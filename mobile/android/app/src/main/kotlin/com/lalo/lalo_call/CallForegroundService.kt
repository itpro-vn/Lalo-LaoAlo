package com.lalo.lalo_call

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service for active voice/video calls.
 * Uses FOREGROUND_SERVICE_TYPE_PHONE_CALL (Android 14+).
 * Keeps the process alive during an active call even when
 * the app is in the background.
 */
class CallForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "active_call_channel"
        private const val CHANNEL_NAME = "Active Call"
        private const val NOTIFICATION_ID = 2001

        const val ACTION_START = "com.lalo.call.START_FOREGROUND"
        const val ACTION_STOP = "com.lalo.call.STOP_FOREGROUND"
        const val EXTRA_CALLER_NAME = "caller_name"
        const val EXTRA_HAS_VIDEO = "has_video"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val callerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "Active Call"
                val hasVideo = intent.getBooleanExtra(EXTRA_HAS_VIDEO, false)
                startForegroundWithNotification(callerName, hasVideo)
            }
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundWithNotification(callerName: String, hasVideo: Boolean) {
        val callType = if (hasVideo) "Video call" else "Voice call"
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setContentTitle(callType)
            .setContentText("In call with $callerName")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .build()

        val foregroundServiceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
        } else {
            0
        }

        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            foregroundServiceType,
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Active call indicator"
                setShowBadge(false)
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }
}
