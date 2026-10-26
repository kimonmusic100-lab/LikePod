package com.likepod.likepod

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.audiofx.Visualizer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max

/**
 * FFT of the playing track. The player's own session is tried first. Session 0
 * is the output mix, used only after Dart asks for it. Every attach is logged
 * as `wave attach sessionId=… ok` or `fail <reason>` under the LikePod tag.
 */
class TrackSpectrum(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val method = MethodChannel(messenger, CHANNEL)
    private val events = EventChannel(messenger, EVENT)
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var visualizer: Visualizer? = null
    private var session: Int = -1
    private var lastCallbackMs = 0L
    private var lastSendMs = 0L
    private var lastLogMs = 0L
    private var sawEnergy = false

    private val poll = object : Runnable {
        override fun run() {
            val effect = visualizer ?: return
            val now = SystemClock.uptimeMillis()
            if (now - lastCallbackMs > 250L) {
                readEffect(effect, "poll")
            }
            main.postDelayed(this, 50L)
        }
    }

    fun attach() {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val id = sessionArgument(call.arguments)
                    result.success(start(id))
                }
                "stop" -> {
                    stop()
                    result.success(true)
                }
                "log" -> {
                    val message = call.argument<String>("message") ?: ""
                    Log.i(TAG, message)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                    Log.i(TAG, "wave stream listen")
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                    Log.i(TAG, "wave stream cancel")
                }
            },
        )
    }

    fun release() {
        stop()
        sink = null
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    private fun start(sessionId: Int): String {
        if (sessionId < 0) {
            Log.i(TAG, "wave attach sessionId=$sessionId fail bad-id")
            return "unavailable"
        }
        if (visualizer != null && session == sessionId && visualizer?.enabled == true) {
            Log.i(TAG, "wave attach sessionId=$sessionId ok")
            return "ok"
        }
        stop()
        allowAppCapture()
        return try {
            val effect = Visualizer(sessionId)
            val range = Visualizer.getCaptureSizeRange()
            effect.captureSize = range[1]
            val rate = max(1000, Visualizer.getMaxCaptureRate() / 2)
            effect.setDataCaptureListener(
                object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(
                        visualizer: Visualizer,
                        waveform: ByteArray,
                        samplingRate: Int,
                    ) {
                    }

                    override fun onFftDataCapture(
                        visualizer: Visualizer,
                        fft: ByteArray,
                        samplingRate: Int,
                    ) {
                        lastCallbackMs = SystemClock.uptimeMillis()
                        val bands = bandsFromFft(fft)
                        if (peak(bands) > 0.04) publish(bands, "fft")
                    }
                },
                rate,
                false,
                true,
            )
            effect.enabled = true
            if (!effect.enabled) {
                effect.release()
                Log.i(TAG, "wave attach sessionId=$sessionId fail not-enabled")
                return "unavailable"
            }
            visualizer = effect
            session = sessionId
            sawEnergy = false
            lastCallbackMs = 0L
            main.removeCallbacks(poll)
            main.post(poll)
            Log.i(TAG, "wave attach sessionId=$sessionId ok")
            "ok"
        } catch (e: SecurityException) {
            Log.i(TAG, "wave attach sessionId=$sessionId fail permission ${e.message}")
            "permission"
        } catch (e: Exception) {
            val message = e.message ?: e.javaClass.simpleName
            val permission = message.contains("permission", ignoreCase = true)
            Log.i(
                TAG,
                "wave attach sessionId=$sessionId fail ${if (permission) "permission" else message}",
            )
            if (permission) "permission" else "unavailable"
        }
    }

    private fun stop() {
        main.removeCallbacks(poll)
        session = -1
        val effect = visualizer
        visualizer = null
        if (effect == null) return
        try {
            effect.enabled = false
        } catch (_: Exception) {
        }
        try {
            effect.release()
        } catch (_: Exception) {
        }
    }

    private fun readEffect(effect: Visualizer, source: String) {
        try {
            val fft = ByteArray(effect.captureSize)
            val wave = ByteArray(effect.captureSize)
            val fftStatus = effect.getFft(fft)
            if (fftStatus == Visualizer.SUCCESS) {
                val bands = bandsFromFft(fft)
                if (peak(bands) > 0.04) {
                    publish(bands, source)
                    return
                }
            }
            if (effect.getWaveForm(wave) == Visualizer.SUCCESS) {
                publish(bandsFromWaveform(wave), source)
            }
        } catch (e: Exception) {
            val now = SystemClock.uptimeMillis()
            if (now - lastLogMs > 2000L) {
                lastLogMs = now
                Log.i(TAG, "wave poll fail ${e.message}")
            }
        }
    }

    private fun publish(bands: List<Double>, source: String) {
        val now = SystemClock.uptimeMillis()
        if (now - lastSendMs < 40L) return
        lastSendMs = now
        val level = peak(bands)
        if (level > 0.05) {
            if (!sawEnergy || now - lastLogMs > 5000L) {
                sawEnergy = true
                lastLogMs = now
                Log.i(TAG, "wave frame sessionId=$session source=$source peak=%.2f".format(level))
            }
        } else if (now - lastLogMs > 2000L) {
            lastLogMs = now
            Log.i(TAG, "wave frame sessionId=$session source=$source peak=0")
        }
        val target = sink ?: return
        main.post {
            try {
                target.success(bands)
            } catch (_: Exception) {
            }
        }
    }

    private fun allowAppCapture() {
        if (Build.VERSION.SDK_INT < 29) return
        try {
            val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            manager.allowedCapturePolicy = AudioAttributes.ALLOW_CAPTURE_BY_ALL
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val TAG = "LikePod"
        private const val CHANNEL = "com.likepod/spectrum"
        private const val EVENT = "com.likepod/spectrum_events"
        const val BANDS = 24

        fun sessionArgument(arguments: Any?): Int {
            val raw = (arguments as? Map<*, *>)?.get("sessionId")
            return when (raw) {
                is Int -> raw
                is Long -> raw.toInt()
                is Number -> raw.toInt()
                else -> -1
            }
        }

        fun peak(bands: List<Double>): Double {
            var best = 0.0
            for (value in bands) {
                if (value > best) best = value
            }
            return best
        }

        fun bandsFromFft(fft: ByteArray): List<Double> {
            val bins = fft.size / 2
            if (bins < 4) return List(BANDS) { 0.0 }
            val magnitudes = FloatArray(bins)
            for (i in 0 until bins) {
                val real = fft[i * 2].toInt().toFloat()
                val imag = if (i * 2 + 1 < fft.size) fft[i * 2 + 1].toInt().toFloat() else 0f
                val mag = hypot(real, imag)
                val raw = (mag / 28f).coerceIn(0f, 1f)
                val db = 20.0 * ln((mag / 128.0) + 1e-4) / ln(10.0)
                val curved = ((db + 52.0) / 52.0).toFloat().coerceIn(0f, 1f)
                magnitudes[i] = max(raw, curved)
            }
            val out = ArrayList<Double>(BANDS)
            val usable = max(2, bins - 2)
            for (band in 0 until BANDS) {
                val start = 2 + band * usable / BANDS
                val end = 2 + (band + 1) * usable / BANDS
                var high = 0f
                var i = start
                val limit = max(start + 1, end)
                while (i < limit && i < bins) {
                    if (magnitudes[i] > high) high = magnitudes[i]
                    i++
                }
                out.add(high.toDouble())
            }
            return out
        }

        fun bandsFromWaveform(wave: ByteArray): List<Double> {
            if (wave.isEmpty()) return List(BANDS) { 0.0 }
            val out = ArrayList<Double>(BANDS)
            for (band in 0 until BANDS) {
                val start = band * wave.size / BANDS
                val end = (band + 1) * wave.size / BANDS
                var high = 0
                var i = start
                while (i < end) {
                    val sample = abs((wave[i].toInt() and 0xff) - 128)
                    if (sample > high) high = sample
                    i++
                }
                out.add((high / 48.0).coerceIn(0.0, 1.0))
            }
            return out
        }
    }
}
