package com.likepod.likepod

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Foreground service that outlives the activity.
 *
 * [mediaPlayback] is what Android uses to keep a mixer stream audible.
 * [connectedDevice] is added only while this process owns the USB interface,
 * so isochronous transfers are still allowed after Home.
 */
class PlaybackService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getBooleanExtra(EXTRA_STOP, false) == true) {
            releaseWake()
            try {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } catch (_: Throwable) {
            }
            stopSelf()
            return START_NOT_STICKY
        }
        val usb = intent?.getBooleanExtra(EXTRA_USB, false) == true
        promote(usb)
        acquireWake()
        if (usb) {
            UsbExclusive.keepForService("playback-service")
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWake()
        super.onDestroy()
    }

    private fun promote(usb: Boolean) {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) {
            val media = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            val connected = if (Build.VERSION.SDK_INT >= 29) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            } else {
                0
            }
            if (usb) {
                try {
                    startForeground(NOTIFICATION_ID, notification, media or connected)
                    return
                } catch (error: Throwable) {
                    Log.i(TAG, "Connected-device foreground skipped: ${error.message}")
                }
            }
            try {
                startForeground(NOTIFICATION_ID, notification, media)
                return
            } catch (error: Throwable) {
                Log.i(TAG, "Typed foreground skipped: ${error.message}")
            }
        }
        startForeground(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "LikePod 后台播放",
                    NotificationManager.IMPORTANCE_LOW,
                )
                channel.setShowBadge(false)
                channel.description = "离开界面后继续出声"
                manager.createNotificationChannel(channel)
            }
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("LikePod")
            .setContentText("正在后台播放")
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .build()
    }

    private fun acquireWake() {
        try {
            val lock = wakeLock ?: run {
                val power = getSystemService(POWER_SERVICE) as PowerManager
                power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LikePod:playback").also {
                    it.setReferenceCounted(false)
                    wakeLock = it
                }
            }
            if (!lock.isHeld) {
                lock.acquire()
            }
        } catch (error: Throwable) {
            Log.i(TAG, "Playback wake lock skipped: ${error.message}")
        }
    }

    private fun releaseWake() {
        try {
            val lock = wakeLock
            if (lock != null && lock.isHeld) {
                lock.release()
            }
        } catch (_: Throwable) {
        }
    }

    companion object {
        private const val TAG = "LikePod"
        const val EXTRA_USB = "usb"
        const val EXTRA_STOP = "stop"
        private const val CHANNEL_ID = "com.likepod.likepod.channel.keepalive"
        private const val NOTIFICATION_ID = 1125
    }
}
