package com.ryanheise.just_audio;

import android.media.AudioDeviceInfo;
import android.os.Handler;
import android.os.Looper;
import androidx.media3.common.C;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Direct call into the just_audio player. Release shrinking renames private
 * fields, so the app talks to this kept type instead of walking them.
 * TYPE_USB_DEVICE and TYPE_USB_HEADSET are both passed through as-is.
 */
public final class UsbPreferredDevice {
    private static final Object LOCK = new Object();
    private static final ArrayList<WeakReference<ExoPlayer>> PLAYERS = new ArrayList<>();
    private static volatile AudioDeviceInfo preferred;

    private UsbPreferredDevice() {}

    public static void onPlayerCreated(ExoPlayer player) {
        try {
            player.setWakeMode(C.WAKE_MODE_LOCAL);
        } catch (RuntimeException ignored) {
        }
        synchronized (LOCK) {
            pruneLocked();
            PLAYERS.add(new WeakReference<>(player));
        }
        final AudioDeviceInfo device = preferred;
        if (device != null) {
            applyTo(player, device);
        }
        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int playbackState) {
                if (playbackState != Player.STATE_BUFFERING && playbackState != Player.STATE_READY) {
                    return;
                }
                final AudioDeviceInfo current = preferred;
                if (current != null) {
                    applyTo(player, current);
                }
            }

            @Override
            public void onPlayWhenReadyChanged(boolean playWhenReady, int reason) {
                if (!playWhenReady) return;
                final AudioDeviceInfo current = preferred;
                if (current != null) {
                    applyTo(player, current);
                }
            }
        });
    }

    /** Returns {@code ok:...} or {@code fail:...}. Null clears the preference. */
    public static String setPreferred(AudioDeviceInfo device) {
        preferred = device;
        final List<ExoPlayer> live = snapshot();
        if (live.isEmpty()) {
            return device == null ? "ok:0" : "fail:没有播放器";
        }
        int ok = 0;
        final StringBuilder errors = new StringBuilder();
        for (ExoPlayer player : live) {
            final String one = applyTo(player, device);
            if ("ok".equals(one)) {
                ok++;
            } else if (errors.length() < 80) {
                if (errors.length() > 0) errors.append(' ');
                errors.append(one);
            }
        }
        if (ok == 0) return "fail:" + errors;
        return "ok:" + ok;
    }

    private static String applyTo(ExoPlayer player, AudioDeviceInfo device) {
        if (Looper.myLooper() == player.getApplicationLooper()) {
            return invoke(player, device);
        }
        final String[] out = new String[] {"超时"};
        final CountDownLatch latch = new CountDownLatch(1);
        new Handler(player.getApplicationLooper()).post(() -> {
            out[0] = invoke(player, device);
            latch.countDown();
        });
        try {
            if (!latch.await(700, TimeUnit.MILLISECONDS)) return "超时";
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return "中断";
        }
        return out[0];
    }

    private static String invoke(ExoPlayer player, AudioDeviceInfo device) {
        try {
            player.setPreferredAudioDevice(device);
            return "ok";
        } catch (Throwable t) {
            final String name = t.getClass().getSimpleName();
            final String message = t.getMessage();
            if (message == null || message.isEmpty()) return name;
            return name + ":" + message;
        }
    }

    private static List<ExoPlayer> snapshot() {
        final ArrayList<ExoPlayer> live = new ArrayList<>();
        synchronized (LOCK) {
            pruneLocked();
            for (WeakReference<ExoPlayer> ref : PLAYERS) {
                final ExoPlayer player = ref.get();
                if (player != null) live.add(player);
            }
        }
        return live;
    }

    private static void pruneLocked() {
        for (int i = PLAYERS.size() - 1; i >= 0; i--) {
            if (PLAYERS.get(i).get() == null) PLAYERS.remove(i);
        }
    }

    /** True while ExoPlayer still has playWhenReady and has not ended. */
    public static boolean isAudible() {
        for (final ExoPlayer player : snapshot()) {
            final int state = player.getPlaybackState();
            if (!player.getPlayWhenReady()) {
                continue;
            }
            if (state == Player.STATE_IDLE || state == Player.STATE_ENDED) {
                continue;
            }
            return true;
        }
        return false;
    }

    /** Pauses so another app can take the DAC. Idle and ended players stay put. */
    public static void pauseForFocus() {
        final List<ExoPlayer> live = snapshot();
        for (final ExoPlayer player : live) {
            final CountDownLatch latch = new CountDownLatch(1);
            final Runnable task = () -> {
                try {
                    final int state = player.getPlaybackState();
                    if (state != Player.STATE_IDLE && state != Player.STATE_ENDED) {
                        player.pause();
                    }
                } finally {
                    latch.countDown();
                }
            };
            if (Looper.myLooper() == player.getApplicationLooper()) {
                task.run();
            } else {
                new Handler(player.getApplicationLooper()).post(task);
                try {
                    latch.await(700, TimeUnit.MILLISECONDS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        }
    }

    /** Rebuilds the audio sink after a direct USB stream opens mid-playback. */
    public static void flushToApplySink() {
        final List<ExoPlayer> live = snapshot();
        for (final ExoPlayer player : live) {
            final Runnable task = () -> {
                final int state = player.getPlaybackState();
                if (!player.getPlayWhenReady()) {
                    return;
                }
                if (state != Player.STATE_READY && state != Player.STATE_BUFFERING) {
                    return;
                }
                player.seekTo(player.getCurrentPosition());
            };
            if (Looper.myLooper() == player.getApplicationLooper()) {
                task.run();
            } else {
                new Handler(player.getApplicationLooper()).post(task);
            }
        }
    }
}
