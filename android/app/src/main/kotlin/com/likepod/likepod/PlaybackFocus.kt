package com.likepod.likepod

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * One media-focus request for the whole time LikePod wants to play.
 *
 * A loss is never answered by requesting focus again. That reclaim kept the
 * USB interface claimed and stole focus back from Bilibili, Douyin, and any
 * other app. The listener only records the change and tells the activity.
 *
 * Foreground losses do not pause or drop USB direct while this app is
 * playing. They are recorded so Home can yield. LikePod pauses and releases
 * the DAC only after it is in the background and another app has taken audio.
 * A duck pauses and yields only on the mixer path in the background; the
 * exclusive direct stream keeps playing.
 * A loss is treated as our own request only while that request's callback is
 * still queued, not for a timed window afterwards.
 */
object PlaybackFocus {
    @Volatile
    private var yielded = false

    @Volatile
    private var granted = false

    @Volatile
    private var listening = false

    /**
     * True between a background loss and the end of its observation window.
     * The activity decides during this window whether the grabber actually
     * plays before handing over the DAC.
     */
    @Volatile
    private var deferredLossPending = false

    fun isDeferredLossPending(): Boolean = deferredLossPending

    fun deferBackgroundLoss() {
        deferredLossPending = true
    }

    fun clearDeferredLoss() {
        deferredLossPending = false
    }

    /**
     * A real loss or a delayed grant means another app has audio. Foreground
     * playback ignores it. Entering the background while this is set pauses.
     */
    @Volatile
    private var otherAppHasAudio = false

    private var onLost: (() -> Unit)? = null
    private var onGained: (() -> Unit)? = null
    private var requesting = false
    private var requestEpoch = 0
    private var selfEchoEpoch = 0

    /** True from onPause until the Home transition's queued focus callbacks have run. */
    private var hostLeaving = false

    /** Another app had already taken audio before this Home press. */
    private var otherAppBeforeLeave = false

    fun isGranted(): Boolean = listening && granted && !yielded

    /**
     * True when another app has not taken focus. A failed request is still
     * true: only [AUDIOFOCUS_LOSS] and its transient variants clear it.
     */
    fun mayUseUsb(): Boolean = !yielded

    fun isYielded(): Boolean = yielded

    fun otherAppHasAudio(): Boolean = otherAppHasAudio

    /**
     * Home is starting. A focus loss delivered while this is set is the
     * activity transition, not another player, unless one was already noted.
     */
    fun noteHostLeaving() {
        if (hostLeaving) return
        hostLeaving = true
        otherAppBeforeLeave = otherAppHasAudio
        Log.i("LikePodUsb", "host leaving otherBefore=$otherAppBeforeLeave")
    }

    /** Queued transition callbacks have been delivered. Later losses are real. */
    fun noteHostLeaveSettled() {
        hostLeaving = false
        Log.i("LikePodUsb", "host leave settled other=$otherAppHasAudio")
    }

    fun noteHostVisible() {
        hostLeaving = false
        otherAppBeforeLeave = false
    }

    /** The activity is visible again. Foreground playback owns the DAC. */
    fun foregroundRestored() {
        yielded = false
        otherAppHasAudio = false
    }

    /** Background yield. The listener stays registered. */
    fun markYielded() {
        yielded = true
        granted = false
        otherAppHasAudio = true
    }

    /** The user pressed play. That is not another app. */
    fun userWantsPlayback() {
        yielded = false
        otherAppHasAudio = false
    }

    fun abandon(context: Context) {
        listening = false
        granted = false
        yielded = false
        deferredLossPending = false
        otherAppHasAudio = false
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= 26) {
            Modern.abandon(audioManager)
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(legacyListener)
        }
    }

    /**
     * Returns true when this process holds focus now.
     * A failed or delayed request does not count as yielding the DAC.
     */
    fun hold(
        context: Context,
        attributes: AudioAttributes,
        handler: Handler,
        onLost: () -> Unit,
        onGained: () -> Unit,
        rerequest: Boolean = false,
    ): Boolean {
        this.onLost = onLost
        this.onGained = onGained
        // rerequest performs a real requestAudioFocus even while we appear
        // to hold focus. The system's focus-loss enforcement can leave our
        // players muted after a regain; a fresh request clears it. Requesting
        // while already the holder returns GRANTED without a dispatch.
        if (!rerequest && listening && granted && !yielded) {
            return true
        }
        listening = true
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val epoch = ++requestEpoch
        // Callbacks queued by this requestAudioFocus run before the clear
        // posted below, because both use the same handler. A later loss is
        // another app, even if it arrives within a second.
        selfEchoEpoch = epoch
        requesting = true
        val code = try {
            if (Build.VERSION.SDK_INT >= 26) {
                Modern.hold(audioManager, attributes, handler, ::dispatch)
            } else {
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    legacyListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN,
                )
            }
        } finally {
            requesting = false
        }
        handler.post {
            if (selfEchoEpoch == epoch) {
                selfEchoEpoch = 0
            }
        }
        when (code) {
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> {
                granted = true
                yielded = false
                otherAppHasAudio = false
                Log.i("LikePodUSB", "focus granted")
            }
            AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> {
                // Another app currently holds focus. Foreground still uses
                // USB direct; background entry pauses.
                otherAppHasAudio = true
                Log.i("LikePodUSB", "focus delayed, another app has audio")
            }
            else -> {
                // lifeme can refuse the request while no other app is playing.
                // That must not be stored as a yield.
                if (!yielded) {
                    granted = false
                }
                Log.i("LikePodUSB", "focus request refused, USB direct stays")
            }
        }
        return isGranted()
    }

    private val legacyListener = AudioManager.OnAudioFocusChangeListener { change ->
        dispatch(change)
    }

    private fun dispatch(change: Int) {
        if (!listening) return
        Log.i(
            "LikePodUSB",
            "focus change=$change requesting=$requesting yielded=$yielded background=${UsbExclusive.backgrounded} echo=$selfEchoEpoch",
        )
        val ownEcho = selfEchoEpoch != 0 && selfEchoEpoch == requestEpoch
        // Queued during our own requestAudioFocus. Not another app.
        if ((requesting || ownEcho) && change != AudioManager.AUDIOFOCUS_GAIN) {
            Log.i("LikePodUSB", "focus change ignored, own request echo")
            return
        }
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                if (hostLeaving && !otherAppBeforeLeave) {
                    Log.i("LikePodUsb", "duck ignored reason=home-transition")
                    return
                }
                if (!UsbExclusive.backgrounded) {
                    // Foreground follows the LOSS handling above: record
                    // nothing, keep playing, so a notification ding while
                    // the user browses LikePod does not pause music.
                    Log.i("LikePodUSB", "duck ignored reason=foreground")
                    return
                }
                if (UsbExclusive.current.active) {
                    // The DAC is exclusively ours and the ducking app plays
                    // on the phone speaker next to it. Releasing here dropped
                    // exclusive USB on lifeme during our own play.
                    Log.i("LikePodUSB", "duck ignored, exclusive USB stays")
                    return
                }
                // Mixer path: the other app shares this output. Feed apps
                // (Douyin, Bilibili) grab focus with a duck; ignoring it
                // left both playing, and the system's duck attenuation then
                // stuck after they stopped. Pause and yield like a normal
                // music app; the debounced auto-resume brings playback back
                // once they release focus.
                if (yielded) return
                otherAppHasAudio = true
                yielded = true
                granted = false
                Log.i("LikePodUsb", "yield reason=background-duck-mixer")
                onLost?.invoke()
            }
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            -> {
                // A loss during Home itself is the activity stopping, not
                // another app. One recorded while the screen was still up
                // still makes this Home yield.
                if (hostLeaving && !otherAppBeforeLeave) {
                    Log.i("LikePodUsb", "focus loss ignored reason=home-transition")
                    return
                }
                // Foreground keeps playing on USB direct, but a transient loss
                // is remembered so Home yields the DAC to that other app.
                if (!UsbExclusive.backgrounded) {
                    otherAppHasAudio = true
                    granted = false
                    Log.i("LikePodUsb", "focus loss recorded reason=foreground-other-app")
                    return
                }
                if (yielded) return
                // Background apps (feeds especially) grab focus far more
                // often than they actually play. Wait a beat: if the output
                // goes quiet again before anything is audible, treat the
                // loss as an empty grab and keep playing. MusicService's
                // keep-direct reasserts the stream in the meantime, so a
                // real player is never cut off by this window.
                otherAppHasAudio = true
                granted = false
                Log.i("LikePodUsb", "yield deferred reason=background-loss-pending")
                onLost?.invoke()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                val wasYielded = yielded
                deferredLossPending = false
                yielded = false
                granted = true
                otherAppHasAudio = false
                Log.i("LikePodUSB", "focus gain wasYielded=$wasYielded")
                if (wasYielded) onGained?.invoke()
            }
        }
    }

    @RequiresApi(26)
    private object Modern {
        private var request: AudioFocusRequest? = null

        fun hold(
            audioManager: AudioManager,
            attributes: AudioAttributes,
            handler: Handler,
            onChange: (Int) -> Unit,
        ): Int {
            val existing = request
            val built = existing ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setAcceptsDelayedFocusGain(true)
                // This app owns duck handling. Without the flag the system
                // auto-ducks our AudioTrack when another app requests
                // MAY_DUCK focus, and that attenuation did not always come
                // back after the other app stopped.
                .setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener({ change -> onChange(change) }, handler)
                .build()
                .also { request = it }
            return audioManager.requestAudioFocus(built)
        }

        fun abandon(audioManager: AudioManager) {
            val built = request ?: return
            audioManager.abandonAudioFocusRequest(built)
            request = null
        }
    }
}
