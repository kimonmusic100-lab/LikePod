package com.likepod.likepod

import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max

/**
 * FFT of this app's own playback session. Session 0 (the output mix) is not
 * used. A missing capture permission comes back as "permission" so Dart can
 * ask once, then give up without inventing motion.
 */
class TrackSpectrum(messenger: BinaryMessenger) {
    private val method = MethodChannel(messenger, CHANNEL)
    private val events = EventChannel(messenger, EVENT)
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var visualizer: Visualizer? = null
    private var session: Int = -1

    fun attach() {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val id = call.argument<Int>("sessionId") ?: 0
                    result.success(start(id))
                }
                "stop" -> {
                    stop()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
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
        if (sessionId <= 0) return "unavailable"
        if (visualizer != null && session == sessionId) return "ok"
        stop()
        return try {
            val effect = Visualizer(sessionId)
            val range = Visualizer.getCaptureSizeRange()
            effect.captureSize = range[1]
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
                        val bands = bandsFromFft(fft)
                        main.post { sink?.success(bands) }
                    }
                },
                Visualizer.getMaxCaptureRate(),
                false,
                true,
            )
            effect.enabled = true
            visualizer = effect
            session = sessionId
            "ok"
        } catch (e: SecurityException) {
            "permission"
        } catch (e: RuntimeException) {
            val message = e.message ?: ""
            if (message.contains("permission", ignoreCase = true)) {
                "permission"
            } else {
                "unavailable"
            }
        }
    }

    private fun stop() {
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

    companion object {
        private const val CHANNEL = "com.likepod/spectrum"
        private const val EVENT = "com.likepod/spectrum_events"
        private const val BANDS = 24

        fun bandsFromFft(fft: ByteArray): List<Double> {
            val bins = fft.size / 2
            if (bins < 4) return List(BANDS) { 0.0 }
            val magnitudes = FloatArray(bins)
            for (i in 0 until bins) {
                val real = fft[i * 2].toInt().toFloat()
                val imag = fft[i * 2 + 1].toInt().toFloat()
                val mag = hypot(real, imag) / 128f
                val db = 20.0 * ln((mag + 1e-4).toDouble()) / ln(10.0)
                magnitudes[i] = ((db + 58.0) / 58.0).toFloat().coerceIn(0f, 1f)
            }
            val out = ArrayList<Double>(BANDS)
            val usable = max(2, bins - 2)
            for (band in 0 until BANDS) {
                val start = 2 + band * usable / BANDS
                val end = 2 + (band + 1) * usable / BANDS
                var peak = 0f
                var i = start
                while (i < max(start + 1, end) && i < bins) {
                    if (magnitudes[i] > peak) peak = magnitudes[i]
                    i++
                }
                out.add(peak.toDouble())
            }
            return out
        }
    }
}
