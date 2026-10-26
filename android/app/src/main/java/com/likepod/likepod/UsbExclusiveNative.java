package com.likepod.likepod;

/**
 * Isochronous USB audio owned by this process. The player sink reaches these
 * methods by name, so release shrinking must keep the class.
 */
public final class UsbExclusiveNative {
    public static volatile boolean active = false;
    public static volatile int rateHz = 0;
    public static volatile int channelCount = 0;
    public static volatile int bytesPerSample = 0;
    public static volatile String detail = "";
    public static volatile Runnable onDied;

    private static final boolean loaded;

    static {
        boolean ok = false;
        try {
            System.loadLibrary("usb_exclusive");
            ok = true;
        } catch (Throwable ignored) {
        }
        loaded = ok;
    }

    private UsbExclusiveNative() {}

    public static boolean libraryLoaded() {
        return loaded;
    }

    public static boolean isActive() {
        if (!loaded || !active) {
            return false;
        }
        try {
            return nativeRunning();
        } catch (Throwable ignored) {
            return false;
        }
    }

    public static int wireRate() {
        return rateHz;
    }

    public static int wireChannels() {
        return channelCount;
    }

    public static int wireBytes() {
        return bytesPerSample;
    }

    /** Called from the USB thread. Must not stop the stream on this thread. */
    public static void onStreamDied(String reason) {
        active = false;
        if (reason != null && !reason.isEmpty()) {
            detail = reason.startsWith("失败") ? reason : "失败 · " + reason;
        } else {
            detail = "失败 · 等时传输中断";
        }
        Runnable callback = onDied;
        if (callback != null) {
            callback.run();
        }
    }

    public static native int nativeStart(
            int fd,
            int epOut,
            int epFeedback,
            int rate,
            int channels,
            int subframe,
            int maxPacket,
            int packetsPerUrb);

    public static native void nativeStop();

    public static native boolean nativeRunning();

    public static native int nativeWrite(byte[] data, int length);

    public static native int nativeSpace();

    public static native int nativeQueuedBytes();

    public static native void nativeFlush();

    public static native void nativeSetPlaying(boolean playing);

    /** Click-wheel / player position, 0..1. The PCM multiplier is not this value. */
    public static native boolean nativeSetPlayerGain(float ui);

    /** Android STREAM_MUSIC position, 0..1. Unknown stays at 10% of the UI. */
    public static native boolean nativeSetStreamGain(float ui);

    /** PCM amplitude after the cubic curve and the −12 dB ceiling. */
    public static native float nativeGetGain();

    /** Lower of the click-wheel and media-stream positions, before the curve. */
    public static native float nativeGetUi();

    /** PCM amplitude the curve would apply for this UI position. */
    public static native float nativePcmForUi(float ui);

    public static native boolean nativeStreamGainKnown();

    public static native long nativePlayedFrames();

    /** PCM bytes pushed by the player. Not incremented by URB completions. */
    public static native long nativeFedBytes();

    /** Asks usbfs again to refuse autosuspend on the open direct-stream fd. */
    public static native void nativeForbidSuspend();

    public static native int nativeGetSpeed(int fd);

    public static native void nativeDisconnect(int fd, int iface);

    /** True when the kernel driver actually bound to the interface. */
    public static native boolean nativeConnect(int fd, int iface);

    /** Kernel driver number holding the interface, or 0 when none does. */
    public static native int nativeGetDriver(int fd, int iface);

    /** Port-level reset (replug equivalent); the device re-enumerates. */
    public static native boolean nativeResetDevice(int fd);

    /**
     * Submits zero-length isochronous URBs for a few seconds to keep the
     * endpoint scheduled after a handoff, so tracks the grabber opened on
     * the USB HAL land on a living pipe.
     */
    public static native boolean nativeKeepAlive(int seconds);

    public static native int[] nativeChoose(byte[] raw, int wantedRate);

    public static native String nativeLastChooseError();

    /**
     * Queues a mono 16-bit little-endian click. Mixed into later USB packets
     * after the music gain. Returns false when the direct stream is closed.
     */
    public static native boolean nativeQueueClick(byte[] pcmLe16, int frames, int srcRate);
}
