package com.likepod.likepod

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Build
import android.os.Handler
import android.os.Process
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * One media-focus request for as long as LikePod wants to play.
 *
 * Pause when another app takes the output (permanent loss, transient loss,
 * or a background duck). Keep the request. Transient loss usually delivers
 * [AudioManager.AUDIOFOCUS_GAIN] when that app lets go (小红书). Permanent
 * loss does not: the loser is dropped from the stack, which is what B站 and
 * many video apps do, so a GAIN callback never arrives.
 *
 * While a yield pause is armed, watch [AudioManager.getActivePlaybackConfigurations].
 * When no other app is still playing, request focus again and resume. Poll
 * while armed so a missed callback still returns. The user abandoning focus
 * (manual pause) clears the arm and must not resume. Cold start never arms.
 * Coming to the foreground only rechecks an arm that already exists; it is
 * not itself a reason to play. The Home transition is not another app.
 */
object PlaybackFocus {
    private const val TAG = "LikePod"
    private const val RECLAIM_DELAY_MS = 700L
    private const val RECLAIM_POLL_MS = 1000L

    @Volatile
    private var granted = false

    @Volatile
    private var listening = false

    @Volatile
    private var backgrounded = false

    @Volatile
    private var awaitingReturn = false

    private var onLost: (() -> Unit)? = null
    private var onGained: (() -> Unit)? = null
    private var requesting = false
    private var requestEpoch = 0
    private var selfEchoEpoch = 0
    private var hostLeaving = false
    private var lossDuringLeave = false
    private var suppressGain = false
    private var mainHandler: Handler? = null
    private var appContext: Context? = null
    private var watcher: AudioManager.AudioPlaybackCallback? = null

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
        val missed = lossDuringLeave
        lossDuringLeave = false
        Log.i(TAG, "host leave settled missedLoss=$missed")
        if (!listening) return
        if (otherAppActive()) {
            markYield()
        } else if (missed && PlaybackAnchor.isPlaying()) {
            refreshOwnGrant()
        } else {
            scheduleReclaim()
        }
    }

    fun noteHostVisible() {
        hostLeaving = false
        // Backup only: an already-armed yield can complete if the interrupter
        // has stopped. Opening the activity does not start playback by itself.
        scheduleReclaim()
    }

    fun abandon(context: Context) {
        awaitingReturn = false
        lossDuringLeave = false
        listening = false
        granted = false
        mainHandler?.removeCallbacks(reclaimRunnable)
        unregisterWatcher()
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
        this.mainHandler = handler
        listening = true
        ensureWatcher(context, handler)
        val code = requestFocus(context, attributes, handler)
        granted = code == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        Log.i(TAG, "focus request code=$code granted=$granted")
        return granted
    }

    private val legacyListener = AudioManager.OnAudioFocusChangeListener { change ->
        dispatch(change)
    }

    private val reclaimRunnable = Runnable { reclaimNow() }

    private fun requestFocus(
        context: Context,
        attributes: AudioAttributes,
        handler: Handler,
    ): Int {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val epoch = ++requestEpoch
        selfEchoEpoch = epoch
        requesting = true
        suppressGain = true
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
            suppressGain = false
        }
        handler.post {
            if (selfEchoEpoch == epoch) selfEchoEpoch = 0
        }
        return code
    }

    private fun dispatch(change: Int) {
        if (!listening) return
        val ownEcho = selfEchoEpoch != 0 && selfEchoEpoch == requestEpoch
        if ((requesting || ownEcho || suppressGain) && change != AudioManager.AUDIOFOCUS_GAIN) {
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
                markYield()
            }
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            -> {
                if (hostLeaving) {
                    lossDuringLeave = true
                    Log.i(TAG, "focus loss deferred reason=home-transition change=$change")
                    return
                }
                Log.i(TAG, "pause reason=focus-loss change=$change")
                markYield()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (requesting || ownEcho || suppressGain) {
                    Log.i(TAG, "focus gain from own request")
                    return
                }
                granted = true
                awaitingReturn = false
                mainHandler?.removeCallbacks(reclaimRunnable)
                Log.i(TAG, "focus gain after another app released audio")
                onGained?.invoke()
            }
        }
    }

    private fun markYield() {
        if (!listening) return
        granted = false
        val shouldPause = !awaitingReturn || PlaybackAnchor.isPlaying()
        awaitingReturn = true
        if (shouldPause) onLost?.invoke()
        scheduleReclaim()
    }

    private fun scheduleReclaim() {
        val handler = mainHandler ?: return
        handler.removeCallbacks(reclaimRunnable)
        if (!listening || !awaitingReturn || hostLeaving) return
        handler.postDelayed(reclaimRunnable, RECLAIM_DELAY_MS)
    }

    private fun reclaimNow() {
        if (!listening || !awaitingReturn || hostLeaving) return
        if (otherAppActive()) {
            mainHandler?.postDelayed(reclaimRunnable, RECLAIM_POLL_MS)
            return
        }
        val context = appContext ?: return
        val handler = mainHandler ?: return
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val code = requestFocus(context, attributes, handler)
        Log.i(TAG, "reclaim focus code=$code")
        if (code == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            granted = true
            awaitingReturn = false
            onGained?.invoke()
        } else {
            // DELAYED or a refused request still needs another look. A GAIN
            // callback can arrive first; this poll covers the one that does not.
            mainHandler?.postDelayed(reclaimRunnable, RECLAIM_POLL_MS)
        }
    }

    private fun refreshOwnGrant() {
        val context = appContext ?: return
        val handler = mainHandler ?: return
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val code = requestFocus(context, attributes, handler)
        granted = code == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        Log.i(TAG, "refresh own grant code=$code")
    }

    private fun ensureWatcher(context: Context, handler: Handler) {
        appContext = context.applicationContext
        if (Build.VERSION.SDK_INT < 26 || watcher != null) return
        val callback = object : AudioManager.AudioPlaybackCallback() {
            override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>) {
                if (!listening || hostLeaving) return
                if (otherAppActive()) {
                    if (PlaybackAnchor.isPlaying()) markYield()
                    else scheduleReclaim()
                } else {
                    scheduleReclaim()
                }
            }
        }
        watcher = callback
        val audioManager = appContext!!.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.registerAudioPlaybackCallback(callback, handler)
    }

    private fun unregisterWatcher() {
        val callback = watcher ?: return
        watcher = null
        val app = appContext ?: return
        if (Build.VERSION.SDK_INT < 26) return
        val audioManager = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.unregisterAudioPlaybackCallback(callback)
    }

    /**
     * True when some other app still has a started player.
     *
     * [AudioPlaybackConfiguration.getClientUid] and `getPlayerState` are
     * hidden, so they are not in android.jar. Read them by reflection and
     * fall back to the public `toString` (`u/pid:` and `state:started`).
     * A started player with an unknown owner still counts, so a miss does
     * not request focus and steal the other app. A player that is clearly
     * paused does not count. [reclaimNow] requests focus only when this
     * is false.
     */
    private fun otherAppActive(): Boolean {
        val app = appContext ?: return false
        if (Build.VERSION.SDK_INT < 26) return false
        val audioManager = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val myUid = Process.myUid()
        return audioManager.activePlaybackConfigurations.any { config ->
            foreignStarted(config, myUid)
        }
    }

    private fun foreignStarted(config: AudioPlaybackConfiguration, myUid: Int): Boolean {
        val described = config.toString()
        val uid = clientUid(config) ?: uidIn(described)
        if (uid == myUid) return false
        val started = playerStarted(config) ?: stateIn(described)?.let { it == "started" }
        if (started != true) return false
        return true
    }

    private fun clientUid(config: AudioPlaybackConfiguration): Int? {
        return try {
            val value = AudioPlaybackConfiguration::class.java
                .getMethod("getClientUid")
                .invoke(config)
            (value as? Int)?.takeIf { it >= 0 }
        } catch (_: Throwable) {
            null
        }
    }

    /** AOSP `PLAYER_STATE_STARTED` is 2. The field is hidden in android.jar. */
    private fun playerStarted(config: AudioPlaybackConfiguration): Boolean? {
        return try {
            if (Build.VERSION.SDK_INT >= 31) {
                val state = AudioPlaybackConfiguration::class.java
                    .getMethod("getPlayerState")
                    .invoke(config) as? Int ?: return null
                val started = try {
                    AudioPlaybackConfiguration::class.java
                        .getField("PLAYER_STATE_STARTED")
                        .getInt(null)
                } catch (_: Throwable) {
                    2
                }
                state == started
            } else {
                AudioPlaybackConfiguration::class.java
                    .getMethod("isActive")
                    .invoke(config) as? Boolean
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun uidIn(described: String): Int? {
        val match = Regex("""u/pid:(\d+)/""").find(described) ?: return null
        return match.groupValues[1].toIntOrNull()
    }

    private fun stateIn(described: String): String? {
        val match = Regex("""(?<![A-Za-z])state:([A-Za-z]+)""").find(described) ?: return null
        return match.groupValues[1].lowercase()
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
