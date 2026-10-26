package com.likepod.likepod

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log

/**
 * Silent player that exists only so a long focus yield is not frozen.
 *
 * HyperOS freezes a background process about twenty seconds after its own
 * audio stops, including one that still has a media foreground service and
 * a partial wake lock. Short videos end before that freeze, so the reclaim
 * poll still runs. A long video outlives it. Xiaohongshu still resumes
 * because `AUDIOFOCUS_GAIN` is delivered by the system and that binder call
 * thaws the process. A permanent loss never sends that callback.
 *
 * A started playback row for this uid keeps the process in the "playing
 * audio" set. The track is sonification, not the music stream, so
 * [android.media.AudioManager.isMusicActive] still describes the other app.
 * The buffer is digital silence. The track does not request
 * audio focus. It stops when real playback starts or the user pauses.
 */
object YieldKeepAlive {
    private const val TAG = "LikePod"
    private const val SAMPLE_RATE = 16000

    @Volatile
    private var running = false

    private var track: AudioTrack? = null
    private var writer: Thread? = null

    @Synchronized
    fun isRunning(): Boolean {
        val existing = track
        return running && existing != null && existing.playState == AudioTrack.PLAYSTATE_PLAYING
    }

    @Synchronized
    fun start() {
        val existing = track
        if (running && existing != null && existing.playState == AudioTrack.PLAYSTATE_PLAYING) {
            return
        }
        stop()
        try {
            val minBytes = AudioTrack.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            ).coerceAtLeast(SAMPLE_RATE / 5 * 2)
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val format = AudioFormat.Builder()
                .setSampleRate(SAMPLE_RATE)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build()
            val created = AudioTrack.Builder()
                .setAudioAttributes(attributes)
                .setAudioFormat(format)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(minBytes)
                .build()
            // Samples are silence. A non-zero track volume keeps the row
            // "playing" on builds that ignore a zero-volume track.
            created.setVolume(0.001f)
            created.play()
            val silence = ByteArray(minBytes)
            running = true
            track = created
            val thread = Thread({
                while (running) {
                    val written = try {
                        created.write(silence, 0, silence.size)
                    } catch (_: Throwable) {
                        break
                    }
                    if (written < 0) break
                }
            }, "likepod-yield-keepalive")
            thread.isDaemon = true
            writer = thread
            thread.start()
            Log.i(TAG, "yield keepalive track started")
        } catch (error: Throwable) {
            Log.i(TAG, "yield keepalive track skipped: ${error.message}")
            stop()
        }
    }

    @Synchronized
    fun stop() {
        running = false
        val created = track
        track = null
        try {
            created?.pause()
        } catch (_: Throwable) {
        }
        try {
            writer?.join(300)
        } catch (_: Throwable) {
        }
        writer = null
        if (created == null) return
        try {
            created.flush()
            created.release()
            Log.i(TAG, "yield keepalive track stopped")
        } catch (error: Throwable) {
            Log.i(TAG, "yield keepalive track stop failed: ${error.message}")
        }
    }
}
