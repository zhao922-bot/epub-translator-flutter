package com.yang.epubtranslator

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Foreground service that keeps the app process alive — and exempt from
 * Doze — while a long translation runs with the app in the background.
 * It does no work itself: the translation runs in Dart, the service only
 * holds the foreground-service slot and shows progress in its ongoing
 * notification.
 */
class TranslationForegroundService : Service() {

    private var lastTitle: String = "EPUB Translator"
    private var lastText: String = ""
    private var lastProgress: Int = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }?.let {
            lastTitle = it
        }
        intent?.getStringExtra(EXTRA_TEXT)?.let { lastText = it }
        // An update that arrived while the service wasn't running yet.
        lastProgress = pendingProgress
        if (pendingText.isNotBlank()) {
            lastText = pendingText
            pendingText = ""
        }
        startAsForeground()
        // The translation itself runs in Dart in this process: if the
        // process dies there is nothing for a restarted service to resume.
        return START_NOT_STICKY
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        // FOREGROUND_SERVICE_TYPE_DATA_SYNC only exists on API 29+; older
        // releases use the no-type overload.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun postUpdate(progress: Int, text: String) {
        lastProgress = progress.coerceIn(0, 100)
        if (text.isNotBlank()) {
            lastText = text
        }
        NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(lastTitle)
            .setContentText(lastText.ifBlank { null })
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, lastProgress.coerceIn(0, 100), false)
            .setContentIntent(launchPendingIntent())
            .build()
    }

    private fun launchPendingIntent(): PendingIntent? {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: return null
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(this, 0, launchIntent, flags)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Translation progress",
            NotificationManager.IMPORTANCE_LOW
        )
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        private const val CHANNEL_ID = "translation_progress"
        private const val NOTIFICATION_ID = 7001

        @Volatile
        private var instance: TranslationForegroundService? = null

        @Volatile
        private var pendingProgress: Int = 0

        @Volatile
        private var pendingText: String = ""

        /**
         * Updates the foreground notification. Safe to call when the
         * service isn't running: the values are stashed and applied on
         * the next start instead of being dropped.
         */
        fun updateNotification(progress: Int, text: String) {
            val service = instance
            if (service != null) {
                service.postUpdate(progress, text)
            } else {
                pendingProgress = progress.coerceIn(0, 100)
                if (text.isNotBlank()) {
                    pendingText = text
                }
            }
        }
    }
}
