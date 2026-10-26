package com.likepod.likepod

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Keeps a media-playback foreground service up after the activity leaves
 * the screen. The stream itself is the system mixer.
 *
 * [playing] is real playback. [yieldHeld] is a focus yield: the user did
 * not pause, another app took audio, and we still intend to resume. The
 * service and its wake lock stay up for that wait. Stopping them on the
 * yield is what let a long video freeze the process until the activity
 * was opened. A user pause clears the yield and then the service.
 */
object PlaybackAnchor {
    private const val TAG = "LikePod"

    @Volatile
    private var playing = false

    @Volatile
    private var yieldHeld = false

    @Volatile
    private var serviceStarted = false

    fun isPlaying(): Boolean = playing

    fun setYieldHeld(context: Context, held: Boolean) {
        if (held) {
            YieldKeepAlive.start()
        } else {
            YieldAlarm.disarm(context)
            YieldKeepAlive.stop()
        }
        if (yieldHeld == held && serviceStarted == wanted()) return
        yieldHeld = held
        refresh(context.applicationContext)
    }

    fun setPlaying(context: Context, active: Boolean) {
        if (active) {
            yieldHeld = false
            YieldAlarm.disarm(context)
            YieldKeepAlive.stop()
        }
        if (playing == active && serviceStarted == wanted()) return
        playing = active
        refresh(context.applicationContext)
    }

    /** Re-acquires the service if playback or a yield should still be held. */
    fun reassert(context: Context) {
        if (!wanted()) return
        refresh(context.applicationContext)
    }

    fun onHostBackground(context: Context) {
        reassert(context)
    }

    fun onHostForeground(context: Context) {
        reassert(context)
    }

    private fun wanted(): Boolean = playing || yieldHeld

    private fun refresh(app: Context) {
        try {
            val intent = Intent(app, PlaybackService::class.java)
            if (wanted()) {
                serviceStarted = true
                intent.putExtra(PlaybackService.EXTRA_WAITING, yieldHeld && !playing)
                ContextCompat.startForegroundService(app, intent)
            } else if (serviceStarted) {
                serviceStarted = false
                intent.putExtra(PlaybackService.EXTRA_STOP, true)
                app.startService(intent)
            }
        } catch (error: Throwable) {
            Log.i(TAG, "Playback service skipped: ${error.message}")
        }
    }
}
