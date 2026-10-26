package com.likepod.likepod

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.util.Log
import java.io.File

/**
 * Click-wheel ticks on the music stream.
 *
 * Sonification follows the touch/system stream. That stream is often muted,
 * and it does not follow Bluetooth or a USB DAC the mixer already selected.
 * Exclusive USB used to mix the tick into the DAC packets; after that path
 * was removed, the sonification tick was silent on the output in use.
 *
 * [AudioAttributes.USAGE_MEDIA] shares speaker, Bluetooth, and mixer-routed
 * USB with the song. [AudioAttributes.FLAG_LOW_LATENCY] asks for a short
 * buffer so the tick lands with the finger. SoundPool does not request
 * audio focus. The pool is created once and kept warm.
 *
 * 0.26 is about −12 dB under full scale: quieter than the song, and loud
 * enough on Bluetooth and a mixer-routed USB DAC. 0.10 was audible on
 * PME110 but too soft.
 */
object WheelSounds {
    private const val TAG = "LikePod"

    /** Linear amplitude. Keep in sync with [SoundService.clickVolume]. */
    private const val CLICK_VOLUME = 0.26f

    private var pool: SoundPool? = null
    private var tickId = 0
    private var selectId = 0
    private var tickReady = false
    private var selectReady = false
    private var lastTickAt = 0L
    private val pending = ArrayList<String>()

    /** One audible tick. Faster events overlap the same 48 ms clip. */
    private const val TICK_GAP_MS = 80L

    fun prepare(context: Context) {
        ensure(context.applicationContext)
    }

    /**
     * True when this pool will play the tick, including one still loading.
     * False only when the asset is missing, so Dart can try its own player.
     * Returning false while the sample is loading made Dart open a second,
     * slower player for the same click.
     */
    fun play(context: Context, kind: String): Boolean {
        val app = context.applicationContext
        ensure(app)
        if (kind != "select" && !tickDue()) return true
        if (playPool(kind)) {
            if (kind != "select") lastTickAt = android.os.SystemClock.uptimeMillis()
            return true
        }
        val id = soundId(kind)
        val ready = if (kind == "select") selectReady else tickReady
        if (pool != null && id != 0 && !ready) {
            if (kind == "select") {
                pending.removeAll { it == "select" }
            } else {
                pending.removeAll { it != "select" }
                lastTickAt = android.os.SystemClock.uptimeMillis()
            }
            pending.add(kind)
            return true
        }
        return false
    }

    private fun tickDue(): Boolean {
        return android.os.SystemClock.uptimeMillis() - lastTickAt >= TICK_GAP_MS
    }

    private fun ensure(app: Context) {
        if (pool != null) return
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .setFlags(AudioAttributes.FLAG_LOW_LATENCY)
            .build()
        val created = SoundPool.Builder()
            .setMaxStreams(8)
            .setAudioAttributes(attrs)
            .build()
        created.setOnLoadCompleteListener { _, sampleId, status ->
            if (status == 0) {
                if (sampleId == tickId) tickReady = true
                if (sampleId == selectId) selectReady = true
            }
            val queued = pending.toList()
            pending.clear()
            if (queued.any { it == "select" }) playPool("select")
            if (queued.any { it != "select" }) playPool("tick")
        }
        pool = created
        val tick = writeAsset(app, "tick.wav")
        val select = writeAsset(app, "select.wav")
        if (tick != null) {
            tickId = created.load(tick.absolutePath, 1)
        }
        if (select != null) {
            selectId = created.load(select.absolutePath, 1)
        }
    }

    private fun soundId(kind: String): Int {
        return if (kind == "select") selectId else tickId
    }

    private fun playPool(kind: String): Boolean {
        val soundPool = pool ?: return false
        val id = soundId(kind)
        val ready = if (kind == "select") selectReady else tickReady
        if (id == 0 || !ready) return false
        val stream = soundPool.play(id, CLICK_VOLUME, CLICK_VOLUME, 1, 0, 1f)
        return stream != 0
    }

    private fun writeAsset(app: Context, name: String): File? {
        val bytes = readAsset(app, name) ?: return null
        val file = File(app.cacheDir, "likepod-$name")
        file.writeBytes(bytes)
        return file
    }

    private fun readAsset(app: Context, name: String): ByteArray? {
        val paths = listOf(
            "flutter_assets/assets/audio/$name",
            "assets/audio/$name",
        )
        for (path in paths) {
            try {
                app.assets.open(path).use { return it.readBytes() }
            } catch (_: Throwable) {
            }
        }
        Log.i(TAG, "Wheel sound asset missing: $name")
        return null
    }
}
