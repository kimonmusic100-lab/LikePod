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
 *
 * While the yield is armed the keepalive service and its wake lock stay up,
 * and a few-second alarm retries the check. Focus loss used to stop that
 * service, so after a long video HyperOS froze the process and nothing
 * ran until the activity was opened. The alarm is not scheduled unless a
 * yield is armed. The comfortable gap before playback is on the Dart side.
 *
 * A playback row pauses us only when its uid is a different app. Our own
 * player, and a row whose uid cannot be read, must not: on PME110 that
 * misread turned "play" into pause → reclaim → play until the process died.
 * The same rule is in `pauseForForeignPlayback`.
 */
object PlaybackFocus {
    private const val TAG = "LikePod"
    private const val RECLAIM_DELAY_MS = 700L
    private const val RECLAIM_POLL_MS = 500L

    /** Covers the Dart gap and fade, then drops the yield wake if play never started. */
    private const val YIELD_HOLD_AFTER_RESUME_MS = 4000L

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
    private var reclaimPosted = false
    private var hiddenTried = false
    private var yieldGeneration = 0
    private var mainHandler: Handler? = null
    private var appContext: Context? = null
    private var watcher: AudioManager.AudioPlaybackCallback? = null

    fun isGranted(): Boolean = listening && granted

    fun isAwaitingReturn(): Boolean = listening && awaitingReturn

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
        if (confirmedForeign()) {
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
        reclaimPosted = false
        mainHandler?.removeCallbacks(reclaimRunnable)
        PlaybackAnchor.setYieldHeld(context, false)
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
        // A user play (or the anchor re-holding an already playing song)
        // is not a yield. Re-requesting focus here is what echoed a loss
        // back into the pause path.
        if (granted && !awaitingReturn) {
            Log.i(TAG, "focus already granted")
            return true
        }
        awaitingReturn = false
        reclaimPosted = false
        handler.removeCallbacks(reclaimRunnable)
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
                reclaimPosted = false
                mainHandler?.removeCallbacks(reclaimRunnable)
                appContext?.let { YieldAlarm.disarm(it) }
                Log.i(TAG, "focus gain after another app released audio")
                onGained?.invoke()
                scheduleYieldRelease()
            }
        }
    }

    private fun markYield() {
        if (!listening) return
        granted = false
        val shouldPause = !awaitingReturn || PlaybackAnchor.isPlaying()
        awaitingReturn = true
        yieldGeneration++
        // Hold the service before the pause callback. That callback clears
        // the playing flag, which used to stop the service and let the
        // process freeze for the rest of a long video.
        appContext?.let {
            PlaybackAnchor.setYieldHeld(it, true)
            YieldAlarm.arm(it)
        }
        if (shouldPause) onLost?.invoke()
        scheduleReclaim()
    }

    /**
     * Alarm entry. Runs the same reclaim as the in-process poll.
     * Returns true when the yield is still armed.
     */
    fun nudgeFromAlarm(): Boolean {
        if (!listening || !awaitingReturn) return false
        reclaimPosted = false
        mainHandler?.removeCallbacks(reclaimRunnable)
        reclaimNow()
        return listening && awaitingReturn
    }

    private fun scheduleReclaim() {
        postReclaim(RECLAIM_DELAY_MS)
    }

    private fun scheduleYieldRelease() {
        val handler = mainHandler ?: return
        val generation = yieldGeneration
        handler.postDelayed({
            if (generation != yieldGeneration || PlaybackAnchor.isPlaying()) return@postDelayed
            appContext?.let { PlaybackAnchor.setYieldHeld(it, false) }
        }, YIELD_HOLD_AFTER_RESUME_MS)
    }

    /**
     * One pending check. Playback callbacks must not keep postponing it:
     * our own track and the click pool update the list often, and a reset
     * on every update never reaches the reclaim.
     */
    private fun postReclaim(delayMs: Long) {
        val handler = mainHandler ?: return
        if (!listening || !awaitingReturn || hostLeaving || reclaimPosted) return
        reclaimPosted = true
        handler.postDelayed(reclaimRunnable, delayMs)
    }

    private fun reclaimNow() {
        reclaimPosted = false
        if (!listening || !awaitingReturn || hostLeaving) return
        if (blocksReclaim()) {
            postReclaim(RECLAIM_POLL_MS)
            return
        }
        if (PlaybackAnchor.isPlaying()) {
            // Already audible. Completing the arm must not call play again.
            awaitingReturn = false
            granted = true
            appContext?.let { YieldAlarm.disarm(it) }
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
            appContext?.let { YieldAlarm.disarm(it) }
            onGained?.invoke()
            scheduleYieldRelease()
        } else {
            // DELAYED or a refused request still needs another look. A GAIN
            // callback can arrive first; this poll covers the one that does not.
            postReclaim(RECLAIM_POLL_MS)
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
                // Pause only for a positively different app. An unreadable
                // uid is not one: that was our own player on PME110.
                if (confirmedForeign()) {
                    if (PlaybackAnchor.isPlaying()) markYield()
                    else scheduleReclaim()
                } else if (awaitingReturn) {
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

    /** Started player whose uid is a different application. */
    private fun confirmedForeign(): Boolean {
        return playbackRows().any { row ->
            row.started && row.ownerUid != null &&
                row.ownerUid != row.selfUid && row.ownerUid >= Process.FIRST_APPLICATION_UID
        }
    }

    /**
     * True while reclaim must wait.
     * Same cases as [foreignPlaybackBlocksReclaim] in Dart.
     */
    private fun blocksReclaim(): Boolean {
        val rows = playbackRows()
        if (rows.any { row ->
                row.started && row.ownerUid != null &&
                    row.ownerUid != row.selfUid &&
                    row.ownerUid >= Process.FIRST_APPLICATION_UID
            }
        ) {
            return true
        }
        val unknownStarted = rows.any { row -> row.started && row.ownerUid == null }
        if (!unknownStarted || PlaybackAnchor.isPlaying()) return false
        val app = appContext ?: return true
        val audioManager = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return audioManager.isMusicActive
    }

    private data class PlaybackRow(val ownerUid: Int?, val selfUid: Int, val started: Boolean)

    private fun playbackRows(): List<PlaybackRow> {
        val app = appContext ?: return emptyList()
        if (Build.VERSION.SDK_INT < 26) return emptyList()
        allowHiddenPlaybackApis()
        val audioManager = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val myUid = Process.myUid()
        return audioManager.activePlaybackConfigurations.map { config ->
            val described = config.toString()
            val uid = clientUid(config) ?: uidIn(described)
            val owner = when {
                uid == null -> null
                uid == myUid -> myUid
                uid >= Process.FIRST_APPLICATION_UID -> uid
                else -> null
            }
            val started = playerStarted(config) ?: (stateIn(described) == "started")
            PlaybackRow(owner, myUid, started)
        }
    }

    /** Lets [AudioPlaybackConfiguration.getClientUid] succeed on API 28+. */
    private fun allowHiddenPlaybackApis() {
        if (hiddenTried) return
        hiddenTried = true
        try {
            val vmRuntime = Class.forName("dalvik.system.VMRuntime")
            val runtime = vmRuntime.getDeclaredMethod("getRuntime").invoke(null)
            val setExemptions = vmRuntime.getDeclaredMethod(
                "setHiddenApiExemptions",
                Array<String>::class.java,
            )
            setExemptions.invoke(
                runtime,
                arrayOf("Landroid/media/AudioPlaybackConfiguration;"),
            )
        } catch (error: Throwable) {
            Log.i(TAG, "playback uid exemption skipped: ${error.message}")
        }
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
