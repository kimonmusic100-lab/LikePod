package com.likepod.likepod

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Build
import android.os.Handler
import android.os.Process
import android.os.SystemClock
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
 * While a yield pause is armed, watch [AudioManager.getActivePlaybackConfigurations],
 * [AudioManager.isMusicActive], and the focus callbacks. Poll while armed,
 * and the yield alarm retries the same check. The user abandoning focus
 * (manual pause) clears the arm and must not resume. Cold start never arms.
 * Coming to the foreground only rechecks an arm that already exists; it is
 * not itself a reason to play. The Home transition is not another app.
 *
 * 小红书 takes a transient loss, so the stack later delivers
 * [AudioManager.AUDIOFOCUS_GAIN] and this object resumes without reading
 * player rows. B站 and many other video apps take a permanent loss. Nothing
 * delivers GAIN. They also leave a playback row whose hidden player-state
 * still says started after the activity is gone. Waiting on that row alone
 * never resumes. A quiet music stream, held briefly so a buffer underrun
 * is not a handoff, means the output is free even if that row remains.
 * The row's public state string wins over reflection: a paused/stopped/
 * idle/released description is not "still playing".
 *
 * While the yield is armed the keepalive service, its wake lock, a silent
 * sonification track, and the yield alarms stay up. Focus loss used to stop
 * the service, and after about twenty seconds without our own audio HyperOS
 * freezes the process anyway. The in-process poll then stops. Xiaohongshu
 * still works because the system delivers `AUDIOFOCUS_GAIN` and that binder
 * call thaws the process. A permanent loss has no such callback, and vc38's
 * alarm was inexact (exact alarms are denied by default), so a long Bilibili
 * session never ran the reclaim until the activity was opened. A short
 * session ends before the freeze. The alarm is not scheduled unless a yield
 * is armed. The two-second gap before playback is on the Dart side.
 *
 * A playback row never pauses us by itself. Pause comes from focus loss.
 * Our own player, and a row whose uid cannot be read, must not count as
 * another app: on PME110 that misread turned "play" into pause → reclaim
 * → play until the process died. The same uid rule is in
 * `pauseForForeignPlayback`.
 */
object PlaybackFocus {
    private const val TAG = "LikePod"
    private const val RECLAIM_DELAY_MS = 700L
    private const val RECLAIM_POLL_MS = 500L

    /**
     * Covers the 3.8s Dart gap plus the 1s fade, then drops the yield wake
     * if play never started. Real playback takes over the service wake lock
     * at the start of the fade, so this only has to outlast the gap.
     */
    private const val YIELD_HOLD_AFTER_RESUME_MS = 9000L

    /**
     * How long the music stream must stay quiet before a leftover started
     * row from another app stops blocking reclaim.
     */
    private const val STALE_QUIET_MS = 1000L

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
    private var quietSinceMs = 0L
    private var yieldArmedAtMs = 0L
    private var lastHeartbeatMs = 0L
    private var lastWaitKey: String? = null
    private var foreignWhileHeld: Set<Int> = emptySet()
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
        val arrived = foreignStartedUids() - foreignWhileHeld
        Log.i(TAG, "host leave settled missedLoss=$missed arrived=$arrived")
        if (!listening) return
        // A player uid that was already present is a leftover row, not a
        // new interrupter. Home used to pause on that leftover.
        if (missed && arrived.isNotEmpty()) {
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
        quietSinceMs = 0L
        yieldArmedAtMs = 0L
        lastHeartbeatMs = 0L
        lastWaitKey = null
        foreignWhileHeld = emptySet()
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
        userRequested: Boolean = false,
    ): Boolean {
        this.onLost = onLost
        this.onGained = onGained
        this.mainHandler = handler
        listening = true
        ensureWatcher(context, handler)
        // Going to the background re-calls hold while a yield is armed.
        // Clearing the arm here dropped the poll and the alarm, and a new
        // focus request can steal the video that just started. A manual
        // play is userRequested and still takes focus now.
        if (awaitingReturn && !userRequested) {
            Log.i(TAG, "hold kept yield")
            PlaybackAnchor.setYieldHeld(context, true)
            YieldAlarm.arm(context)
            return false
        }
        // A user play (or the anchor re-holding an already playing song)
        // is not a yield. Re-requesting focus here is what echoed a loss
        // back into the pause path.
        if (granted && !awaitingReturn) {
            foreignWhileHeld = foreignStartedUids()
            Log.i(TAG, "focus already granted")
            return true
        }
        awaitingReturn = false
        reclaimPosted = false
        quietSinceMs = 0L
        lastWaitKey = null
        handler.removeCallbacks(reclaimRunnable)
        val code = requestFocus(context, attributes, handler)
        granted = code == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (granted) foreignWhileHeld = foreignStartedUids()
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
                quietSinceMs = 0L
                lastWaitKey = null
                foreignWhileHeld = foreignStartedUids()
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
        quietSinceMs = 0L
        yieldArmedAtMs = SystemClock.elapsedRealtime()
        lastHeartbeatMs = 0L
        lastWaitKey = null
        logPlayback("yield armed")
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
        val context = appContext
        if (context != null) {
            PlaybackAnchor.reassert(context)
            YieldKeepAlive.start()
        }
        heartbeat("alarm")
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
        heartbeat("poll")
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
            quietSinceMs = 0L
            lastWaitKey = null
            foreignWhileHeld = foreignStartedUids()
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
                // Remember rows while we hold focus so a leftover started
                // player is not treated as a new interrupter on Home.
                // Do not pause from this callback. A stale foreign row used
                // to mark a yield the moment we resumed, which paused us
                // again. Real pauses come from focus loss.
                if (!awaitingReturn) {
                    foreignWhileHeld = foreignStartedUids()
                    return
                }
                scheduleReclaim()
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
     * True while reclaim must wait.
     * Same cases as [foreignPlaybackBlocksReclaim] in Dart.
     * A confirmed other app blocks while music is active, and for
     * [STALE_QUIET_MS] after the stream goes quiet. A phone call always
     * blocks. An unreadable started row blocks only while music is active.
     */
    private fun blocksReclaim(): Boolean {
        val decision = evaluateReclaim()
        if (decision.key != lastWaitKey) {
            lastWaitKey = decision.key
            Log.i(TAG, decision.detail)
        }
        return decision.blocked
    }

    private data class ReclaimDecision(val blocked: Boolean, val key: String, val detail: String)

    private fun evaluateReclaim(): ReclaimDecision {
        val app = appContext
            ?: return ReclaimDecision(true, "no-context", "reclaim waiting reason=no-context")
        val audioManager = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val mode = audioManager.mode
        val inCall = mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION ||
            mode == AudioManager.MODE_RINGTONE ||
            (Build.VERSION.SDK_INT >= 30 && mode == AudioManager.MODE_CALL_SCREENING)
        if (inCall) {
            quietSinceMs = 0L
            return ReclaimDecision(true, "call", "reclaim waiting reason=call mode=$mode")
        }
        val rows = playbackRows()
        val foreign = rows.any { it.isOtherApp }
        val unknownStarted = rows.any { it.started && it.ownerUid == null }
        val music = audioManager.isMusicActive
        val described = describeRows(rows)
        if (music) {
            quietSinceMs = 0L
            if (foreign) {
                return ReclaimDecision(
                    true,
                    "foreign",
                    "reclaim waiting reason=foreign music=1 $described",
                )
            }
            if (unknownStarted && !PlaybackAnchor.isPlaying()) {
                return ReclaimDecision(
                    true,
                    "unknown",
                    "reclaim waiting reason=unknown music=1 $described",
                )
            }
            return ReclaimDecision(false, "clear", "reclaim clear reason=music-ours $described")
        }
        if (!foreign) {
            quietSinceMs = 0L
            return ReclaimDecision(false, "clear", "reclaim clear reason=silent $described")
        }
        val now = SystemClock.elapsedRealtime()
        if (quietSinceMs == 0L) quietSinceMs = now
        val quietFor = now - quietSinceMs
        if (quietFor < STALE_QUIET_MS) {
            return ReclaimDecision(
                true,
                "quiet-hold",
                "reclaim waiting reason=quiet-hold quietMs=$quietFor $described",
            )
        }
        return ReclaimDecision(
            false,
            "clear",
            "reclaim clear reason=stale-foreign quietMs=$quietFor $described",
        )
    }

    private fun describeRows(rows: List<PlaybackRow>): String {
        if (rows.isEmpty()) return "rows=0"
        return rows.joinToString(";") { row ->
            "uid=${row.ownerUid} started=${row.started} state=${row.describedState} usage=${row.usage} raw=${row.raw}"
        }
    }

    private fun heartbeat(where: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastHeartbeatMs < 10_000L) return
        lastHeartbeatMs = now
        val age = if (yieldArmedAtMs == 0L) 0L else now - yieldArmedAtMs
        Log.i(
            TAG,
            "yield heartbeat where=$where ageMs=$age keepalive=${YieldKeepAlive.isRunning()}",
        )
        logPlayback("yield heartbeat")
    }

    private fun logPlayback(reason: String) {
        val app = appContext
        val music = if (app == null) {
            null
        } else {
            val audioManager = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.isMusicActive
        }
        Log.i(TAG, "$reason music=$music ${describeRows(playbackRows())}")
    }

    private data class PlaybackRow(
        val ownerUid: Int?,
        val selfUid: Int,
        val started: Boolean,
        val describedState: String?,
        val usage: Int,
        val raw: String,
    ) {
        val isOtherApp: Boolean
            get() = started && ownerUid != null && ownerUid != selfUid &&
                ownerUid >= Process.FIRST_APPLICATION_UID
    }

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
            val describedState = stateIn(described)
            val usage = config.audioAttributes.usage
            // The yield keepalive is a silent sonification track on our uid.
            // It must not count as someone else still playing, and it must
            // not keep isMusicActive's "foreign started" wait latched if the
            // uid cannot be read.
            val started = rowStarted(playerStarted(config), describedState) &&
                usage != AudioAttributes.USAGE_ASSISTANCE_SONIFICATION
            PlaybackRow(owner, myUid, started, describedState, usage, described.take(160))
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

    /** Same rule as `playbackRowStarted` in Dart. The public state wins. */
    private fun rowStarted(reflected: Boolean?, describedState: String?): Boolean {
        return when (describedState) {
            "paused", "stopped", "idle", "released" -> false
            "started" -> true
            else -> reflected == true
        }
    }

    private fun foreignStartedUids(): Set<Int> {
        return playbackRows().mapNotNull { row ->
            if (row.isOtherApp) row.ownerUid else null
        }.toSet()
    }

    private fun uidIn(described: String): Int? {
        val patterns = listOf(
            Regex("""u/pid:(\d+)/"""),
            Regex("""(?i)clientUid[=:](\d+)"""),
            Regex("""(?i)\buid[=:](\d+)"""),
        )
        for (pattern in patterns) {
            val value = pattern.find(described)?.groupValues?.get(1)?.toIntOrNull()
            if (value != null && value >= 0) return value
        }
        return null
    }

    private fun stateIn(described: String): String? {
        val patterns = listOf(
            Regex("""(?<![A-Za-z])state:([A-Za-z]+)"""),
            Regex("""(?i)playerState[=:]([A-Za-z]+)"""),
        )
        for (pattern in patterns) {
            val value = pattern.find(described)?.groupValues?.get(1)?.lowercase()
            if (value != null) return value
        }
        return null
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
