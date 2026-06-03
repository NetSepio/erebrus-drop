package com.erebrus.drop

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

class DropRoomForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val roomName = intent?.getStringExtra("roomName") ?: "Drop Room"
        val baseUrl = intent?.getStringExtra("baseUrl") ?: "Local network"
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Erebrus Drop is hosting")
            .setContentText("$roomName · $baseUrl")
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
        startForeground(notificationId, notification)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            channelId,
            "Drop Room hosting",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps local Drop Room transfers responsive while the app is in the background."
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val channelId = "erebrus_drop_room_hosting"
        private const val notificationId = 8787
    }
}
