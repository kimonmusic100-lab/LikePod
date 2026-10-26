package com.likepod.likepod

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Keeps a media-playback foreground service up after the activity leaves
 * the screen. The stream itself is the system mixer.
 */
object PlaybackAnchor {
    private const val TAG = "LikePod"

    @Volatile
    private var playing = false

    @Volatile
    private var serviceStarted = false

    fun isPlaying(): Boolean = playing

    fun setPlaying(context: Context, active: Boolean) {
        if (playing == active && (!active || serviceStarted)) return
        playing = active
        if (active) {
            serviceStarted = true
        }
        refresh(context.applicationContext)
    }

    /** Re-acquires the service if playback is still supposed to be running. */
    fun reassert(context: Context) {
        if (!playing) return
        refresh(context.applicationContext)
    }

    fun onHostBackground(context: Context) {
        reassert(context)
    }

    fun onHostForeground(context: Context) {
        reassert(context)
    }

    private fun refresh(app: Context) {
        try {
            val intent = Intent(app, PlaybackService::class.java)
            if (playing) {
                serviceStarted = true
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
