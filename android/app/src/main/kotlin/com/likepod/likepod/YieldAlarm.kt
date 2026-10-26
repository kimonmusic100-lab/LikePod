package com.likepod.likepod

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log

/**
 * Wakes a yielded process that the in-process poll can no longer run.
 *
 * Armed only while a focus yield is waiting. A few seconds is enough to
 * notice the other app has stopped after a long video, without a timer
 * when the user paused or nothing is waiting.
 */
object YieldAlarm {
    private const val TAG = "LikePod"
    private const val INTERVAL_MS = 4000L
    private const val REQUEST = 36

    fun arm(context: Context) {
        val app = context.applicationContext
        val alarm = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pending = pending(app)
        val at = SystemClock.elapsedRealtime() + INTERVAL_MS
        try {
            val exact = Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()
            if (exact) {
                alarm.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
            } else {
                alarm.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
            }
        } catch (error: Throwable) {
            Log.i(TAG, "yield alarm exact failed: ${error.message}")
            try {
                alarm.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
            } catch (again: Throwable) {
                Log.i(TAG, "yield alarm skipped: ${again.message}")
            }
        }
    }

    fun disarm(context: Context) {
        val app = context.applicationContext
        val alarm = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarm.cancel(pending(app))
    }

    private fun pending(app: Context): PendingIntent {
        val intent = Intent(app, YieldAlarmReceiver::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(app, REQUEST, intent, flags)
    }
}

class YieldAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val stillWaiting = PlaybackFocus.nudgeFromAlarm()
        if (stillWaiting) {
            YieldAlarm.arm(context)
        } else {
            YieldAlarm.disarm(context)
        }
    }
}
