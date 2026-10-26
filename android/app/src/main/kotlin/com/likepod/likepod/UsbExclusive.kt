package com.likepod.likepod

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.util.Log

/**
 * Opens a USB DAC from this app and streams PCM on its isochronous endpoint.
 * That bypasses AudioFlinger. It is not a verified bit-identical path: the
 * click-wheel volume and Android media volume are positions on a cubic
 * curve, then capped at −12 dBFS. The lower position wins, and that PCM
 * multiplier is applied when each USB packet is filled. A DAC that lacks
 * the track rate is resampled on purpose. If that gain cannot be set, or
 * the samples would be louder than the curve, the direct stream is closed
 * so playback can fall back to the system mixer.
 */
object UsbExclusive {
    private const val TAG = "LikePod"
    const val ACTION_USB_PERMISSION = "com.likepod.likepod.USB_PERMISSION"

    data class Status(
        val active: Boolean,
        val rate: Int,
        val bitDepth: Int,
        val resampled: Boolean,
        val detail: String,
        val name: String,
        /** PCM amplitude after the cubic curve and −12 dB ceiling. Negative when inactive. */
        val gain: Double = -1.0,
        /** Lower of the click-wheel and media-stream positions, before the curve. */
        val ui: Double = -1.0,
        /** True only for the open that just claimed the interface. */
        val fresh: Boolean = false,
    ) {
        companion object {
            val idle = Status(false, 0, 0, false, "", "")
        }
    }

    data class Heard(
        val ui: Float,
        val linear: Float,
    )

    @Volatile
    var current: Status = Status.idle
        private set

    private var connection: UsbDeviceConnection? = null
    private var device: UsbDevice? = null
    private val claimed = ArrayList<UsbInterface>()
    private var activeKey: String? = null
    private var failKey: String? = null
    private var cachedFail: String? = null
    private var permissionPending = false
    private var deniedName: String? = null
    private var handler: Handler? = null
    private var onChanged: (() -> Unit)? = null
    private var appContext: Context? = null

    /** Activity is stopped. The direct stream stays open across Home. */
    @Volatile
    var backgrounded: Boolean = false

    /**
     * True after another app took audio focus. [tryStart] will not claim the
     * interface again until [focusReturned].
     */
    @Volatile
    private var focusYielded = false

    /** True while [focusYielded] is holding the claim closed. */
    @Volatile
    private var directBlocked = false

    /**
     * Stream position held while the activity is stopped. A later write of
     * ~0 is ignored so an OEM mute cannot zero the direct-path PCM.
     */
    @Volatile
    private var pinnedStreamUi: Float? = null

    fun pinBackgroundGain(ui: Float) {
        pinnedStreamUi = ui.coerceIn(0f, 1f)
    }

    fun clearBackgroundGain() {
        pinnedStreamUi = null
    }

    fun reassertSuspend() {
        if (!UsbExclusiveNative.libraryLoaded() || !UsbExclusiveNative.isActive()) return
        try {
            UsbExclusiveNative.nativeForbidSuspend()
        } catch (_: Throwable) {
        }
    }

    fun isDirectBlocked(): Boolean = directBlocked

    fun isFocusYielded(): Boolean = focusYielded

    /**
     * Drops the isochronous claim and asks the kernel to bind its own driver
     * again. [tryStart] stays closed until [focusReturned].
     */
    fun releaseForFocus(reason: String = "yield") {
        Log.i("LikePodUsb", "release reason=$reason mode=yield")
        val context = hostContext
        synchronized(this) {
            focusYielded = true
            directBlocked = true
            val name = current.name
            val hadClaim = current.active ||
                (UsbExclusiveNative.libraryLoaded() && UsbExclusiveNative.isActive())
            if (hadClaim) {
                stopLocked(reason)
            }
            current = named(name, "已让出 · 系统混音")
        }
        // The kernel isochronous stream does not recover on its own after an
        // exclusive handoff (the endpoint stays stalled: HAL writes block,
        // URB count freezes). Rebind the driver and reset the port right
        // here, while our handle is closed and BEFORE the other app builds
        // its AudioTrack on a dead endpoint. The reset re-enumerates the
        // dongle (1-2 s), so the grabber's first track open retries into a
        // freshly built device; that is still faster than a stalled stream
        // that never recovers.
        if (context != null) {
            rebindKernelDriver(context)
        }
    }

    /**
     * Broadcasts a device-state toggle for [dev] so the audio framework
     * invalidates every active AudioTrack on it. Used after a port reset:
     * the re-enumerated card keeps its ALSA address, apps see no device
     * change, and tracks opened before the reset stay silent forever
     * unless the framework forces them to reopen.
     */
    private fun forceDeviceStateToggle(dev: UsbDevice) {
        try {
            // Try every known AudioSystem.setDeviceConnectionState overload —
            // the exact signature varies across OEMs and API levels. All
            // variants take (device, state, address[, name[, volume]]).
            val audioSystemClass = Class.forName("android.media.AudioSystem")
            val address = dev.deviceName
            val deviceType = 0x4000000 // AUDIO_DEVICE_OUT_USB_HEADSET
            var toggled = false
            for (method in audioSystemClass.declaredMethods) {
                if (method.name != "setDeviceConnectionState") continue
                val types = method.parameterTypes
                if (types.size < 3 || types[0] != Int::class.javaPrimitiveType) continue
                if (types.any { it != Int::class.javaPrimitiveType && it != String::class.java }) continue
                try {
                    method.isAccessible = true
                    val args = mutableListOf<Any>(deviceType, 0, address)
                    for (i in 3 until types.size) {
                        args.add(if (types[i] == String::class.java) address else 0)
                    }
                    method.invoke(null, *args.toTypedArray())
                    args[1] = 1
                    method.invoke(null, *args.toTypedArray())
                    toggled = true
                    Log.i(TAG, "device state toggled via ${types.size}-arg overload")
                    break
                } catch (error: Throwable) {
                    Log.i(TAG, "overload ${types.size} args rejected: ${error.message}")
                }
            }
            if (!toggled) {
                // Public-API fallback: the wired-device state lives in the
                // same table the framework broadcasts from.
                val am = appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                if (am != null) {
                    val m = AudioManager::class.java.getDeclaredMethod(
                        "setWiredDeviceConnectionState",
                        Int::class.javaPrimitiveType,
                        Int::class.javaPrimitiveType,
                        String::class.java,
                        String::class.java,
                    )
                    m.isAccessible = true
                    m.invoke(am, deviceType, 0, address, "lifeme")
                    m.invoke(am, deviceType, 1, address, "lifeme")
                    toggled = true
                    Log.i(TAG, "device state toggled via AudioManager")
                }
            }
            if (!toggled) {
                Log.i(TAG, "device state toggle unavailable")
            }
        } catch (error: Throwable) {
            Log.i(TAG, "device state toggle skipped: ${error.message}")
        }
    }

    /** Blocks a device-callback reclaim before the interfaces are released. */
    fun armYield(reason: String) {
        synchronized(this) {
            focusYielded = true
            directBlocked = true
        }
        Log.i("LikePodUsb", "yield armed reason=$reason")
    }

    fun clearFailure() {
        synchronized(this) {
            failKey = null
            cachedFail = null
        }
    }

    /** Allows a later [tryStart] after this process holds focus again. */
    fun focusReturned() {
        synchronized(this) {
            focusYielded = false
            directBlocked = false
            failKey = null
            cachedFail = null
        }
    }

    /** Last click-wheel volume. Null until the user or startup sets it. */
    @Volatile
    private var appGain: Float? = null

    fun wheelUi(): Float? = appGain

    private const val SAFE_UI = 0.10f
    private const val PCM_SLOP = 0.001f

    /** Application context captured at install, used for rebinds after death. */
    @Volatile
    private var hostContext: Context? = null

    fun install(host: Handler, context: Context, changed: () -> Unit) {
        handler = host
        hostContext = context.applicationContext
        onChanged = changed
        UsbExclusiveNative.onDied = Runnable {
            val reason = UsbExclusiveNative.detail
            val physical = isPhysicalDrop(reason)
            host.post {
                synchronized(this) {
                    stopLocked()
                    if (!physical) {
                        // A freeze or transient stall killed the stream but
                        // the dongle is still enumerated and still ours.
                        // Keep the claim key so the next tryStart skips the
                        // cached-failure gate and reopens immediately.
                        activeKey = lastClaimKey
                        failKey = null
                        cachedFail = null
                    }
                    current = Status(
                        active = false,
                        rate = 0,
                        bitDepth = 0,
                        resampled = false,
                        detail = reason.ifEmpty { "失败 · 等时传输中断" },
                        name = current.name,
                    )
                }
                if (physical) {
                    // The link itself dropped; the kernel driver will not
                    // come back on its own. Rebind so the mixer stays usable.
                    rebindKernelDriver(hostContext ?: return@post)
                }
                changed()
            }
        }
    }

    /** URB -108/ENODEV means the link dropped; anything else is a stall. */
    private fun isPhysicalDrop(reason: String): Boolean {
        return reason.contains("-108") ||
            reason.contains("ENODEV") ||
            reason.contains("等时包被拒绝")
    }

    private var lastClaimKey: String? = null

    fun audioPresent(context: Context): Boolean = findAudio(context) != null

    fun syntheticSink(): Map<String, Any?>? {
        val status = current
        val dev = device
        if (!status.active || dev == null) {
            return null
        }
        return mapOf(
            "id" to (1_000_000 + dev.deviceId),
            "name" to status.name,
            "type" to 11,
            "sampleRates" to listOf(status.rate),
            "encodings" to listOf(2),
            "routed" to true,
        )
    }

    fun onPermission(name: String, granted: Boolean) {
        synchronized(this) {
            permissionPending = false
            failKey = null
            cachedFail = null
            deniedName = if (granted) null else name
        }
    }

    fun onDetached(name: String?) {
        synchronized(this) {
            val openName = device?.deviceName
            if (name == null || openName == null || name == openName) {
                stopLocked()
                current = Status.idle
            }
            failKey = null
            cachedFail = null
            deniedName = null
            permissionPending = false
            clearClaimHeld()
        }
    }

    fun tryStart(activity: Activity, wantedRate: Int): Status {
        synchronized(this) {
            // Route sync must keep trying the isochronous open. A focus
            // grant is not required. Only a real loss sets [focusYielded],
            // and that path must not run stopLocked on an unrelated sync.
            if (focusYielded) {
                Log.i("LikePodUSB", "tryStart skipped, focus yielded")
                return current
            }
            if (!UsbExclusiveNative.libraryLoaded()) {
                val status = fail(Status.idle, "失败 · 直接输出库未装入")
                current = status
                return status
            }
            val dev = findAudio(activity)
            if (dev == null) {
                Log.i("LikePodUSB", "tryStart no USB audio interface")
                if (current.active) {
                    stopLocked()
                }
                current = Status.idle
                return Status.idle
            }
            val name = displayName(dev)
            val wanted = if (wantedRate > 0) wantedRate else 44100
            val key = "${dev.deviceName}:$wanted"
            if (current.active && activeKey == key && UsbExclusiveNative.isActive()) {
                val heard = appliedGain()
                if (heard == null) {
                    stopLocked()
                    val status = named(name, "失败 · 直接输出音量无法控制，已改走系统混音")
                    current = status
                    return status
                }
                val refreshed = current.copy(
                    gain = heard.linear.toDouble(),
                    ui = heard.ui.toDouble(),
                    fresh = false,
                )
                current = refreshed
                return refreshed
            }
            val manager = usbManager(activity)
            if (!manager.hasPermission(dev)) {
                if (deniedName == dev.deviceName) {
                    Log.i("LikePodUSB", "tryStart permission denied name=$name")
                    val status = named(name, "失败 · USB 权限被拒绝")
                    current = status
                    return status
                }
                if (!permissionPending) {
                    permissionPending = true
                    requestPermission(activity, manager, dev)
                }
                Log.i("LikePodUSB", "tryStart waiting for USB permission name=$name")
                val status = named(name, "失败 · 等待 USB 权限")
                current = status
                return status
            }
            permissionPending = false
            deniedName = null
            val cached = cachedFail
            if (failKey == key && cached != null) {
                Log.i("LikePodUSB", "tryStart cached failure $cached")
                val status = named(name, cached)
                current = status
                return status
            }
            if (current.active) {
                stopLocked()
            }
            val opened = open(activity, manager, dev, name, wanted)
            if (!opened.active && !opened.detail.contains("等待")) {
                failKey = key
                cachedFail = opened.detail
            } else if (opened.active) {
                failKey = null
                cachedFail = null
                activeKey = key
                lastClaimKey = key
                markClaimHeld()
            }
            current = opened
            Log.i(
                "LikePodUsb",
                if (opened.active) {
                    "claim reason=playback rate=$wanted ${opened.detail}"
                } else {
                    "claim skipped reason=open-failed ${opened.detail}"
                },
            )
            Log.i("LikePodUSB", "tryStart active=${opened.active} fresh=${opened.fresh} ${opened.detail}")
            return opened
        }
    }

    fun stop(reason: String = "stop") {
        Log.i("LikePodUsb", "release reason=$reason mode=idle")
        synchronized(this) {
            focusYielded = false
            directBlocked = false
            stopLocked(reason)
            current = Status.idle
            activeKey = null
        }
    }

    /** The playback service is in front. The open usbfs claim does not follow the activity. */
    fun keepForService(reason: String) {
        if (!current.active) return
        reassertSuspend()
        Log.i("LikePodUsb", "claim kept reason=$reason active=true")
    }

    /**
     * Best-effort rebind of the kernel USB audio driver. A process that
     * dies holding the exclusive claim leaves the interfaces detached
     * (USBDEVFS_DISCONNECT is one-way), which silences the DAC for every
     * other app until the dongle is replugged. Safe to call while idle:
     * connecting an already-bound interface just returns EBUSY.
     */
    /** True once this process has held the exclusive claim since attach.
     *  After that, a handoff needs a port reset to restart the kernel
     *  isochronous stream: snd-usb-audio does not reliably resubmit its
     *  urb state machine when an interface was usbfs-disconnected under
     *  it, even after a clean rebind. */
    @Volatile
    private var exclusiveHeldSinceLastReset = false

    /** False until the first preemptive reset of this process has run. */
    @Volatile
    private var firstResetDone = false

    fun markClaimHeld() {
        exclusiveHeldSinceLastReset = true
    }

    fun clearClaimHeld() {
        exclusiveHeldSinceLastReset = false
    }    fun rebindKernelDriver(context: Context) {
        synchronized(this) {
            // focusYielded is fine here: yielding is exactly when the driver
            // must go back to the kernel. Only an open exclusive stream
            // blocks the rebind.
            if (current.active || UsbExclusiveNative.isActive()) return
            if (!UsbExclusiveNative.libraryLoaded()) return
            val manager = usbManager(context)
            val dev = findAudio(context) ?: return
            if (!manager.hasPermission(dev)) return
            val conn = manager.openDevice(dev) ?: return
            try {
                val fd = conn.fileDescriptor
                if (fd < 0) return
                val ifaces = audioInterfaces(dev)
                var bound = 0
                var orphan = 0
                for (number in ifaces) {
                    val driver = try {
                        UsbExclusiveNative.nativeGetDriver(fd, number)
                    } catch (_: Throwable) {
                        -1
                    }
                    when {
                        driver > 0 -> bound++
                        driver == 0 -> {
                            orphan++
                            try {
                                if (UsbExclusiveNative.nativeConnect(fd, number)) bound++
                            } catch (_: Throwable) {
                            }
                        }
                    }
                }
                Log.i(
                    "LikePodUsb",
                    "kernel rebind pass ifaces=$ifaces bound=$bound orphan=$orphan",
                )
                // All interfaces are bound but an exclusive claim happened
                // since the last rebind-with-reset: the kernel isochronous
                // stream is stalled (HAL writes block, timestamps stay
                // cold). A port reset forces snd-usb-audio to rebuild from
                // scratch. The flag tracks "a claim happened since the last
                // reset" and is cleared HERE, right after the reset —
                // gating it on the next exclusive open starved every
                // handoff after the first in a long feed session.
                if (bound == ifaces.size && orphan == 0 && exclusiveHeldSinceLastReset) {
                    exclusiveHeldSinceLastReset = false
                    // After the reset the endpoint needs a few seconds of
                    // scheduled zero-length traffic to stay alive; without
                    // it, tracks the grabber opened on the HAL write into a
                    // dead pipe. Run it while our handle is open.
                    val alive = try {
                        UsbExclusiveNative.nativeKeepAlive(5)
                    } catch (_: Throwable) {
                        false
                    }
                    Log.i(TAG, "endpoint keepalive after reset: $alive")
                    val ok = try {
                        UsbExclusiveNative.nativeResetDevice(fd)
                    } catch (_: Throwable) {
                        false
                    }
                    Log.i(TAG, "usb port reset after handoff: $ok")
                }
            } finally {
                try {
                    conn.close()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun open(context: Context, manager: UsbManager, dev: UsbDevice, name: String, wanted: Int): Status {
        val connection = manager.openDevice(dev) ?: return named(name, "失败 · 打开 USB 设备失败")
        this.connection = connection
        this.device = dev
        val raw = connection.rawDescriptors
        if (raw == null || raw.isEmpty()) {
            stopLocked()
            return named(name, "失败 · 读不到 USB 描述符")
        }
        val chosen = UsbExclusiveNative.nativeChoose(raw, wanted)
        if (chosen == null || chosen.size < 18) {
            val why = UsbExclusiveNative.nativeLastChooseError()?.takeIf { it.isNotEmpty() }
                ?: "描述符里没有 PCM 播放端点"
            stopLocked()
            return named(name, "失败 · $why")
        }
        val ifNum = chosen[0]
        val alt = chosen[1]
        val protocol = chosen[2]
        val channels = chosen[3]
        val bits = chosen[4]
        val subframe = chosen[5]
        val endpoint = chosen[6]
        val maxPacket = chosen[7]
        val interval = chosen[8]
        val feedback = chosen[9]
        val clockId = chosen[10]
        val acInterface = chosen[11]
        val descriptorResample = chosen[12] != 0
        var rate = chosen[13]
        val continuous = chosen[14] != 0
        val rateCount = chosen[17]
        if (channels <= 0 || subframe <= 0 || endpoint <= 0 || maxPacket <= 0 || rate <= 0) {
            stopLocked()
            return named(name, "失败 · 播放端点不完整")
        }
        val fd = connection.fileDescriptor
        if (fd < 0) {
            stopLocked()
            return named(name, "失败 · USB 句柄无效")
        }
        val numbers = audioInterfaces(dev)
        // Preemptive port reset: any kernel isochronous stream left by the
        // previous handoff is stalled and unrecoverable for whoever built
        // tracks on it. Resetting here — while the claim is ours and before
        // our own stream starts — hands the grabber a fresh endpoint if it
        // grabs focus in a moment. Costs one 1-2 s re-enumeration right after
        // this open, which the user sees as the DAC reconnecting before
        // playback continues.
        if (exclusiveHeldSinceLastReset || !firstResetDone) {
            val ok = try {
                UsbExclusiveNative.nativeResetDevice(fd)
            } catch (_: Throwable) {
                false
            }
            Log.i(TAG, "preemptive port reset at claim: $ok")
            exclusiveHeldSinceLastReset = false
            firstResetDone = true
        }
        for (number in numbers) {
            UsbExclusiveNative.nativeDisconnect(fd, number)
        }
        val stream = findInterface(dev, ifNum, alt)
        if (stream == null) {
            rebind(connection, fd, dev)
            stopLocked()
            return named(name, "失败 · 找不到备用设置 $alt")
        }
        val claimAlt0 = findInterface(dev, ifNum, 0) ?: stream
        if (!connection.claimInterface(claimAlt0, true)) {
            rebind(connection, fd, dev)
            stopLocked()
            return named(name, "失败 · 无法占用 USB 声卡接口")
        }
        claimed.add(claimAlt0)
        if (acInterface >= 0 && acInterface != ifNum) {
            val control = findInterface(dev, acInterface, 0)
            if (control != null && connection.claimInterface(control, true)) {
                claimed.add(control)
            }
        }
        if (!connection.setInterface(stream)) {
            stopLocked()
            return named(name, "失败 · 无法切换 USB 备用设置")
        }
        val rateSet = setSampleRate(connection, protocol, endpoint, acInterface, clockId, rate)
        val listedSingle = rateCount == 1 && !continuous && !descriptorResample
        var confirmed = rateSet || listedSingle
        var resampled = descriptorResample || rate != wanted
        if (!rateSet && !listedSingle) {
            val fallback = if (rate == 48000) 44100 else 48000
            if (setSampleRate(connection, protocol, endpoint, acInterface, clockId, fallback)) {
                rate = fallback
                resampled = true
                confirmed = true
            }
        }
        val speed = UsbExclusiveNative.nativeGetSpeed(fd)
        val high = speed >= 3
        val packets = packetsPerUrb(high, interval)
        val frame = channels * subframe
        val perSecond = packets * 1000
        val perPacket = (rate + perSecond - 1) / perSecond + 1
        if (maxPacket < perPacket * frame) {
            stopLocked()
            return named(name, "失败 · 端点包长 $maxPacket 不够 ${formatHz(rate)}")
        }
        UsbExclusiveNative.rateHz = rate
        UsbExclusiveNative.channelCount = channels
        UsbExclusiveNative.bytesPerSample = subframe
        UsbExclusiveNative.active = false
        val heard = seedGain(context)
        if (heard == null) {
            stopLocked()
            return named(name, "失败 · 直接输出音量无法控制，已改走系统混音")
        }
        val started = UsbExclusiveNative.nativeStart(
            fd,
            endpoint,
            feedback,
            rate,
            channels,
            subframe,
            maxPacket,
            packets,
        )
        if (started != 0) {
            stopLocked()
            return named(name, "失败 · 等时提交 ${errnoText(started)}")
        }
        UsbExclusiveNative.active = true
        appContext = context.applicationContext
        PlaybackAnchor.setDirect(context, true)
        val protoName = if (protocol == 0x20) "UAC2" else "UAC1"
        val detail = buildString {
            append("已打开 · ${formatHz(rate)} · ${bits}-bit · $protoName")
            if (resampled) append(" · 已重采样")
            if (!confirmed) append(" · 采样率未确认")
        }
        Log.i(TAG, "USB direct $detail ep=$endpoint packets=$packets speed=$speed ui=${heard.ui} pcm=${heard.linear}")
        Log.i("LikePodUSB", "direct open $detail ep=$endpoint packets=$packets")
        return Status(
            true,
            rate,
            bits,
            resampled,
            detail,
            name,
            heard.linear.toDouble(),
            heard.ui.toDouble(),
            fresh = true,
        )
    }

    /**
     * Click-wheel position. Sets both controls to that UI fraction.
     * The value multiplied onto PCM is the cubic curve of it, capped at −12 dB.
     * Null means the direct path cannot attenuate and must be closed.
     */
    fun setWheelVolume(ui: Float): Heard? {
        val clamped = ui.coerceIn(0f, 1f)
        appGain = clamped
        return try {
            if (!UsbExclusiveNative.libraryLoaded()) {
                return null
            }
            if (!UsbExclusiveNative.nativeSetPlayerGain(clamped)) {
                return null
            }
            if (!UsbExclusiveNative.nativeSetStreamGain(clamped)) {
                return null
            }
            confirmNotLouderThan(clamped)
        } catch (error: Throwable) {
            Log.i(TAG, "USB wheel gain failed: ${error.message}")
            null
        }
    }

    /** Android media-stream position. Does not raise the click-wheel position. */
    fun setStreamVolume(ui: Float): Heard? {
        val requested = ui.coerceIn(0f, 1f)
        val pin = pinnedStreamUi
        val clamped = if (pin != null && requested <= 0.001f && pin > 0.02f) {
            pin
        } else {
            requested
        }
        return try {
            if (!UsbExclusiveNative.libraryLoaded()) {
                return null
            }
            if (!UsbExclusiveNative.nativeSetStreamGain(clamped)) {
                return null
            }
            confirmNotLouderThan(clamped)
        } catch (error: Throwable) {
            Log.i(TAG, "USB stream gain failed: ${error.message}")
            null
        }
    }

    fun appliedGain(): Heard? {
        return try {
            if (!UsbExclusiveNative.libraryLoaded() || !UsbExclusiveNative.nativeStreamGainKnown()) {
                return null
            }
            val ui = UsbExclusiveNative.nativeGetUi()
            if (ui.isNaN() || ui < 0f || ui > 1f) {
                return null
            }
            confirmNotLouderThan(ui)
        } catch (error: Throwable) {
            null
        }
    }

    private fun seedGain(context: Context): Heard? {
        val stream = readStreamRatio(context) ?: SAFE_UI
        val wheel = appGain
        return try {
            if (!UsbExclusiveNative.nativeSetStreamGain(stream)) {
                return null
            }
            if (wheel != null && !UsbExclusiveNative.nativeSetPlayerGain(wheel)) {
                return null
            }
            if (!UsbExclusiveNative.nativeStreamGainKnown()) {
                return null
            }
            confirmNotLouderThan(stream)
        } catch (error: Throwable) {
            Log.i(TAG, "USB gain seed failed: ${error.message}")
            null
        }
    }

    /** PCM readback must not exceed the curve of [ui]. Quieter is fine. */
    private fun confirmNotLouderThan(ui: Float): Heard? {
        val linear = UsbExclusiveNative.nativeGetGain()
        val limit = UsbExclusiveNative.nativePcmForUi(ui)
        val heardUi = UsbExclusiveNative.nativeGetUi()
        if (linear.isNaN() || limit.isNaN() || heardUi.isNaN()) {
            return null
        }
        if (linear < 0f || linear > limit + PCM_SLOP || linear > 1f) {
            return null
        }
        return Heard(heardUi.coerceIn(0f, 1f), linear.coerceIn(0f, 1f))
    }

    private fun readStreamRatio(context: Context): Float? {
        return try {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            if (max <= 0) {
                null
            } else {
                val current = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                (current.toFloat() / max.toFloat()).coerceIn(0f, 1f)
            }
        } catch (error: Throwable) {
            null
        }
    }

    private fun stopLocked(reason: String = "stop") {
        UsbExclusiveNative.active = false
        try {
            if (UsbExclusiveNative.libraryLoaded()) {
                UsbExclusiveNative.nativeStop()
            }
        } catch (e: Throwable) {
            Log.i(TAG, "USB stop: ${e.message}")
        }
        val conn = connection
        val dev = device
        if (conn != null && dev != null) {
            val fd = conn.fileDescriptor
            Log.i("LikePodUsb", "release order reason=$reason step=releaseInterface+USBDEVFS_CONNECT")
            for (intf in claimed) {
                try {
                    conn.releaseInterface(intf)
                    Log.i("LikePodUsb", "releaseInterface iface=${intf.id} reason=$reason")
                } catch (error: Exception) {
                    Log.i("LikePodUsb", "releaseInterface failed iface=${intf.id} ${error.message}")
                }
                if (fd >= 0) {
                    try {
                        UsbExclusiveNative.nativeConnect(fd, intf.id)
                    } catch (_: Throwable) {
                    }
                }
            }
            for (number in audioInterfaces(dev)) {
                if (fd >= 0) {
                    try {
                        UsbExclusiveNative.nativeConnect(fd, number)
                        Log.i("LikePodUsb", "kernel connect iface=$number reason=$reason")
                    } catch (error: Throwable) {
                        Log.i("LikePodUsb", "kernel connect failed iface=$number ${error.message}")
                    }
                }
            }
            try {
                conn.close()
                Log.i("LikePodUsb", "UsbDeviceConnection closed reason=$reason")
            } catch (_: Exception) {
            }
        }
        claimed.clear()
        connection = null
        device = null
        appContext?.let { PlaybackAnchor.setDirect(it, false) }
        UsbExclusiveNative.rateHz = 0
        UsbExclusiveNative.channelCount = 0
        UsbExclusiveNative.bytesPerSample = 0
    }

    private fun rebind(connection: UsbDeviceConnection, fd: Int, dev: UsbDevice) {
        for (number in audioInterfaces(dev)) {
            if (fd >= 0) {
                UsbExclusiveNative.nativeConnect(fd, number)
            }
        }
        try {
            connection.close()
        } catch (_: Exception) {
        }
        this.connection = null
        this.device = null
    }

    private fun setSampleRate(
        connection: UsbDeviceConnection,
        protocol: Int,
        endpoint: Int,
        acInterface: Int,
        clockId: Int,
        rate: Int,
    ): Boolean {
        return if (protocol == 0x20) {
            if (acInterface < 0 || clockId <= 0) {
                false
            } else {
                val data = byteArrayOf(
                    (rate and 0xFF).toByte(),
                    ((rate shr 8) and 0xFF).toByte(),
                    ((rate shr 16) and 0xFF).toByte(),
                    ((rate shr 24) and 0xFF).toByte(),
                )
                val index = (clockId shl 8) or (acInterface and 0xFF)
                val wrote = connection.controlTransfer(0x21, 0x01, 0x0100, index, data, 4, 250)
                if (wrote < 0) {
                    false
                } else {
                    val back = ByteArray(4)
                    val read = connection.controlTransfer(0xA1, 0x81, 0x0100, index, back, 4, 250)
                    if (read < 4) {
                        true
                    } else {
                        val got = (back[0].toInt() and 0xFF) or
                            ((back[1].toInt() and 0xFF) shl 8) or
                            ((back[2].toInt() and 0xFF) shl 16) or
                            ((back[3].toInt() and 0xFF) shl 24)
                        got == rate
                    }
                }
            }
        } else {
            val data = byteArrayOf(
                (rate and 0xFF).toByte(),
                ((rate shr 8) and 0xFF).toByte(),
                ((rate shr 16) and 0xFF).toByte(),
            )
            val wrote = connection.controlTransfer(0x22, 0x01, 0x0100, endpoint, data, 3, 250)
            if (wrote < 0) {
                false
            } else {
                val back = ByteArray(3)
                val read = connection.controlTransfer(0xA2, 0x81, 0x0100, endpoint, back, 3, 250)
                if (read < 3) {
                    true
                } else {
                    val got = (back[0].toInt() and 0xFF) or
                        ((back[1].toInt() and 0xFF) shl 8) or
                        ((back[2].toInt() and 0xFF) shl 16)
                    got == rate
                }
            }
        }
    }

    private fun packetsPerUrb(highSpeed: Boolean, interval: Int): Int {
        if (!highSpeed) {
            return 1
        }
        val step = if (interval <= 1) 1 else 1 shl (interval - 1).coerceAtMost(10)
        return (8 / step).coerceIn(1, 8)
    }

    private fun audioInterfaces(dev: UsbDevice): List<Int> {
        val numbers = LinkedHashSet<Int>()
        for (i in 0 until dev.interfaceCount) {
            val intf = dev.getInterface(i)
            if (intf.interfaceClass == UsbConstants.USB_CLASS_AUDIO) {
                numbers.add(intf.id)
            }
        }
        return numbers.toList()
    }

    private fun findInterface(dev: UsbDevice, number: Int, alt: Int): UsbInterface? {
        for (i in 0 until dev.interfaceCount) {
            val intf = dev.getInterface(i)
            if (intf.id == number && intf.alternateSetting == alt) {
                return intf
            }
        }
        return null
    }

    private fun findAudio(context: Context): UsbDevice? {
        val manager = usbManager(context)
        return manager.deviceList.values.firstOrNull { dev ->
            (0 until dev.interfaceCount).any { index ->
                dev.getInterface(index).interfaceClass == UsbConstants.USB_CLASS_AUDIO
            }
        }
    }

    private fun usbManager(context: Context): UsbManager {
        return context.getSystemService(Context.USB_SERVICE) as UsbManager
    }

    private fun requestPermission(activity: Activity, manager: UsbManager, dev: UsbDevice) {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(activity.packageName)
        val pending = PendingIntent.getBroadcast(activity, 0, intent, flags)
        manager.requestPermission(dev, pending)
    }

    private fun displayName(device: UsbDevice): String {
        val product = device.productName?.toString()?.trim().orEmpty()
        return if (product.isEmpty()) "USB" else product
    }

    private fun named(name: String, detail: String): Status {
        return Status(false, 0, 0, false, detail, name)
    }

    private fun fail(status: Status, detail: String): Status {
        return status.copy(active = false, detail = detail)
    }

    private fun errnoText(code: Int): String {
        val n = if (code < 0) -code else code
        return when (n) {
            1 -> "EPERM"
            2 -> "ENOENT 端点未就绪"
            12 -> "ENOMEM"
            13 -> "EACCES"
            16 -> "EBUSY 接口忙"
            19 -> "ENODEV 设备不在"
            22 -> "EINVAL 参数无效"
            else -> "errno $n"
        }
    }

    private fun formatHz(hz: Int): String {
        if (hz <= 0) return "采样率未报告"
        val tenths = hz / 100
        val frac = tenths % 10
        val whole = tenths / 10
        return if (frac == 0) "${whole}kHz" else "$whole.${frac}kHz"
    }
}
