package com.likepod.likepod

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log

/**
 * Wakes a yielded process whose main-thread poll has been frozen.
 *
 * Two clocks, both armed only while a yield is waiting:
 *
 * The in-process listener uses [AlarmManager.setExact]. That API does not
 * need the exact-alarm permission, and with the screen on it is not subject
 * to the allow-while-idle quota. It cannot restart a dead process.
 *
 * The broadcast uses [AlarmManager.setExactAndAllowWhileIdle] when exact
 * alarms are allowed ([android.Manifest.permission.USE_EXACT_ALARM] is a
 * normal permission, so it is granted at install). Delivering the broadcast
 * thaws a frozen process. `setAndAllowWhileIdle` is the fallback, and
 * HyperOS may hold that one until the activity is opened, which is why a
 * long Bilibili session never resumed on vc38. Re-arming the allow-while-idle
 * alarm every few seconds also loses: the platform defers it to about a
 * minute, or about fifteen minutes in idle, instead of creating a new slot.
 */
object YieldAlarm {
    private const val TAG = "LikePod"
    private const val LISTENER_MS = 3000L
    private const val BROADCAST_MS = 15000L
    private const val REQUEST = 36

    private val handler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private val listener = AlarmManager.OnAlarmListener {
        Log.i(TAG, "yield alarm listener")
        if (PlaybackFocus.nudgeFromAlarm()) {
            scheduleListener()
        }
    }

    fun arm(context: Context) {
        val app = context.applicationContext
        appContext = app
        scheduleListener()
        scheduleBroadcast(app)
    }

    fun disarm(context: Context) {
        val app = context.applicationContext
        val alarm = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        try {
            alarm.cancel(listener)
        } catch (_: Throwable) {
        }
        alarm.cancel(pending(app))
    }

    private fun scheduleListener() {
        val context = appContext ?: return
        val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val at = SystemClock.elapsedRealtime() + LISTENER_MS
        try {
            alarm.setExact(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                at,
                "likepod-yield",
                listener,
                handler,
            )
        } catch (error: Throwable) {
            Log.i(TAG, "yield listener alarm skipped: ${error.message}")
        }
    }

    fun scheduleBroadcast(context: Context) {
        val app = context.applicationContext
        val alarm = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pending = pending(app)
        val at = SystemClock.elapsedRealtime() + BROADCAST_MS
        val exact = Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()
        try {
            if (exact) {
                alarm.setExactAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    at,
                    pending,
                )
            } else {
                alarm.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
            }
            Log.i(TAG, "yield broadcast alarm exact=$exact")
        } catch (error: Throwable) {
            Log.i(TAG, "yield broadcast alarm exact failed: ${error.message}")
            try {
                alarm.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pending)
            } catch (again: Throwable) {
                Log.i(TAG, "yield broadcast alarm skipped: ${again.message}")
            }
        }
    }

    private fun pending(app: Context): PendingIntent {
        val intent = Intent(app, YieldAlarmReceiver::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(app, REQUEST, intent, flags)
    }
}

class YieldAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val deferred = goAsync()
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LikePod:yield-alarm")
        lock.setReferenceCounted(false)
        lock.acquire(10_000L)
        try {
            Log.i(TAG, "yield alarm broadcast")
            val stillWaiting = PlaybackFocus.nudgeFromAlarm()
            if (stillWaiting) {
                YieldAlarm.scheduleBroadcast(context)
            } else {
                YieldAlarm.disarm(context)
            }
        } finally {
            try {
                if (lock.isHeld) lock.release()
            } catch (_: Throwable) {
            }
            deferred.finish()
        }
    }

    companion object {
        private const val TAG = "LikePod"
    }
}
