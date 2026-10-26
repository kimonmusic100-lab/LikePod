package com.likepod.likepod

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Keeps the process in the foreground-service state after the activity
 * leaves the screen.
 *
 * A silent speaker track does not count as playback on the devices that
 * mute background audio, and it can move the audio policy off the DAC.
 * The service holds a media-playback (and, while direct USB is open, a
 * connected-device) foreground type instead.
 */
object PlaybackAnchor {
    private const val TAG = "LikePod"

    @Volatile
    private var playing = false

    @Volatile
    private var direct = false

    @Volatile
    private var serviceStarted = false

    /** `direct` or `mixer` after a background handoff. Empty until then. */
    @Volatile
    var backgroundPath: String = ""
        private set

    fun isPlaying(): Boolean = playing

    fun setPlaying(context: Context, active: Boolean) {
        playing = active
        if (!active) {
            backgroundPath = ""
        } else {
            serviceStarted = true
        }
        refresh(context.applicationContext)
    }

    fun setDirect(context: Context, active: Boolean) {
        direct = active
        refresh(context.applicationContext)
    }

    fun noteBackground(path: String) {
        backgroundPath = path
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
                intent.putExtra(PlaybackService.EXTRA_USB, direct)
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
