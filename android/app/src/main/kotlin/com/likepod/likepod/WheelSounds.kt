package com.likepod.likepod

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.util.Log
import java.io.File

/**
 * Click-wheel ticks through the system mixer. SoundPool follows the
 * current output, including a USB DAC that Android has already routed.
 */
object WheelSounds {
    private const val TAG = "LikePod"

    /** Linear amplitude. 0.016 is −36 dB, a soft click on speaker and Bluetooth. */
    private const val CLICK_VOLUME = 0.016f

    private var pool: SoundPool? = null
    private var tickId = 0
    private var selectId = 0
    private val pending = ArrayList<String>()

    fun prepare(context: Context) {
        ensure(context.applicationContext)
    }

    /** True when a tick was started here. False lets Dart try its own player. */
    fun play(context: Context, kind: String): Boolean {
        val app = context.applicationContext
        ensure(app)
        val pooled = playPool(kind)
        if (!pooled) {
            pending.add(kind)
        }
        return pooled
    }

    private fun ensure(app: Context) {
        if (pool != null) return
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val created = SoundPool.Builder()
            .setMaxStreams(8)
            .setAudioAttributes(attrs)
            .build()
        created.setOnLoadCompleteListener { _, _, status ->
            if (status != 0) return@setOnLoadCompleteListener
            val queued = pending.toList()
            pending.clear()
            for (kind in queued) {
                playPool(kind)
            }
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

    private fun playPool(kind: String): Boolean {
        val soundPool = pool ?: return false
        val id = if (kind == "select") selectId else tickId
        if (id == 0) return false
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
