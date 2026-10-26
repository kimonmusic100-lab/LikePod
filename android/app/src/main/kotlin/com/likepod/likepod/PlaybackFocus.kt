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
 * One media-focus request for as long as LikePod wants to play.
 *
 * A full or transient loss pauses playback. A duck pauses only while the
 * activity is in the background, which is how feed apps take the output.
 * The request stays registered across that pause. When the other app
 * releases focus, [onGained] runs so playback can continue. A pause the
 * user asked for abandons the request and does not resume.
 * The Home transition itself is not another app.
 */
object PlaybackFocus {
    private const val TAG = "LikePod"

    @Volatile
    private var granted = false

    @Volatile
    private var listening = false

    @Volatile
    private var backgrounded = false

    private var onLost: (() -> Unit)? = null
    private var onGained: (() -> Unit)? = null
    private var requesting = false
    private var requestEpoch = 0
    private var selfEchoEpoch = 0
    private var hostLeaving = false

    fun isGranted(): Boolean = listening && granted

    fun setBackground(background: Boolean) {
        backgrounded = background
    }

    fun noteHostLeaving() {
        if (hostLeaving) return
        hostLeaving = true
        Log.i(TAG, "host leaving")
    }

    fun noteHostLeaveSettled() {
        hostLeaving = false
        Log.i(TAG, "host leave settled")
    }

    fun noteHostVisible() {
        hostLeaving = false
    }

    fun abandon(context: Context) {
        listening = false
        granted = false
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= 26) {
            Modern.abandon(audioManager)
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(legacyListener)
        }
    }

    /**
     * Returns true only when this process holds focus now.
     * A delayed or refused request does not count as a grant.
     */
    fun hold(
        context: Context,
        attributes: AudioAttributes,
        handler: Handler,
        onLost: () -> Unit,
        onGained: () -> Unit,
    ): Boolean {
        this.onLost = onLost
        this.onGained = onGained
        listening = true
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val epoch = ++requestEpoch
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
        granted = code == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        Log.i(TAG, "focus request code=$code granted=$granted")
        return granted
    }

    private val legacyListener = AudioManager.OnAudioFocusChangeListener { change ->
        dispatch(change)
    }

    private fun dispatch(change: Int) {
        if (!listening) return
        val ownEcho = selfEchoEpoch != 0 && selfEchoEpoch == requestEpoch
        if ((requesting || ownEcho) && change != AudioManager.AUDIOFOCUS_GAIN) {
            Log.i(TAG, "focus change ignored, own request echo change=$change")
            return
        }
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                if (hostLeaving || !backgrounded) {
                    Log.i(TAG, "duck ignored background=$backgrounded leaving=$hostLeaving")
                    return
                }
                Log.i(TAG, "pause reason=background-duck")
                granted = false
                onLost?.invoke()
            }
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            -> {
                if (hostLeaving) {
                    Log.i(TAG, "focus loss ignored reason=home-transition change=$change")
                    return
                }
                Log.i(TAG, "pause reason=focus-loss change=$change")
                granted = false
                onLost?.invoke()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                granted = true
                val own = requesting || (selfEchoEpoch != 0 && selfEchoEpoch == requestEpoch)
                if (own) {
                    Log.i(TAG, "focus gain from own request")
                    return
                }
                Log.i(TAG, "focus gain after another app released audio")
                onGained?.invoke()
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
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
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
