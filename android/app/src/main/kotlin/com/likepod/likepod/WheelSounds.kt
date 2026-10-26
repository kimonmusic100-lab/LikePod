package com.likepod.likepod

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Click-wheel ticks. SoundPool starts a new stream on every step.
 * When the DAC is opened exclusively, the same clip is mixed into the USB
 * packets so the tick is still audible on that output.
 */
object WheelSounds {
    private const val TAG = "LikePod"

    /** Linear amplitude. 0.016 is −36 dB, a soft click on speaker and Bluetooth. */
    private const val CLICK_VOLUME = 0.016f

    private var pool: SoundPool? = null
    private var tickId = 0
    private var selectId = 0
    private var tickPcm: ByteArray? = null
    private var selectPcm: ByteArray? = null
    private var tickRate = 44100
    private var selectRate = 44100
    private val pending = ArrayList<String>()

    fun prepare(context: Context) {
        ensure(context.applicationContext)
    }

    /** True when a tick was started here. False lets Dart try its own player. */
    fun play(context: Context, kind: String): Boolean {
        val app = context.applicationContext
        ensure(app)
        val mixed = mixUsb(kind)
        val pooled = playPool(kind)
        if (!pooled && !mixed) {
            pending.add(kind)
        }
        return mixed || pooled
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
                mixUsb(kind)
            }
        }
        pool = created
        val tick = loadWav(app, "tick.wav")
        val select = loadWav(app, "select.wav")
        if (tick != null) {
            tickPcm = tick.pcm
            tickRate = tick.rate
            tickId = created.load(tick.file.absolutePath, 1)
        }
        if (select != null) {
            selectPcm = select.pcm
            selectRate = select.rate
            selectId = created.load(select.file.absolutePath, 1)
        }
    }

    private fun playPool(kind: String): Boolean {
        val soundPool = pool ?: return false
        val id = if (kind == "select") selectId else tickId
        if (id == 0) return false
        val stream = soundPool.play(id, CLICK_VOLUME, CLICK_VOLUME, 1, 0, 1f)
        return stream != 0
    }

    private fun mixUsb(kind: String): Boolean {
        if (!UsbExclusive.current.active || !UsbExclusiveNative.libraryLoaded()) {
            return false
        }
        val pcm = if (kind == "select") selectPcm else tickPcm
        val rate = if (kind == "select") selectRate else tickRate
        if (pcm == null || pcm.size < 2) return false
        return try {
            UsbExclusiveNative.nativeQueueClick(pcm, pcm.size / 2, rate)
        } catch (error: Throwable) {
            Log.i(TAG, "USB click mix failed: ${error.message}")
            false
        }
    }

    private data class Wav(val file: File, val pcm: ByteArray, val rate: Int)

    private fun loadWav(app: Context, name: String): Wav? {
        val bytes = readAsset(app, name) ?: return null
        val parsed = parsePcm16(bytes) ?: return null
        val file = File(app.cacheDir, "likepod-$name")
        file.writeBytes(bytes)
        return Wav(file, parsed.first, parsed.second)
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

    /** Mono or the first channel of 16-bit PCM, plus the sample rate. */
    private fun parsePcm16(wav: ByteArray): Pair<ByteArray, Int>? {
        if (wav.size < 44) return null
        var rate = 44100
        var channels = 1
        var offset = 12
        var data: ByteArray? = null
        while (offset + 8 <= wav.size) {
            val id = String(wav, offset, 4, Charsets.US_ASCII)
            val size = ByteBuffer.wrap(wav, offset + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            val start = offset + 8
            if (size < 0 || start + size > wav.size) break
            if (id == "fmt " && size >= 16) {
                val fmt = ByteBuffer.wrap(wav, start, size).order(ByteOrder.LITTLE_ENDIAN)
                val format = fmt.short.toInt() and 0xFFFF
                channels = fmt.short.toInt() and 0xFFFF
                rate = fmt.int
                fmt.int
                fmt.short
                val bits = fmt.short.toInt() and 0xFFFF
                if (format != 1 || bits != 16 || channels < 1 || rate <= 0) return null
            } else if (id == "data") {
                data = wav.copyOfRange(start, start + size)
            }
            offset = start + size + (size and 1)
        }
        val pcm = data ?: return null
        if (channels == 1) return pcm to rate
        val frames = pcm.size / (2 * channels)
        val mono = ByteArray(frames * 2)
        var inPos = 0
        var outPos = 0
        while (outPos + 1 < mono.size && inPos + 1 < pcm.size) {
            mono[outPos] = pcm[inPos]
            mono[outPos + 1] = pcm[inPos + 1]
            outPos += 2
            inPos += 2 * channels
        }
        return mono to rate
    }
}
