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
 * [mediaPlayback] is what Android uses to keep a mixer stream audible
 * after Home. The service does not claim a USB device.
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
        promote(intent?.getBooleanExtra(EXTRA_WAITING, false) == true)
        acquireWake()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWake()
        super.onDestroy()
    }

    private fun promote(waiting: Boolean) {
        val notification = buildNotification(waiting)
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
                return
            } catch (error: Throwable) {
                Log.i(TAG, "Typed foreground skipped: ${error.message}")
            }
        }
        startForeground(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(waiting: Boolean): Notification {
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
            .setContentText(if (waiting) "等待继续播放" else "正在后台播放")
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
        const val EXTRA_STOP = "stop"
        const val EXTRA_WAITING = "waiting"
        private const val CHANNEL_ID = "com.likepod.likepod.channel.keepalive"
        private const val NOTIFICATION_ID = 1125
    }
}
