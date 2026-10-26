package com.likepod.likepod

import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import androidx.annotation.NonNull
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

/**
 * System-mixer playback. USB DACs are used only when Android routes the
 * music stream to them. This activity does not open usbfs or claim an
 * interface.
 */
class MainActivity : AudioServiceActivity() {
    override fun onPause() {
        PlaybackFocus.noteHostLeaving()
        super.onPause()
        PlaybackAnchor.reassert(this)
    }

    override fun onStop() {
        PlaybackFocus.noteHostLeaving()
        super.onStop()
        PlaybackFocus.setBackground(true)
        PlaybackAnchor.onHostBackground(this)
        mainHandler.post { PlaybackFocus.noteHostLeaveSettled() }
    }

    override fun onStart() {
        super.onStart()
        PlaybackFocus.setBackground(false)
        PlaybackFocus.noteHostVisible()
        PlaybackAnchor.onHostForeground(this)
    }

    private val CHANNEL = "com.likepod/media"
    private val WHEEL_CHANNEL = "com.likepod/wheel"
    private var mediaChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var deviceCallbackRegistered = false
    private var outputCallback: AudioDeviceCallback? = null
    private var deviceEvent: Runnable? = null
    private var trackSpectrum: TrackSpectrum? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        // Before any AudioTrack. A policy applied after the track exists
        // does not change that track, and the visualizer then reads zeros.
        TrackSpectrum.allowPlaybackCapture(this)
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        mediaChannel = channel
        // Clicks do not share the media channel. A scan or focus call on
        // that channel would hold the tick until it returned.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WHEEL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepareWheelSound" -> {
                        WheelSounds.prepare(this)
                        result.success(true)
                    }
                    "playWheelSound" -> {
                        val kind = call.argument<String>("kind") ?: "tick"
                        result.success(WheelSounds.play(this, kind))
                    }
                    else -> result.notImplemented()
                }
            }
        WheelSounds.prepare(this)
        trackSpectrum = TrackSpectrum(this, flutterEngine.dartExecutor.binaryMessenger).also {
            it.attach()
        }
        registerOutputWatcher()

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSongs" -> {
                    try {
                        result.success(fetchSongs())
                    } catch (e: Exception) {
                        result.error("QUERY_ERROR", e.message, null)
                    }
                }
                "getArtwork" -> {
                    val albumId = call.argument<Number>("albumId")?.toLong()
                    if (albumId != null) {
                        try {
                            result.success(fetchArtwork(albumId))
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    } else {
                        result.success(null)
                    }
                }
                "getBatteryLevel" -> {
                    try {
                        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                        result.success(if (level in 0..100) level else 100)
                    } catch (e: Exception) {
                        result.success(100)
                    }
                }
                "getVolume" -> {
                    try {
                        result.success(readMusicVolumeRatio())
                    } catch (e: Exception) {
                        result.success(0.7)
                    }
                }
                "setVolume" -> {
                    try {
                        val volume = call.argument<Double>("volume") ?: 0.5
                        val writeSystem = call.argument<Boolean>("writeSystem") != false
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val target = (volume * max).roundToInt().coerceIn(0, max)
                        if (writeSystem && max > 0) {
                            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                        }
                        val reported = if (max > 0) target.toDouble() / max.toDouble() else volume
                        result.success(reported)
                    } catch (e: Exception) {
                        result.error("VOLUME_ERROR", e.message, null)
                    }
                }
                "listOutputSinks" -> {
                    try {
                        result.success(listOutputSinks())
                    } catch (e: Exception) {
                        result.success(mapOf("outputSampleRate" to null, "sinks" to emptyList<Any>()))
                    }
                }
                "holdPlayback" -> {
                    val user = call.argument<Boolean>("user") == true
                    val granted = holdAudioFocus(user)
                    Log.i("LikePod", "holdPlayback granted=$granted user=$user")
                    if (!granted) {
                        // A yield re-anchor returns false on purpose. Dropping
                        // the playing flag is fine; dropping the yield is not.
                        if (!PlaybackFocus.isAwaitingReturn()) {
                            PlaybackAnchor.setPlaying(this, false)
                        }
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    PlaybackAnchor.setPlaying(this, true)
                    result.success(true)
                }
                "userPause" -> {
                    PlaybackAnchor.setPlaying(this, false)
                    PlaybackFocus.abandon(this)
                    result.success(true)
                }
                "moveTaskToBack" -> {
                    result.success(moveTaskToBack(true))
                }
                "releasePlayback" -> {
                    val userStopped = call.argument<Boolean>("userStopped") == true
                    if (userStopped) {
                        PlaybackAnchor.setPlaying(this, false)
                        PlaybackFocus.abandon(this)
                    }
                    result.success(true)
                }
                "prepareWheelSound" -> {
                    WheelSounds.prepare(this)
                    result.success(true)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    // HyperOS freezes this process ~20s after audio pauses.
                    // The battery whitelist keeps notification controls usable.
                    try {
                        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                        if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                            val intent = Intent(
                                android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName"),
                            )
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "playWheelSound" -> {
                    val kind = call.argument<String>("kind") ?: "tick"
                    result.success(WheelSounds.play(this, kind))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun holdAudioFocus(userRequested: Boolean): Boolean {
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        return PlaybackFocus.hold(
            this,
            attributes,
            mainHandler,
            onLost = {
                PlaybackAnchor.setPlaying(this, false)
                mediaChannel?.invokeMethod("onAudioFocusLost", null)
            },
            onGained = {
                mediaChannel?.invokeMethod("onAudioFocusGained", null)
            },
            userRequested = userRequested,
        )
    }

    private fun readMusicVolumeRatio(): Double {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        return if (max > 0) current.toDouble() / max.toDouble() else 0.7
    }

    private fun fetchSongs(): List<Map<String, Any>> {
        val songList = mutableListOf<Map<String, Any>>()
        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.ALBUM_ID,
        )
        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.DURATION} >= 10000"
        val sortOrder = "${MediaStore.Audio.Media.TITLE} ASC"

        contentResolver.query(uri, projection, selection, null, sortOrder)?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
            val albumIdCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idCol)
                val title = cursor.getString(titleCol) ?: "Unknown Title"
                val artist = cursor.getString(artistCol) ?: "Unknown Artist"
                val album = cursor.getString(albumCol) ?: "Unknown Album"
                val duration = cursor.getLong(durationCol)
                val path = cursor.getString(dataCol) ?: ""
                val albumId = cursor.getLong(albumIdCol)
                val contentUri = ContentUris.withAppendedId(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                    id,
                ).toString()
                songList.add(
                    mapOf(
                        "id" to id,
                        "title" to title,
                        "artist" to artist,
                        "album" to album,
                        "duration" to duration,
                        "path" to path,
                        "contentUri" to contentUri,
                        "albumId" to albumId,
                    ),
                )
            }
        }
        return songList
    }

    private fun fetchArtwork(albumId: Long): ByteArray? {
        val artworkUri = ContentUris.withAppendedId(
            Uri.parse("content://media/external/audio/albumart"),
            albumId,
        )
        return try {
            contentResolver.openInputStream(artworkUri)?.use { inputStream ->
                val buffer = ByteArrayOutputStream()
                val data = ByteArray(4096)
                var nRead: Int
                while (inputStream.read(data, 0, data.size).also { nRead = it } != -1) {
                    buffer.write(data, 0, nRead)
                }
                buffer.toByteArray()
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun registerOutputWatcher() {
        if (deviceCallbackRegistered) return
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                scheduleOutputEvent()
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                scheduleOutputEvent()
            }
        }
        outputCallback = callback
        audioManager.registerAudioDeviceCallback(callback, mainHandler)
        deviceCallbackRegistered = true
    }

    private fun scheduleOutputEvent() {
        deviceEvent?.let { mainHandler.removeCallbacks(it) }
        val task = Runnable {
            mediaChannel?.invokeMethod("onOutputDevicesChanged", null)
        }
        deviceEvent = task
        mainHandler.postDelayed(task, 200)
    }

    private fun listOutputSinks(): Map<String, Any?> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val reportedRate = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()
        val routedIds = routedOutputIds(audioManager)
        val sinks = mutableListOf<Map<String, Any?>>()
        audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).forEach { device ->
            if (!device.isSink) return@forEach
            val rates = mutableListOf<Int>()
            device.sampleRates.forEach { rate ->
                if (rate > 0 && !rates.contains(rate)) rates.add(rate)
            }
            rates.sort()
            val encodings = mutableListOf<Int>()
            device.encodings.forEach { encoding -> encodings.add(encoding) }
            sinks.add(
                mapOf(
                    "id" to device.id,
                    "name" to sinkName(device),
                    "type" to device.type,
                    "sampleRates" to rates,
                    "encodings" to encodings,
                    "routed" to routedIds.contains(device.id),
                ),
            )
        }
        return mapOf("outputSampleRate" to reportedRate, "sinks" to sinks)
    }

    private fun routedOutputIds(audioManager: AudioManager): Set<Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return emptySet()
        return try {
            val method = AudioManager::class.java.getMethod(
                "getDevicesForAttributes",
                AudioAttributes::class.java,
            )
            val routed = method.invoke(audioManager, mediaAttributes()) as? Array<*>
            val ids = mutableSetOf<Int>()
            routed?.forEach { item ->
                val info = item as? AudioDeviceInfo ?: return@forEach
                ids.add(info.id)
            }
            ids
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun sinkName(device: AudioDeviceInfo): String {
        val product = device.productName?.toString()?.trim().orEmpty()
        if (product.isNotEmpty()) return product
        return when (device.type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
            -> "扬声器"
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            -> "有线耳机"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_BLE_BROADCAST,
            -> "蓝牙"
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            -> "USB"
            else -> "其他"
        }
    }

    private fun mediaAttributes(): AudioAttributes {
        return AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
    }

    override fun onDestroy() {
        outputCallback?.let { callback ->
            try {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                audioManager.unregisterAudioDeviceCallback(callback)
            } catch (_: Exception) {
            }
        }
        outputCallback = null
        deviceCallbackRegistered = false
        deviceEvent?.let { mainHandler.removeCallbacks(it) }
        trackSpectrum?.release()
        trackSpectrum = null
        super.onDestroy()
    }
}
