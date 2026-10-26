package com.likepod.likepod

import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.media.AudioTrack
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import androidx.annotation.NonNull
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.lang.reflect.Modifier
import java.util.Collections
import java.util.IdentityHashMap
import kotlin.math.roundToInt

class MainActivity : AudioServiceActivity() {
    override fun onPause() {
        PlaybackFocus.noteHostLeaving()
        if (playbackOwnsDac() && UsbExclusive.current.active) {
            UsbExclusive.reassertSuspend()
            Log.i("LikePodUsb", "claim reassert reason=onPause")
        }
        super.onPause()
        if (!hostStopped) {
            heldVolume = readMusicVolume()
            lastSeenVolume = heldVolume
            userMuted = false
        }
        PlaybackAnchor.reassert(this)
    }

    override fun onStop() {
        PlaybackFocus.noteHostLeaving()
        super.onStop()
        hostStopped = true
        UsbExclusive.backgrounded = true
        val owns = playbackOwnsDac()
        // Live focus state, not the flag snapshotted at onPause. A recorded
        // foreground loss can outlive the app that caused it; keeping the
        // DAC on that stale flag pauses playback on a plain Home press.
        val focusHeld = PlaybackFocus.isGranted() && !UsbExclusive.isFocusYielded()
        Log.i(
            "LikePodUsb",
            "onStop owns=$owns focusHeld=$focusHeld direct=${UsbExclusive.current.active}",
        )
        if (owns && focusHeld) {
            // Home alone. The usbfs claim stays with the playback service.
            if (heldVolume < 0) heldVolume = readMusicVolume()
            lastSeenVolume = heldVolume
            userMuted = false
            pinHeldGain()
            // focusHeld means this process is the recorded holder, so hold()
            // returns without requesting again and cannot steal focus back
            // from another app.
            holdAudioFocus()
            PlaybackAnchor.setDirect(this, UsbExclusive.current.active)
            PlaybackAnchor.onHostBackground(this)
            UsbExclusive.keepForService("home-no-other-audio")
            startVolumeHold()
            if (UsbExclusive.current.active) {
                PlaybackAnchor.noteBackground("direct")
                Log.i("LikePodUsb", "mode direct reason=background-no-other-audio")
            }
            publishBackgroundPath()
            settleHomeTransition()
            return
        }
        PlaybackAnchor.onHostBackground(this)
        if (!owns) {
            if (UsbExclusive.current.active || UsbExclusive.isFocusYielded()) {
                Log.i("LikePodUsb", "release reason=background-not-playing")
                if (UsbExclusive.isFocusYielded()) {
                    UsbExclusive.releaseForFocus("background-not-playing")
                } else {
                    UsbExclusive.stop("background-not-playing")
                }
                releaseRouteToSystem()
            }
            settleHomeTransition()
            return
        }
        Log.i("LikePodUsb", "yield reason=focus-not-held-at-home")
        yieldToOtherApp()
        settleHomeTransition()
    }

    private fun settleHomeTransition() {
        mainHandler.post { PlaybackFocus.noteHostLeaveSettled() }
    }

    /** Anchor flag or the live player. Home must not look idle while audio is running. */
    private fun playbackOwnsDac(): Boolean {
        if (PlaybackAnchor.isPlaying()) return true
        return try {
            com.ryanheise.just_audio.UsbPreferredDevice.isAudible()
        } catch (_: Throwable) {
            false
        }
    }

    override fun onStart() {
        super.onStart()
        val wasStopped = hostStopped
        hostStopped = false
        UsbExclusive.backgrounded = false
        if (wasStopped || lastSeenVolume < 0) {
            lastSeenVolume = readMusicVolume()
        }
        stopBackgroundLoops()
        PlaybackFocus.noteHostVisible()
        PlaybackAnchor.onHostForeground(this)
        if (wasStopped && (UsbExclusive.isFocusYielded() || resumeAfterFocus)) {
            Log.i("LikePodUSB", "foreground return, DAC stays released until play")
            restoreDirectOnForeground()
            return
        }
        if (!UsbExclusive.isFocusYielded()) {
            UsbExclusive.clearBackgroundGain()
        }
        if (wasStopped && PlaybackAnchor.isPlaying() && UsbExclusive.current.active) {
            val ratio = volumeRatio(readMusicVolume())
            if (ratio != null) UsbExclusive.setStreamVolume(ratio)
            PlaybackAnchor.noteBackground("direct")
        }
        publishBackgroundPath()
    }

    /**
     * The user came back. The direct path may be opened on the next play.
     * Playback stays paused, and the DAC stays released until that press.
     */
    private fun restoreDirectOnForeground() {
        resumeAfterFocus = false
        focusPauses = 0
        cancelFocusResume()
        stopYieldWatch()
        PlaybackFocus.foregroundRestored()
        UsbExclusive.focusReturned()
        UsbExclusive.clearBackgroundGain()
        PlaybackAnchor.setPlaying(this, false)
        if (UsbExclusive.current.active) {
            UsbExclusive.stop()
            releaseRouteToSystem()
        }
        mediaChannel?.invokeMethod("onAudioFocusGained", false)
        mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
    }

    private val CHANNEL = "com.likepod/media"
    private val TAG = "LikePod"
    private val VOLUME_CHANGED_ACTION = "android.media.VOLUME_CHANGED_ACTION"
    private val EXTRA_VOLUME_STREAM_TYPE = "android.media.EXTRA_VOLUME_STREAM_TYPE"
    private var boundEngine: FlutterEngine? = null
    private var mediaChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var hostStopped = false
    private var heldVolume = -1
    private var lastSeenVolume = -1
    private var userMuted = false
    private var restoringVolume = false
    private var resumeAfterFocus = false
    private var focusPauses = 0
    private var focusResumeRunnable: Runnable? = null
    private val focusResumeDelayMs = 2500L
    private var quietCheckCount = 0
    private var lastAutoResumeAt = 0L
    private var lastYieldAt = 0L
    private val pingPongWindowMs = 60000L
    private var yieldWatchRunnable: Runnable? = null
    private var yieldClearTicks = 0
    private val yieldWatchIntervalMs = 3000L
    private val yieldWatchQuietTicks = 2
    private var volumeHold: Runnable? = null
    private var deviceCallbackRegistered = false
    private var outputCallback: AudioDeviceCallback? = null
    private var deviceEvent: Runnable? = null
    private var mixerDeviceId: Int? = null
    private var usbReceiverRegistered = false
    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                UsbExclusive.ACTION_USB_PERMISSION -> {
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    val name = usbDeviceName(intent)
                    if (name != null) {
                        UsbExclusive.onPermission(name, granted)
                    }
                    mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    UsbExclusive.onDetached(usbDeviceName(intent))
                    mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
                }
                VOLUME_CHANGED_ACTION -> onSystemVolumeChanged(intent)
            }
        }
    }

    private fun onSystemVolumeChanged(intent: Intent) {
        val stream = intent.getIntExtra(EXTRA_VOLUME_STREAM_TYPE, -1)
        if (stream != AudioManager.STREAM_MUSIC) {
            return
        }
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) {
            return
        }
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val ratio = current.toFloat() / max.toFloat()
        if (absorbBackgroundVolume(current)) {
            return
        }
        if (UsbExclusive.current.active) {
            applyDirectVolumeKey(current, max)
            return
        }
        val applied = UsbExclusive.setStreamVolume(ratio)
        if (!UsbExclusive.current.active) {
            return
        }
        if (applied == null) {
            UsbExclusive.stop()
            mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
            return
        }
        mediaChannel?.invokeMethod("onDirectGain", gainPayload(applied))
    }

    /**
     * Volume keys move the direct-path wheel in both directions. The system
     * stream is only the step size; it is not a second gain on the PCM.
     */
    private fun applyDirectVolumeKey(current: Int, max: Int) {
        val previous = lastSeenVolume
        lastSeenVolume = current
        val wheel = UsbExclusive.wheelUi() ?: (current.toFloat() / max.toFloat())
        val delta = if (previous >= 0) (current - previous).toFloat() / max.toFloat() else 0f
        val next = (wheel + delta).coerceIn(0f, 1f)
        val applied = UsbExclusive.setWheelVolume(next)
        Log.i("LikePodUSB", "volume key direct $wheel -> $next delta=$delta")
        if (applied == null) {
            if (UsbExclusive.current.active) {
                UsbExclusive.stop()
                mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
            }
            return
        }
        mediaChannel?.invokeMethod("onDirectGain", gainPayload(applied))
    }

    private fun gainPayload(heard: UsbExclusive.Heard): Map<String, Double> {
        return mapOf("ui" to heard.ui.toDouble(), "linear" to heard.linear.toDouble())
    }

    private fun readMusicVolume(): Int {
        return try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        } catch (_: Throwable) {
            -1
        }
    }

    /**
     * While the activity is stopped, a jump to silence is put back for as
     * long as playback continues. One step down to 0 is a user mute and is
     * kept. Returns true when this change must not be copied onto USB gain.
     */
    private fun absorbBackgroundVolume(current: Int): Boolean {
        if (restoringVolume) return true
        if (!hostStopped || !PlaybackAnchor.isPlaying()) return false
        val previous = lastSeenVolume
        lastSeenVolume = current
        if (userMuted) return false
        if (previous == 1 && current == 0) {
            userMuted = true
            UsbExclusive.clearBackgroundGain()
            Log.i(TAG, "Background volume left at 0 after a user step")
            return false
        }
        if (previous >= 0 && kotlin.math.abs(current - previous) <= 1 && current > 0) {
            heldVolume = current
            pinHeldGain()
            return false
        }
        if (current == 0 && heldVolume > 0) {
            restoreHeldVolume()
            pinHeldGain()
            return true
        }
        if (current > 0) {
            heldVolume = current
            pinHeldGain()
        }
        return false
    }

    private fun startVolumeHold() {
        volumeHold?.let { mainHandler.removeCallbacks(it) }
        val task = object : Runnable {
            override fun run() {
                if (!hostStopped || !PlaybackAnchor.isPlaying() || UsbExclusive.isFocusYielded()) {
                    return
                }
                if (!userMuted && heldVolume > 0 && readMusicVolume() == 0) {
                    restoreHeldVolume()
                }
                if (!userMuted) {
                    pinHeldGain()
                    if (UsbExclusive.current.active) {
                        val ratio = volumeRatio(heldVolume)
                        if (ratio != null) UsbExclusive.setStreamVolume(ratio)
                        UsbExclusive.reassertSuspend()
                    }
                }
                mainHandler.postDelayed(this, 300)
            }
        }
        volumeHold = task
        mainHandler.postDelayed(task, 300)
    }

    private fun stopBackgroundLoops() {
        volumeHold?.let { mainHandler.removeCallbacks(it) }
        volumeHold = null
    }

    private fun pinHeldGain() {
        val ratio = volumeRatio(heldVolume) ?: return
        UsbExclusive.pinBackgroundGain(ratio)
    }

    private fun volumeRatio(index: Int): Float? {
        if (index < 0) return null
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return null
        return index.toFloat() / max.toFloat()
    }

    private fun restoreHeldVolume() {
        if (heldVolume <= 0 || restoringVolume) return
        restoringVolume = true
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, heldVolume, 0)
            Log.i(TAG, "Restored music volume $heldVolume while backgrounded")
        } catch (error: Throwable) {
            Log.i(TAG, "Background volume restore skipped: ${error.message}")
        } finally {
            restoringVolume = false
        }
    }

    private fun publishBackgroundPath() {
        val path = PlaybackAnchor.backgroundPath
        if (path.isEmpty()) return
        mediaChannel?.invokeMethod("onBackgroundPath", path)
    }

    private fun pauseForFocus() {
        try {
            val cls = Class.forName("com.ryanheise.just_audio.UsbPreferredDevice")
            cls.getMethod("pauseForFocus").invoke(null)
            Log.i("LikePodUsb", "player paused reason=yield")
        } catch (error: Exception) {
            Log.i("LikePodUsb", "player pause skipped ${error.message}")
        }
    }

    private fun holdAudioFocus(force: Boolean = false): Boolean {
        return PlaybackFocus.hold(
            context = this,
            attributes = mediaAttributes(),
            handler = mainHandler,
            onLost = { yieldToOtherApp() },
            onGained = { regainFocus() },
            rerequest = force,
        )
    }

    /**
     * Another app started audio while LikePod is in the background. Pause,
     * drop the exclusive USB claim, and put the kernel driver back so the
     * system mixer can use the DAC. Foreground losses do not call this.
     */
    private fun yieldToOtherApp() {
        if (UsbExclusive.isFocusYielded()) {
            Log.i("LikePodUsb", "yield skipped reason=already-released")
            return
        }
        // The DAC-side work (release + rebind + port reset) must happen
        // immediately: the grabber opens its first AudioTrack within ~400 ms
        // of taking focus, and a track opened before the reset lands on the
        // stalled endpoint and stays silent forever. Whether LikePod also
        // pauses is decided afterwards by the observation window: if nothing
        // audible came out of the grab, the DAC comes straight back.
        if (!PlaybackFocus.isDeferredLossPending()) {
            PlaybackFocus.deferBackgroundLoss()
            releaseUsbForHandoff()
            Log.i("LikePodUsb", "yield dac released reason=loss-under-observation")
            mainHandler.removeCallbacks(deferredYieldCheck)
            mainHandler.postDelayed(deferredYieldCheck, yieldObserveMs)
            return
        }
        performYieldToOtherApp()
    }

    private val yieldObserveMs = 800L

    /** Stops the stream, releases the interfaces, rebinds, resets the port. */
    private fun releaseUsbForHandoff() {
        lastYieldAt = SystemClock.elapsedRealtime()
        // playbackOwnsDac() is false on the second+ yield of a feed session
        // (we are already paused); the armed auto-resume task is the intent
        // carrier and must keep it alive.
        resumeAfterFocus = playbackOwnsDac() || resumeAfterFocus ||
            focusResumeRunnable != null
        focusPauses++
        // The armed auto-resume must survive the release: it comes back when
        // the grabber goes quiet; only a user pause or the foreground
        // cancels it.
        UsbExclusive.armYield("other-app-audio")
        PlaybackFocus.markYielded()
        // Hand the DAC back before anything slow runs. Stopping the stream,
        // releasing the interfaces, and rebinding the kernel driver are
        // plain ioctls with no latches or reflection.
        UsbExclusive.releaseForFocus("other-app-audio")
        releaseRouteToSystem()
    }

    private val deferredYieldCheck = Runnable {
        if (!UsbExclusive.isFocusYielded()) return@Runnable
        if (PlaybackAnchor.isPlaying() || isOtherMediaAudible()) {
            // The grabber is really playing: stay yielded, pause our player.
            pauseForFocus()
            PlaybackAnchor.setDirect(this, false)
            PlaybackAnchor.setPlaying(this, false)
            Log.i("LikePodUsb", "mode mixer reason=yielded-dac-to-system")
            mediaChannel?.invokeMethod("onAudioFocusLost", null)
            mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
            startYieldWatch()
            return@Runnable
        }
        // Nothing audible came out of the grab. Take the DAC straight back:
        // the endpoint is fresh (post-reset), so the direct stream reopens
        // without losing a beat of the user's playlist.
        PlaybackFocus.clearDeferredLoss()
        Log.i("LikePodUsb", "yield reverted reason=no-audible-other")
        attemptAutoResume("empty-grab", requireHeldFocus = false)
    }

    /** True when another app's media player is emitting right now. */
    private fun isOtherMediaAudible(): Boolean {
        return try {
            (getSystemService(Context.AUDIO_SERVICE) as AudioManager).isMusicActive
        } catch (_: Throwable) {
            // Cannot tell; prefer yielding over stealing.
            true
        }
    }

    /**
     * The observation window has confirmed the grabber is audible. The DAC
     * was already released and reset by [releaseUsbForHandoff]; pause our
     * player and start the quiet-output watch that brings playback back.
     */
    private fun performYieldToOtherApp() {
        PlaybackFocus.clearDeferredLoss()
        if (UsbExclusive.isFocusYielded()) {
            pauseForFocus()
            PlaybackAnchor.setDirect(this, false)
            PlaybackAnchor.setPlaying(this, false)
            Log.i("LikePodUsb", "mode mixer reason=yielded-dac-to-system")
            mediaChannel?.invokeMethod("onAudioFocusLost", null)
            mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
            startYieldWatch()
            return
        }
        // The observation path released the DAC but the grabber went quiet
        // before this late confirmation ran; keep the release and resume.
        Log.i("LikePodUsb", "yield confirmed but output quiet, resuming")
        attemptAutoResume("late-confirm", requireHeldFocus = false)
    }

    /**
     * Focus came back. If LikePod was audible when it yielded, resume after a
     * quiet period: the other app may grab focus again right away, and a
     * resume inside that window would fight it for the DAC. The wait is
     * cancelled by any new loss, a user pause, or returning to the foreground;
     * playback then waits for the user as before.
     */
    private fun regainFocus() {
        val autoResume = resumeAfterFocus
        resumeAfterFocus = false
        UsbExclusive.focusReturned()
        stopYieldWatch()
        // The grabber released focus before its observation window closed:
        // it never became audible, so nothing to yield to.
        cancelDeferredYield()
        if (!autoResume) {
            Log.i("LikePodUSB", "focus gain, waiting for the user to press play")
            mediaChannel?.invokeMethod("onAudioFocusGained", false)
            return
        }
        Log.i("LikePodUSB", "focus gain, auto resume armed")
        scheduleFocusResume()
    }

    private fun scheduleFocusResume() {
        cancelFocusResume()
        val task = Runnable { attemptAutoResume("focus-gain", requireHeldFocus = true) }
        focusResumeRunnable = task
        mainHandler.postDelayed(task, focusResumeDelayMs)
    }

    private fun cancelFocusResume() {
        focusResumeRunnable?.let { mainHandler.removeCallbacks(it) }
        focusResumeRunnable = null
    }

    /** Cancels a pending loss-observation without yielding. */
    private fun cancelDeferredYield() {
        mainHandler.removeCallbacks(deferredYieldCheck)
        PlaybackFocus.clearDeferredLoss()
    }

    /**
     * Resumes after a yield. The focus-gain path waits out the debounce and
     * still holds focus; the yield watch calls this once the output has been
     * quiet and must take focus back itself instead of requiring it held.
     */
    private fun attemptAutoResume(trigger: String, requireHeldFocus: Boolean) {
        if (PlaybackAnchor.isPlaying()) {
            Log.i("LikePodUSB", "auto resume skipped, already playing")
            return
        }
        if (isCallActive()) {
            Log.i("LikePodUSB", "auto resume skipped, call in progress")
            return
        }
        // A feed bouncing focus (gain then another loss within the debounce)
        // must not disarm the resume: the loss path decides yielding on its
        // own through the observation window. Requeue instead of dropping.
        if (requireHeldFocus && (!PlaybackFocus.isGranted() || UsbExclusive.isFocusYielded())) {
            Log.i("LikePodUSB", "auto resume deferred, focus in flight")
            scheduleFocusResume()
            return
        }
        // The other app may still be playing on the mixer path. Resuming
        // under it would reclaim the DAC and silence it mid-video; wait
        // for the output to be quiet first. isMusicActive misses feed video
        // tracks between clips, so require the quiet check twice in a row.
        if (trigger != "yield-watch" && isOtherMediaAudible()) {
            Log.i("LikePodUSB", "auto resume deferred, other app still audible")
            scheduleFocusResume()
            return
        }
        if (trigger != "yield-watch") {
            quietCheckCount++
            if (quietCheckCount < 2) {
                Log.i("LikePodUSB", "auto resume deferred, quiet check $quietCheckCount/2")
                scheduleFocusResume()
                return
            }
            quietCheckCount = 0
        }
        // If the last auto-resume was reclaimed quickly, this session is a
        // feed binge: auto-resuming again only re-triggers the yield+reset
        // ping-pong that keeps breaking the other app's audio. Stand down
        // until the user presses play or the app returns to the foreground.
        val now = SystemClock.elapsedRealtime()
        if (now - lastAutoResumeAt < pingPongWindowMs && now - lastYieldAt < pingPongWindowMs) {
            Log.i("LikePodUSB", "auto resume stood down, ping-pong detected")
            resumeAfterFocus = false
            mediaChannel?.invokeMethod("onAudioFocusGained", false)
            return
        }
        lastAutoResumeAt = now
        // Mirror what a manual pause/play does before the sound comes back:
        // re-request focus (clears the system's focus-loss enforcement on
        // our players) and re-route the player's tracks while still paused.
        // Playing on the held request alone left the resumed track silent
        // on the mixer path.
        val granted = holdAudioFocus(force = true)
        if (!granted) {
            Log.i("LikePodUSB", "auto resume skipped, focus not granted")
            return
        }
        resumeAfterFocus = false
        UsbExclusive.focusReturned()
        if (!UsbExclusive.current.active) {
            releaseRouteToSystem()
        }
        Log.i("LikePodUSB", "auto resume trigger=$trigger")
        mediaChannel?.invokeMethod("onAudioFocusGained", true)
    }

    /**
     * Feed apps keep their focus request while the player sits idle, so the
     * regained-focus dispatch never arrives when they stop playing. While
     * yielded, watch the system's player list instead: after a couple of
     * quiet ticks with no other app running an active media player, the
     * output is free and playback can resume. Needs MODIFY_AUDIO_SETTINGS
     * (declared in the manifest).
     */
    private fun startYieldWatch() {
        stopYieldWatch()
        if (!resumeAfterFocus) return
        yieldClearTicks = 0
        Log.i("LikePodUSB", "yield watch started")
        scheduleYieldTick()
    }

    private fun scheduleYieldTick() {
        val task = Runnable { yieldTick() }
        yieldWatchRunnable = task
        mainHandler.postDelayed(task, yieldWatchIntervalMs)
    }

    private fun stopYieldWatch() {
        yieldWatchRunnable?.let { mainHandler.removeCallbacks(it) }
        yieldWatchRunnable = null
    }

    private fun yieldTick() {
        yieldWatchRunnable = null
        if (!resumeAfterFocus || !UsbExclusive.isFocusYielded()) {
            Log.i("LikePodUSB", "yield watch stopped, state moved on")
            return
        }
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (audioManager.mode != AudioManager.MODE_NORMAL) {
            yieldClearTicks = 0
            scheduleYieldTick()
            return
        }
        if (otherMediaActive(audioManager)) {
            yieldClearTicks = 0
            scheduleYieldTick()
            return
        }
        yieldClearTicks++
        Log.i("LikePodUSB", "yield watch quiet $yieldClearTicks/$yieldWatchQuietTicks")
        if (yieldClearTicks < yieldWatchQuietTicks) {
            scheduleYieldTick()
            return
        }
        Log.i("LikePodUSB", "yield watch: output quiet, resuming")
        attemptAutoResume("yield-watch", requireHeldFocus = false)
    }

    private fun otherMediaActive(audioManager: AudioManager): Boolean {
        return try {
            // The playback-config APIs are hidden; isMusicActive() is public
            // and answers the same question for media playback: is any app
            // (including this one, which is paused here) emitting music now.
            audioManager.isMusicActive
        } catch (e: Throwable) {
            // Cannot see other players: assume blocked rather than steal.
            true
        }
    }

    private fun isCallActive(): Boolean {
        return try {
            (getSystemService(Context.AUDIO_SERVICE) as AudioManager).mode != AudioManager.MODE_NORMAL
        } catch (_: Throwable) {
            false
        }
    }

    private fun releaseRouteToSystem() {
        callUsbHook(null)
        pointAudioTracks(null)
        clearMixer(getSystemService(Context.AUDIO_SERVICE) as AudioManager)
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        boundEngine = flutterEngine
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        mediaChannel = channel
        UsbExclusive.install(mainHandler, this) {
            mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
        }
        WheelSounds.prepare(this)
        registerUsbReceiver()
        registerOutputWatcher()

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSongs" -> {
                    try {
                        val songs = fetchSongs()
                        result.success(songs)
                    } catch (e: Exception) {
                        result.error("QUERY_ERROR", e.message, null)
                    }
                }
                "getArtwork" -> {
                    val albumId = call.argument<Number>("albumId")?.toLong()
                    if (albumId != null) {
                        try {
                            val bytes = fetchArtwork(albumId)
                            result.success(bytes)
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    } else {
                        result.success(null)
                    }
                }
                "getBatteryLevel" -> {
                    try {
                        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                        result.success(if (level in 0..100) level else 100)
                    } catch (e: Exception) {
                        result.success(100)
                    }
                }
                "getVolume" -> {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val ratio = if (max > 0) current.toDouble() / max.toDouble() else 0.7
                        result.success(ratio)
                    } catch (e: Exception) {
                        result.success(0.7)
                    }
                }
                "setVolume" -> {
                    try {
                        val volume = call.argument<Double>("volume") ?: 0.5
                        val writeSystem = call.argument<Boolean>("writeSystem") != false
                        val applied = UsbExclusive.setWheelVolume(volume.toFloat())
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val target = (volume * max).roundToInt().coerceIn(0, max)
                        // Direct PCM already follows the wheel curve. Writing
                        // STREAM_MUSIC as well is a second attenuation on the
                        // mixer path, and it must not run at startup.
                        if (!UsbExclusive.current.active && writeSystem && max > 0) {
                            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                        }
                        if (UsbExclusive.current.active && applied == null) {
                            UsbExclusive.stop()
                            mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
                        }
                        if (applied != null) {
                            result.success(gainPayload(applied))
                        } else {
                            val reported = if (max > 0) target.toDouble() / max.toDouble() else volume
                            result.success(reported)
                        }
                    } catch (e: Exception) {
                        result.error("VOLUME_ERROR", e.message, null)
                    }
                }
                "probeOutput" -> {
                    try {
                        result.success(probeOutput())
                    } catch (e: Exception) {
                        result.success(emptyMap<String, Any?>())
                    }
                }
                "probeTrack" -> {
                    val uri = call.argument<String>("uri")
                    try {
                        result.success(if (uri.isNullOrEmpty()) emptyMap<String, Any?>() else probeTrack(uri))
                    } catch (e: Exception) {
                        result.success(emptyMap<String, Any?>())
                    }
                }
                "listOutputSinks" -> {
                    try {
                        result.success(listOutputSinks())
                    } catch (e: Exception) {
                        result.success(mapOf("outputSampleRate" to null, "sinks" to emptyList<Any>()))
                    }
                }
                "applyPreferredDevice" -> {
                    val deviceId = call.argument<Number>("deviceId")?.toInt()
                    val sampleRate = call.argument<Number>("sampleRate")?.toInt() ?: 0
                    val force = call.argument<Boolean>("force") == true
                    val highQuality = call.argument<Boolean>("highQuality") != false
                    try {
                        result.success(applyPreferredDevice(deviceId, sampleRate, force, highQuality))
                    } catch (e: Exception) {
                        result.success(mapOf("applied" to false, "mixerAccepted" to false))
                    }
                }
                "holdPlayback" -> {
                    val user = call.argument<Boolean>("user") == true
                    if (!user && (PlaybackFocus.isYielded() || UsbExclusive.isFocusYielded())) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    if (!user && PlaybackFocus.otherAppHasAudio()) {
                        // Re-requesting here would steal the DAC back from the
                        // app that just took focus. User play clears that flag.
                        Log.i("LikePodUSB", "holdPlayback skipped, another app has audio")
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    if (user) {
                        resumeAfterFocus = false
                        focusPauses = 0
                        cancelFocusResume()
                        stopYieldWatch()
                        PlaybackFocus.userWantsPlayback()
                    }
                    // A user play always re-requests focus. After a yield,
                    // holding-from-records alone left the resumed track
                    // silent on the mixer path; the fresh request clears
                    // the system's focus-loss state.
                    val granted = holdAudioFocus(force = user)
                    val blocked = !granted && PlaybackFocus.otherAppHasAudio()
                    Log.i("LikePodUSB", "holdPlayback user=$user granted=$granted blocked=$blocked yielded=${UsbExclusive.isFocusYielded()}")
                    if (blocked) {
                        // DELAYED: a call or another app still holds focus.
                        // A plain refusal is not that case; lifeme can refuse
                        // while the DAC is free, and playback may continue.
                        if (user) {
                            PlaybackAnchor.setPlaying(this, false)
                            if (UsbExclusive.current.active) {
                                UsbExclusive.stop()
                                releaseRouteToSystem()
                            }
                        }
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    PlaybackAnchor.setPlaying(this, true)
                    UsbExclusive.focusReturned()
                    if (user) {
                        UsbExclusive.clearFailure()
                        Log.i("LikePodUsb", "play granted, direct claim allowed")
                    }
                    result.success(true)
                }
                "userPause" -> {
                    resumeAfterFocus = false
                    focusPauses = 0
                    cancelFocusResume()
                    stopYieldWatch()
                    cancelDeferredYield()
                    PlaybackAnchor.setPlaying(this, false)
                    PlaybackFocus.abandon(this)
                    UsbExclusive.stop()
                    releaseRouteToSystem()
                    mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
                    result.success(true)
                }
                "moveTaskToBack" -> {
                    result.success(moveTaskToBack(true))
                }
                "releasePlayback" -> {
                    val userStopped = call.argument<Boolean>("userStopped") == true
                    if (!userStopped) {
                        if (focusPauses > 0) {
                            focusPauses--
                            if (UsbExclusive.isFocusYielded()) {
                                PlaybackAnchor.setPlaying(this, false)
                            }
                        }
                        // A pause while we still hold focus is not the user
                        // giving the DAC away. Leave the claim and the grant.
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    focusPauses = 0
                    resumeAfterFocus = false
                    cancelFocusResume()
                    stopYieldWatch()
                    cancelDeferredYield()
                    PlaybackAnchor.setPlaying(this, false)
                    PlaybackFocus.abandon(this)
                    if (UsbExclusive.current.active || UsbExclusive.isFocusYielded()) {
                        UsbExclusive.stop()
                    }
                    releaseRouteToSystem()
                    result.success(true)
                }
                "focusHeld" -> {
                    // The keep-direct caller must not undercut the yield or
                    // the debounced auto-resume: a feed app that grabs focus
                    // and bounces it back within milliseconds used to make
                    // LikePod restart playback mid-handoff and fight the
                    // other app for the DAC.
                    result.success(
                        PlaybackFocus.mayUseUsb() &&
                            !UsbExclusive.isFocusYielded() &&
                            focusResumeRunnable == null &&
                            yieldWatchRunnable == null,
                    )
                }
                "prepareWheelSound" -> {
                    WheelSounds.prepare(this)
                    result.success(true)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    // HyperOS freezes this process ~20s after audio pauses
                    // (even with a foreground service), which kills the
                    // background auto-resume. The battery whitelist keeps
                    // the process unfrozen.
                    try {
                        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                            val intent = Intent(
                                android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName"),
                            )
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "playWheelSound" -> {
                    val kind = call.argument<String>("kind") ?: "tick"
                    result.success(WheelSounds.play(this, kind))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun fetchSongs(): List<Map<String, Any>> {
        val songList = mutableListOf<Map<String, Any>>()
        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.ALBUM_ID
        )

        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.DURATION} >= 10000"
        val sortOrder = "${MediaStore.Audio.Media.TITLE} ASC"

        contentResolver.query(uri, projection, selection, null, sortOrder)?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
            val albumIdCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idCol)
                val title = cursor.getString(titleCol) ?: "Unknown Title"
                val artist = cursor.getString(artistCol) ?: "Unknown Artist"
                val album = cursor.getString(albumCol) ?: "Unknown Album"
                val duration = cursor.getLong(durationCol)
                val path = cursor.getString(dataCol) ?: ""
                val albumId = cursor.getLong(albumIdCol)

                val contentUri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id).toString()

                val item = mapOf(
                    "id" to id,
                    "title" to title,
                    "artist" to artist,
                    "album" to album,
                    "duration" to duration,
                    "path" to path,
                    "contentUri" to contentUri,
                    "albumId" to albumId
                )
                songList.add(item)
            }
        }
        return songList
    }

    private fun probeOutput(): Map<String, Any?> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val reportedRate = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()
        val device = currentOutputDevice(audioManager)
        val rates = device?.sampleRates?.filter { it > 0 }?.distinct()?.sorted() ?: emptyList()
        val depths = mutableListOf<Int>()
        device?.encodings?.forEach { encoding ->
            encodingToBitDepth(encoding)?.let { depths.add(it) }
        }
        depths.sort()
        // just_audio submits 16-bit PCM into the mixer. Report 16 only when the
        // device lists that encoding. Do not promote 24/32 as the open path.
        val pathDepth = if (depths.contains(16)) 16 else null
        return mapOf(
            "sampleRate" to reportedRate,
            "bitDepth" to pathDepth,
            "route" to (device?.let { routeLabel(it.type) } ?: ""),
            "sampleRates" to rates,
            "bitDepths" to depths
        )
    }

    private fun currentOutputDevice(audioManager: AudioManager): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val method = AudioManager::class.java.getMethod(
                    "getDevicesForAttributes",
                    AudioAttributes::class.java
                )
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
                val routed = method.invoke(audioManager, attrs) as? Array<*>
                val first = routed?.firstOrNull() as? AudioDeviceInfo
                if (first != null) return first
            } catch (_: Exception) {
            }
        }
        val sinks = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { it.isSink }
        if (sinks.isEmpty()) return null
        val preferred = listOf(
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        )
        for (type in preferred) {
            sinks.firstOrNull { it.type == type }?.let { return it }
        }
        return sinks.first()
    }

    private fun registerOutputWatcher() {
        if (deviceCallbackRegistered) return
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                scheduleOutputEvent()
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                scheduleOutputEvent()
            }
        }
        outputCallback = callback
        audioManager.registerAudioDeviceCallback(callback, mainHandler)
        deviceCallbackRegistered = true
    }

    private fun scheduleOutputEvent() {
        deviceEvent?.let { mainHandler.removeCallbacks(it) }
        val task = Runnable {
            mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
        }
        deviceEvent = task
        mainHandler.postDelayed(task, 200)
    }

    private fun listOutputSinks(): Map<String, Any?> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val reportedRate = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()
        val routedIds = routedOutputIds(audioManager)
        val sinks = mutableListOf<Map<String, Any?>>()
        audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).forEach { device ->
            if (!device.isSink) return@forEach
            val rates = mutableListOf<Int>()
            device.sampleRates.forEach { rate ->
                if (rate > 0 && !rates.contains(rate)) rates.add(rate)
            }
            rates.sort()
            val encodings = mutableListOf<Int>()
            device.encodings.forEach { encoding -> encodings.add(encoding) }
            sinks.add(
                mapOf(
                    "id" to device.id,
                    "name" to sinkName(device),
                    "type" to device.type,
                    "sampleRates" to rates,
                    "encodings" to encodings,
                    "routed" to routedIds.contains(device.id)
                )
            )
        }
        UsbExclusive.syntheticSink()?.let { sinks.add(it) }
        return mapOf("outputSampleRate" to reportedRate, "sinks" to sinks)
    }

    private fun routedOutputIds(audioManager: AudioManager): Set<Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return emptySet()
        return try {
            val method = AudioManager::class.java.getMethod(
                "getDevicesForAttributes",
                AudioAttributes::class.java
            )
            val routed = method.invoke(audioManager, mediaAttributes()) as? Array<*>
            val ids = mutableSetOf<Int>()
            routed?.forEach { item ->
                val info = item as? AudioDeviceInfo ?: return@forEach
                ids.add(info.id)
            }
            ids
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun findOutputDevice(audioManager: AudioManager, deviceId: Int?): AudioDeviceInfo? {
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { it.isSink }
        if (deviceId != null) {
            outputs.firstOrNull { it.id == deviceId }?.let { return it }
        }
        return outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_USB_HEADSET }
            ?: outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_USB_DEVICE }
    }

    private fun sinkName(device: AudioDeviceInfo): String {
        val product = device.productName?.toString()?.trim().orEmpty()
        if (product.isNotEmpty()) return product
        return routeLabel(device.type)
    }

    private fun mediaAttributes(): AudioAttributes {
        return AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
    }

    /// Points playback at a USB DAC. A direct isochronous stream is preferred.
    /// If that cannot be opened, the existing player is aimed at the device and
    /// Android 14+ may be asked for a no-resample mixer. Playback is not stopped.
    private fun applyPreferredDevice(
        deviceId: Int?,
        sampleRate: Int,
        force: Boolean = false,
        highQuality: Boolean = true,
    ): Map<String, Any> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val usbHost = UsbExclusive.audioPresent(this)
        if (force) {
            UsbExclusive.clearFailure()
        }
        if (UsbExclusive.isFocusYielded()) {
            Log.i("LikePodUsb", "route sync skipped reason=yielded")
            if (UsbExclusive.current.active) {
                UsbExclusive.releaseForFocus("route-sync-yielded")
            }
            callUsbHook(null)
            pointAudioTracks(null)
            clearMixer(audioManager)
            return resultMap(
                applied = false,
                mixerAccepted = false,
                verifiedUsb = false,
                detail = "已让出 · 系统混音",
            )
        }
        Log.i(
            "LikePodUSB",
            "route sync usbHost=$usbHost deviceId=$deviceId rate=$sampleRate playing=${PlaybackAnchor.isPlaying()}",
        )
        if (!playbackOwnsDac()) {
            Log.i("LikePodUsb", "route sync while not playing, DAC released")
            if (UsbExclusive.current.active) {
                if (UsbExclusive.isFocusYielded()) {
                    UsbExclusive.releaseForFocus("route-sync-not-playing")
                } else {
                    UsbExclusive.stop("route-sync-not-playing")
                }
            }
            // A previous process that died holding the exclusive claim
            // leaves the kernel driver detached, silencing the DAC for
            // every app until replug. Rebind it while we hold nothing.
            UsbExclusive.rebindKernelDriver(this)
            callUsbHook(null)
            pointAudioTracks(null)
            clearMixer(audioManager)
            followUps = 0
            return resultMap(
                applied = false,
                mixerAccepted = false,
                verifiedUsb = false,
                detail = "未播放 · 未占用 USB",
            )
        }
        if (deviceId == null && !usbHost) {
            Log.i("LikePodUsb", "release reason=no-usb-device")
            UsbExclusive.stop("no-usb-device")
            val hook = callUsbHook(null)
            val tracks = pointAudioTracks(null)
            clearMixer(audioManager)
            followUps = 0
            return resultMap(
                applied = hook.ok || tracks.accepted > 0,
                mixerAccepted = false,
                verifiedUsb = false,
                detail = "已清除 · ${hook.text} · ${tracks.text}"
            )
        }
        val wanted = if (sampleRate > 0) sampleRate else 44100
        // Standard mode never claims the DAC exclusively; drop an active
        // claim so the mixer path below takes over.
        val direct = if (highQuality) {
            UsbExclusive.tryStart(this, wanted)
        } else {
            if (UsbExclusive.current.active) {
                Log.i("LikePodUsb", "release reason=standard-mode")
                UsbExclusive.stop("standard-mode")
            }
            UsbExclusive.Status.idle
        }
        if (direct.active) {
            clearMixer(audioManager)
            val sinkDirect = try {
                val cls = Class.forName("com.ryanheise.just_audio.UsbDirectSink")
                cls.getMethod("inDirect").invoke(null) == true
            } catch (_: Throwable) {
                true
            }
            if (direct.fresh || !sinkDirect) {
                Log.i("LikePodUsb", "mode direct reason=route-sync fresh=${direct.fresh}")
                flushPlayerSink()
            }
            followUps = 0
            return directMap(direct)
        }
        Log.i("LikePodUsb", "mode mixer reason=${direct.detail}")
        val device = findOutputDevice(audioManager, deviceId)
        if (device == null) {
            callUsbHook(null)
            pointAudioTracks(null)
            clearMixer(audioManager)
            maybeFollowUp(wantedUsb = usbHost, verified = false)
            val why = direct.detail.ifEmpty {
                if (deviceId == null) "失败 · 没有系统输出设备" else "失败 · 设备$deviceId 已不在输出列表"
            }
            return resultMap(
                applied = false,
                mixerAccepted = false,
                verifiedUsb = false,
                detail = why,
                direct = direct,
            )
        }
        val hook = callUsbHook(device)
        val reflected = reflectPreferredDevice(device)
        val tracks = pointAudioTracks(device)
        val mediaRoute = routedMediaLabel(audioManager)
        val verified = tracks.usb || mediaRoute == "USB"
        val applied = hook.ok || reflected.ok || tracks.accepted > 0
        val mixer = if (applied && sampleRate > 0) {
            requestMixer(audioManager, device, sampleRate)
        } else {
            if (!applied || (mixerDeviceId != null && mixerDeviceId != device.id)) {
                clearMixer(audioManager)
            }
            MixerRequest(false, false, "")
        }
        val head = if (applied) "已设置" else "失败"
        val mixerText = if (mixer.detail.isEmpty()) "" else " · ${mixer.detail}"
        val detail = "$head · ${hook.text} · 反射${reflected.text} · ${tracks.text} · 媒体=$mediaRoute$mixerText"
        Log.i(TAG, "USB route $detail")
        maybeFollowUp(wantedUsb = true, verified = verified || direct.active)
        return resultMap(applied, mixer.accepted, verified, detail, direct, mixer.bitPerfect)
    }

    private fun directMap(status: UsbExclusive.Status): Map<String, Any> {
        return resultMap(
            applied = true,
            mixerAccepted = false,
            verifiedUsb = true,
            detail = status.detail,
            direct = status,
        )
    }

    private fun resultMap(
        applied: Boolean,
        mixerAccepted: Boolean,
        verifiedUsb: Boolean,
        detail: String,
        direct: UsbExclusive.Status = UsbExclusive.Status.idle,
        mixerBitPerfect: Boolean = false,
    ): Map<String, Any> {
        return mapOf(
            "applied" to applied,
            "mixerAccepted" to mixerAccepted,
            "verifiedUsb" to verifiedUsb,
            "detail" to detail,
            "directActive" to direct.active,
            "directRate" to direct.rate,
            "directBitDepth" to direct.bitDepth,
            "directResampled" to direct.resampled,
            "directDetail" to direct.detail,
            "directName" to direct.name,
            "directGain" to direct.gain,
            "directUi" to direct.ui,
            "mixerBitPerfect" to mixerBitPerfect,
            "backgroundPath" to PlaybackAnchor.backgroundPath,
            "backgroundMixer" to UsbExclusive.isDirectBlocked(),
        )
    }

    private fun flushPlayerSink() {
        try {
            val cls = Class.forName("com.ryanheise.just_audio.UsbPreferredDevice")
            cls.getMethod("flushToApplySink").invoke(null)
        } catch (e: Exception) {
            Log.i(TAG, "USB sink flush skipped: ${e.message}")
        }
    }

    private fun registerUsbReceiver() {
        if (usbReceiverRegistered) {
            return
        }
        val filter = IntentFilter().apply {
            addAction(UsbExclusive.ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(VOLUME_CHANGED_ACTION)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(usbReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(usbReceiver, filter)
        }
        usbReceiverRegistered = true
    }

    private fun usbDeviceName(intent: Intent): String? {
        val device = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
        return device?.deviceName
    }

    override fun onDestroy() {
        cancelFocusResume()
        stopYieldWatch()
        outputCallback?.let { callback ->
            try {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.unregisterAudioDeviceCallback(callback)
            } catch (_: Exception) {
            }
        }
        outputCallback = null
        deviceCallbackRegistered = false
        if (usbReceiverRegistered) {
            try {
                unregisterReceiver(usbReceiver)
            } catch (_: Exception) {
            }
            usbReceiverRegistered = false
        }
        super.onDestroy()
    }

    private fun callUsbHook(device: AudioDeviceInfo?): HookResult {
        return try {
            val cls = Class.forName("com.ryanheise.just_audio.UsbPreferredDevice")
            val method = cls.getMethod("setPreferred", AudioDeviceInfo::class.java)
            val raw = method.invoke(null, device) as? String ?: "空结果"
            when {
                raw.startsWith("ok:") -> HookResult(true, "播放器${raw.removePrefix("ok:")}")
                raw.startsWith("fail:") -> HookResult(false, raw.removePrefix("fail:"))
                else -> HookResult(false, raw)
            }
        } catch (e: ClassNotFoundException) {
            HookResult(false, "未编入播放器钩子")
        } catch (e: Exception) {
            val cause = (e as? java.lang.reflect.InvocationTargetException)?.cause ?: e
            HookResult(false, cause.javaClass.simpleName + ":" + (cause.message ?: ""))
        }
    }

    /// Backup when the hook has not seen a player yet. Finds objects by the
    /// public method or by AudioTrack type, not by just_audio field names.
    private fun reflectPreferredDevice(device: AudioDeviceInfo?): ReflectResult {
        val found = scanPlayers()
        if (found.players.isEmpty()) {
            return ReflectResult(false, "播放器0/插件${found.plugins}")
        }
        var ok = 0
        val errors = StringBuilder()
        for (player in found.players) {
            val method = preferredDeviceMethod(player) ?: continue
            try {
                method.invoke(player, device)
                ok++
            } catch (e: Exception) {
                val cause = (e as? java.lang.reflect.InvocationTargetException)?.cause ?: e
                if (errors.length < 60) {
                    if (errors.isNotEmpty()) errors.append(' ')
                    errors.append(cause.javaClass.simpleName)
                }
            }
        }
        val text = if (ok > 0) ok.toString() else errors.toString().ifEmpty { "0" }
        return ReflectResult(ok > 0, text)
    }

    private class HookResult(val ok: Boolean, val text: String)
    private class ReflectResult(val ok: Boolean, val text: String)
    private class TrackResult(val accepted: Int, val usb: Boolean, val text: String)

    private fun pointAudioTracks(device: AudioDeviceInfo?): TrackResult {
        val tracks = scanPlayers().tracks
        if (tracks.isEmpty()) return TrackResult(0, false, "音轨0")
        var accepted = 0
        var rejected = 0
        var sawUsb = false
        for (track in tracks) {
            try {
                if (track.setPreferredDevice(device)) accepted++ else rejected++
                val routed = track.routedDevice
                if (routed != null && isUsbType(routed.type)) sawUsb = true
            } catch (e: Exception) {
                rejected++
            }
        }
        val routedLabel = tracks.firstNotNullOfOrNull { it.routedDevice?.let { info -> routeLabel(info.type) } }
            ?: "未建立"
        return TrackResult(accepted, sawUsb, "音轨$accepted/$rejected 实际=$routedLabel")
    }

    private class Scan(val plugins: Int, val players: List<Any>, val tracks: List<AudioTrack>)

    private fun scanPlayers(): Scan {
        val engine = boundEngine ?: return Scan(0, emptyList(), emptyList())
        val players = mutableListOf<Any>()
        val tracks = mutableListOf<AudioTrack>()
        val seen = Collections.newSetFromMap(IdentityHashMap<Any, Boolean>())
        val plugins = pluginInstances(engine)
        for (plugin in plugins) {
            walkGraph(plugin, players, tracks, seen, 0)
        }
        return Scan(plugins.size, players, tracks.distinct())
    }

    private fun pluginInstances(engine: FlutterEngine): List<Any> {
        val registry = try {
            engine.plugins
        } catch (_: Exception) {
            return emptyList()
        }
        val found = LinkedHashSet<Any>()
        var cls: Class<*>? = registry.javaClass
        while (cls != null && cls != Any::class.java) {
            for (field in cls.declaredFields) {
                if (!Map::class.java.isAssignableFrom(field.type)) continue
                try {
                    field.isAccessible = true
                    val map = field.get(registry) as? Map<*, *> ?: continue
                    for (value in map.values) {
                        if (value is FlutterPlugin) found.add(value)
                    }
                } catch (_: Exception) {
                }
            }
            cls = cls.superclass
        }
        return found.toList()
    }

    private fun walkGraph(
        obj: Any,
        players: MutableList<Any>,
        tracks: MutableList<AudioTrack>,
        seen: MutableSet<Any>,
        depth: Int
    ) {
        if (depth > 10 || seen.size > 2500 || !seen.add(obj)) return
        if (obj is AudioTrack) {
            tracks.add(obj)
            return
        }
        if (preferredDeviceMethod(obj) != null) players.add(obj)
        var cls: Class<*>? = obj.javaClass
        while (cls != null && cls != Any::class.java) {
            for (field in cls.declaredFields) {
                if (Modifier.isStatic(field.modifiers) || field.isSynthetic) continue
                if (field.type.isPrimitive) continue
                val value = try {
                    field.isAccessible = true
                    field.get(obj)
                } catch (_: Exception) {
                    null
                } ?: continue
                when (value) {
                    is AudioTrack -> if (seen.add(value)) tracks.add(value)
                    is Map<*, *> -> {
                        for (entry in value.values) {
                            if (entry != null && shouldWalk(entry)) {
                                walkGraph(entry, players, tracks, seen, depth + 1)
                            }
                        }
                    }
                    is Array<*> -> {
                        for (entry in value) {
                            if (entry != null && shouldWalk(entry)) {
                                walkGraph(entry, players, tracks, seen, depth + 1)
                            }
                        }
                    }
                    is Iterable<*> -> {
                        for (entry in value) {
                            if (entry != null && shouldWalk(entry)) {
                                walkGraph(entry, players, tracks, seen, depth + 1)
                            }
                        }
                    }
                    else -> if (shouldWalk(value)) {
                        walkGraph(value, players, tracks, seen, depth + 1)
                    }
                }
            }
            cls = cls.superclass
        }
    }

    private fun shouldWalk(value: Any): Boolean {
        if (value is AudioTrack) return true
        if (preferredDeviceMethod(value) != null) return true
        val name = value.javaClass.name
        if (name.startsWith("android.")) return false
        if (name.startsWith("java.")) return false
        if (name.startsWith("javax.")) return false
        if (name.startsWith("kotlin.")) return false
        if (name.startsWith("kotlinx.")) return false
        if (name.startsWith("io.flutter.")) return false
        if (name.startsWith("com.google.")) return false
        if (name.startsWith("androidx.") && !name.startsWith("androidx.media3.")) return false
        return true
    }

    private fun preferredDeviceMethod(player: Any): java.lang.reflect.Method? {
        return player.javaClass.methods.firstOrNull { candidate ->
            candidate.name == "setPreferredAudioDevice" && candidate.parameterTypes.size == 1
        }
    }

    private fun routedMediaLabel(audioManager: AudioManager): String {
        val ids = routedOutputIds(audioManager)
        if (ids.isEmpty()) return "未报告"
        val match = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull { it.isSink && ids.contains(it.id) }
        return match?.let { routeLabel(it.type) } ?: "未报告"
    }

    private fun isUsbType(type: Int): Boolean {
        return type == AudioDeviceInfo.TYPE_USB_DEVICE || type == AudioDeviceInfo.TYPE_USB_HEADSET
    }

    private var followUps = 0

    private fun maybeFollowUp(wantedUsb: Boolean, verified: Boolean) {
        if (!wantedUsb || verified) {
            followUps = 0
            return
        }
        if (followUps >= 2) return
        followUps++
        mainHandler.postDelayed({
            mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
        }, 450)
    }

    private class MixerRequest(
        val accepted: Boolean,
        val bitPerfect: Boolean,
        val detail: String,
    )

    /// Asks Android 14+ to avoid resampling when the USB HAL allows it.
    /// A matching read-back is still not a measurement at the DAC.
    private fun requestMixer(
        audioManager: AudioManager,
        device: AudioDeviceInfo,
        sampleRate: Int
    ): MixerRequest {
        if (Build.VERSION.SDK_INT < 34) {
            return MixerRequest(false, false, "失败 · 需要 Android 14 才有无重采样混音")
        }
        return try {
            val supported = audioManager.getSupportedMixerAttributes(device)
            val match = supported.firstOrNull { attrs ->
                attrs.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT &&
                    attrs.format.sampleRate == sampleRate &&
                    (attrs.format.encoding == AudioFormat.ENCODING_PCM_16BIT ||
                        attrs.format.encoding == AudioFormat.ENCODING_INVALID)
            }
            val requested = match ?: AudioMixerAttributes.Builder(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            ).setMixerBehavior(AudioMixerAttributes.MIXER_BEHAVIOR_DEFAULT).build()
            val ok = audioManager.setPreferredMixerAttributes(mediaAttributes(), device, requested)
            if (!ok) {
                return MixerRequest(false, false, "失败 · 系统拒绝混音属性")
            }
            mixerDeviceId = device.id
            val back = audioManager.getPreferredMixerAttributes(mediaAttributes(), device)
            val perfect = back != null &&
                back.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT &&
                back.format.sampleRate == sampleRate
            if (perfect) {
                MixerRequest(true, true, "已接受 · ${sampleRate}Hz · 无重采样")
            } else if (back?.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT) {
                MixerRequest(false, false, "失败 · 回读 ${back.format.sampleRate}Hz")
            } else {
                MixerRequest(false, false, "已接受 · 仍是系统混音")
            }
        } catch (e: Exception) {
            MixerRequest(false, false, "失败 · ${e.javaClass.simpleName}")
        }
    }

    private fun clearMixer(audioManager: AudioManager) {
        val id = mixerDeviceId ?: return
        mixerDeviceId = null
        if (Build.VERSION.SDK_INT < 34) return
        try {
            val device = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { it.id == id } ?: return
            val method = AudioManager::class.java.getMethod(
                "clearPreferredMixerAttributes",
                AudioAttributes::class.java,
                AudioDeviceInfo::class.java
            )
            method.invoke(audioManager, mediaAttributes(), device)
        } catch (_: Exception) {
        }
    }

    private fun routeLabel(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "扬声器"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "有线耳机"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "蓝牙"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "USB"
        AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC -> "HDMI"
        else -> "其他"
    }

    private fun encodingToBitDepth(encoding: Int): Int? = when (encoding) {
        AudioFormat.ENCODING_PCM_16BIT -> 16
        AudioFormat.ENCODING_PCM_8BIT -> 8
        else -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                encoding == AudioFormat.ENCODING_PCM_24BIT_PACKED
            ) {
                24
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                encoding == AudioFormat.ENCODING_PCM_32BIT
            ) {
                32
            } else {
                null
            }
        }
    }

    private fun probeTrack(uriString: String): Map<String, Any?> {
        val extractor = MediaExtractor()
        try {
            if (uriString.startsWith("content://") || uriString.startsWith("file://")) {
                extractor.setDataSource(this, Uri.parse(uriString), null)
            } else {
                extractor.setDataSource(uriString)
            }
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("audio/")) continue
                val rate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                    format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                } else {
                    null
                }
                val bits = trackBitDepth(format)
                return mapOf("sampleRate" to rate, "bitDepth" to bits, "mime" to mime)
            }
        } finally {
            extractor.release()
        }
        return emptyMap()
    }

    private fun trackBitDepth(format: MediaFormat): Int? {
        if (format.containsKey("bits-per-sample")) {
            val bits = format.getInteger("bits-per-sample")
            if (bits > 0) return bits
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            format.containsKey(MediaFormat.KEY_PCM_ENCODING)
        ) {
            return encodingToBitDepth(format.getInteger(MediaFormat.KEY_PCM_ENCODING))
        }
        return null
    }

    private fun fetchArtwork(albumId: Long): ByteArray? {
        val artworkUri = ContentUris.withAppendedId(
            Uri.parse("content://media/external/audio/albumart"),
            albumId
        )
        return try {
            contentResolver.openInputStream(artworkUri)?.use { inputStream ->
                val buffer = ByteArrayOutputStream()
                val data = ByteArray(4096)
                var nRead: Int
                while (inputStream.read(data, 0, data.size).also { nRead = it } != -1) {
                    buffer.write(data, 0, nRead)
                }
                buffer.toByteArray()
            }
        } catch (e: Exception) {
            null
        }
    }
}
