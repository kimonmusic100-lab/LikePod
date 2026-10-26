package com.ryanheise.just_audio;

import android.util.Log;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Writes decoded PCM to the app's USB isochronous stream when that stream is
 * open. Otherwise the bytes go to the normal AudioTrack sink.
 *
 * Direct PCM is stored without attenuation. The USB thread applies a cubic
 * curve of the UI position, capped at −12 dBFS, when it fills the next
 * isochronous packet. A volume change does not wait for the ring to drain.
 */
public final class UsbDirectSink extends ForwardingAudioSink {
    private static final String TAG = "LikePod";
    private static volatile boolean anyDirect = false;

    /** True after this process has moved a sink onto the usbfs stream. */
    public static boolean inDirect() {
        return anyDirect;
    }
    private final Client client = new Client();
    private Format format;
    private int sampleRate;
    private int channels;
    private boolean floatPcm;
    private boolean configuredDirect;
    private boolean rendererPlaying;
    private boolean inputEnded;
    private boolean hasStart;
    private long startUs;

    /** State-change trace of what the renderer asks the sink to do. */
    private void slog(String what) {
        Log.i("LikePodSink", what + " direct=" + configuredDirect + " rendererPlaying=" + rendererPlaying);
    }

    public UsbDirectSink(AudioSink inner) {
        super(inner);
    }

    @Override
    public void configure(Format inputFormat, int specifiedBufferSize, int[] outputChannels)
            throws AudioSink.ConfigurationException {
        slog("configure rate=" + inputFormat.sampleRate + " ch=" + inputFormat.channelCount);
        format = inputFormat;
        sampleRate = inputFormat.sampleRate;
        channels = inputFormat.channelCount;
        int encoding = inputFormat.pcmEncoding;
        floatPcm = encoding == C.ENCODING_PCM_FLOAT;
        if (client.ready()) {
            enterDirect();
            return;
        }
        configuredDirect = false;
        super.configure(inputFormat, specifiedBufferSize, outputChannels);
    }

    @Override
    public void play() {
        rendererPlaying = true;
        slog("play");
        if (configuredDirect) {
            client.setPlaying(true);
            return;
        }
        super.play();
    }

    @Override
    public void pause() {
        rendererPlaying = false;
        slog("pause");
        if (configuredDirect) {
            client.setPlaying(false);
            return;
        }
        super.pause();
    }

    @Override
    public void flush() {
        slog("flush");
        inputEnded = false;
        hasStart = false;
        if (client.ready()) {
            enterDirect();
            return;
        }
        if (configuredDirect) {
            leaveDirect();
        }
        super.flush();
    }

    @Override
    public void reset() {
        slog("reset");
        inputEnded = false;
        hasStart = false;
        if (configuredDirect) {
            client.flush();
            configuredDirect = false;
        }
        super.reset();
    }

    @Override
    public boolean handleBuffer(ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount)
            throws AudioSink.InitializationException, AudioSink.WriteException {
        if (client.ready()) {
            if (!configuredDirect) {
                enterDirect();
            }
            return writeDirect(buffer, presentationTimeUs);
        }
        if (configuredDirect) {
            leaveDirect();
        }
        return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount);
    }

    @Override
    public void playToEndOfStream() throws AudioSink.WriteException {
        if (configuredDirect) {
            inputEnded = true;
            return;
        }
        super.playToEndOfStream();
    }

    @Override
    public boolean isEnded() {
        if (!configuredDirect) {
            return super.isEnded();
        }
        return inputEnded && client.queuedBytes() == 0;
    }

    @Override
    public boolean hasPendingData() {
        if (!configuredDirect) {
            return super.hasPendingData();
        }
        return !isEnded() && (rendererPlaying || client.queuedBytes() > 0);
    }

    @Override
    public long getCurrentPositionUs(boolean sourceEnded) {
        if (!configuredDirect) {
            return super.getCurrentPositionUs(sourceEnded);
        }
        if (!hasStart) {
            return AudioSink.CURRENT_POSITION_NOT_SET;
        }
        int rate = client.wireRate();
        if (rate <= 0) {
            rate = sampleRate > 0 ? sampleRate : 44100;
        }
        return startUs + (client.playedFrames() * 1_000_000L) / rate;
    }

    @Override
    public void setVolume(float volume) {
        if (volume < 0f) {
            volume = 0f;
        } else if (volume > 1f) {
            volume = 1f;
        }
        client.setPlayerGain(volume);
        super.setVolume(volume);
    }

    @Override
    public void handleDiscontinuity() {
        hasStart = false;
        if (configuredDirect) {
            client.flush();
            return;
        }
        super.handleDiscontinuity();
    }

    private void enterDirect() {
        try {
            super.pause();
            super.flush();
            super.reset();
        } catch (Throwable ignored) {
        }
        configuredDirect = true;
        anyDirect = true;
        inputEnded = false;
        hasStart = false;
        client.flush();
        client.setPlaying(rendererPlaying);
        Log.i("LikePodUsb", "mode direct reason=sink-entered rate=" + sampleRate);
    }

    private void leaveDirect() {
        configuredDirect = false;
        anyDirect = false;
        client.setPlaying(false);
        Log.i("LikePodUsb", "mode mixer reason=sink-left-direct playing=" + rendererPlaying);
        if (format == null) {
            return;
        }
        try {
            super.configure(format, 0, null);
            if (rendererPlaying) {
                super.play();
            }
        } catch (Throwable error) {
            Log.i(TAG, "USB sink fallback failed: " + error);
        }
    }

    private boolean writeDirect(ByteBuffer buffer, long presentationTimeUs) {
        byte[] out = convert(buffer);
        if (out.length == 0) {
            buffer.position(buffer.limit());
            return true;
        }
        if (client.space() < out.length) {
            return false;
        }
        int wrote = client.write(out);
        if (wrote != out.length) {
            return false;
        }
        buffer.position(buffer.limit());
        if (!hasStart) {
            hasStart = true;
            startUs = presentationTimeUs;
        }
        return true;
    }

    private byte[] convert(ByteBuffer buffer) {
        int srcChannels = channels > 0 ? channels : 1;
        int srcRate = sampleRate > 0 ? sampleRate : client.wireRate();
        int dstRate = client.wireRate();
        int dstChannels = client.wireChannels();
        int dstBytes = client.wireBytes();
        if (srcRate <= 0 || dstRate <= 0 || dstChannels <= 0 || dstBytes <= 0) {
            return new byte[0];
        }
        int srcFrameBytes = floatPcm ? srcChannels * 4 : srcChannels * 2;
        if (srcFrameBytes <= 0 || buffer.remaining() < srcFrameBytes) {
            return new byte[0];
        }
        int srcFrames = buffer.remaining() / srcFrameBytes;
        int dstFrames = srcRate == dstRate
                ? srcFrames
                : (int) (((long) srcFrames * dstRate) / srcRate);
        if (dstFrames < 1) {
            dstFrames = 1;
        }
        ByteBuffer src = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN);
        int base = src.position();
        byte[] out = new byte[dstFrames * dstChannels * dstBytes];
        for (int frame = 0; frame < dstFrames; frame++) {
            double pos = srcRate == dstRate ? frame : ((double) frame * srcFrames) / dstFrames;
            int i0 = (int) pos;
            if (i0 >= srcFrames) {
                i0 = srcFrames - 1;
            }
            int i1 = i0 + 1 < srcFrames ? i0 + 1 : i0;
            double frac = pos - i0;
            for (int ch = 0; ch < dstChannels; ch++) {
                int srcCh = ch < srcChannels ? ch : srcChannels - 1;
                int s0 = readSample(src, base, srcFrameBytes, srcChannels, i0, srcCh);
                int s1 = readSample(src, base, srcFrameBytes, srcChannels, i1, srcCh);
                int mixed = (int) Math.round(s0 + ((s1 - s0) * frac));
                if (mixed > 32767) {
                    mixed = 32767;
                } else if (mixed < -32768) {
                    mixed = -32768;
                }
                writeSample(out, (frame * dstChannels + ch) * dstBytes, dstBytes, mixed);
            }
        }
        return out;
    }

    private int readSample(ByteBuffer src, int base, int srcFrameBytes, int srcChannels, int frame, int channel) {
        int index = base + (frame * srcChannels + channel) * (floatPcm ? 4 : 2);
        if (floatPcm) {
            float value = src.getFloat(index);
            if (value > 1f) {
                value = 1f;
            } else if (value < -1f) {
                value = -1f;
            }
            return Math.round(value * 32767f);
        }
        return src.getShort(index);
    }

    private void writeSample(byte[] out, int offset, int dstBytes, int sample) {
        if (dstBytes == 2) {
            out[offset] = (byte) sample;
            out[offset + 1] = (byte) (sample >> 8);
            return;
        }
        int widened = dstBytes >= 4 ? sample << 16 : sample << 8;
        for (int i = 0; i < dstBytes && i < 4; i++) {
            out[offset + i] = (byte) (widened >> (8 * i));
        }
    }

    /** Reflects into the app module. just_audio cannot import it at compile time. */
    private static final class Client {
        private static boolean lookedUp;
        private static Class<?> type;
        private static Method isActive;
        private static Method wireRate;
        private static Method wireChannels;
        private static Method wireBytes;
        private static Method space;
        private static Method write;
        private static Method flush;
        private static Method setPlaying;
        private static Method setPlayerGain;
        private static Method played;
        private static Method queued;

        boolean ready() {
            lookup();
            if (isActive == null) {
                return false;
            }
            try {
                Object value = isActive.invoke(null);
                return value instanceof Boolean && (Boolean) value && wireRate() > 0;
            } catch (Throwable error) {
                return false;
            }
        }

        int wireRate() {
            return callInt(wireRate);
        }

        int wireChannels() {
            return callInt(wireChannels);
        }

        int wireBytes() {
            return callInt(wireBytes);
        }

        int space() {
            return callInt(space);
        }

        int queuedBytes() {
            return callInt(queued);
        }

        long playedFrames() {
            lookup();
            if (played == null) {
                return 0;
            }
            try {
                Object value = played.invoke(null);
                return value instanceof Long ? (Long) value : 0;
            } catch (Throwable error) {
                return 0;
            }
        }

        int write(byte[] data) {
            lookup();
            if (write == null) {
                return 0;
            }
            try {
                Object value = write.invoke(null, data, data.length);
                return value instanceof Integer ? (Integer) value : 0;
            } catch (Throwable error) {
                return 0;
            }
        }

        void flush() {
            call(flush);
        }

        void setPlaying(boolean playing) {
            lookup();
            if (setPlaying == null) {
                return;
            }
            try {
                setPlaying.invoke(null, playing);
            } catch (Throwable ignored) {
            }
        }

        void setPlayerGain(float gain) {
            lookup();
            if (setPlayerGain == null) {
                return;
            }
            try {
                setPlayerGain.invoke(null, gain);
            } catch (Throwable ignored) {
            }
        }

        private int callInt(Method method) {
            lookup();
            if (method == null) {
                return 0;
            }
            try {
                Object value = method.invoke(null);
                return value instanceof Integer ? (Integer) value : 0;
            } catch (Throwable error) {
                return 0;
            }
        }

        private void call(Method method) {
            lookup();
            if (method == null) {
                return;
            }
            try {
                method.invoke(null);
            } catch (Throwable ignored) {
            }
        }

        private static void lookup() {
            if (lookedUp) {
                return;
            }
            lookedUp = true;
            try {
                type = Class.forName("com.likepod.likepod.UsbExclusiveNative");
                isActive = type.getMethod("isActive");
                wireRate = type.getMethod("wireRate");
                wireChannels = type.getMethod("wireChannels");
                wireBytes = type.getMethod("wireBytes");
                space = type.getMethod("nativeSpace");
                write = type.getMethod("nativeWrite", byte[].class, int.class);
                flush = type.getMethod("nativeFlush");
                setPlaying = type.getMethod("nativeSetPlaying", boolean.class);
                setPlayerGain = type.getMethod("nativeSetPlayerGain", float.class);
                played = type.getMethod("nativePlayedFrames");
                queued = type.getMethod("nativeQueuedBytes");
            } catch (Throwable error) {
                Log.i(TAG, "USB direct sink unavailable: " + error);
                Log.i("LikePodUSB", "sink reflection failed: " + error);
                type = null;
            }
        }
    }
}
