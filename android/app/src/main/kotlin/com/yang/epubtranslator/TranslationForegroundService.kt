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
    private var stopLabel: String = "Stop"
    private var timeoutText: String =
        "Background time limit reached — reopen the app to continue."
    private var hasStarted: Boolean = false

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
        hasStarted = false
        super.onDestroy()
    }

    /**
     * Android 15+ (API 35): the system invokes this when a dataSync
     * foreground service exhausts its background runtime budget (about 6
     * hours per 24h while the app stays in the background). If the service
     * does not stop promptly, the system kills the whole process with a
     * RemoteServiceException — losing the in-memory translation. This
     * callback is never invoked below API 35, so overriding it is safe on
     * every release (compileSdk 36). Reopening the app resets the budget,
     * so the final notification tells the user exactly that.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        lastText = timeoutText
        // Detach the notification from the foreground slot so it survives
        // stopSelf() as a normal dismissible notification.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(Service.STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
        if (NotificationManagerCompat.from(this).areNotificationsEnabled() &&
            isProgressChannelEnabled()
        ) {
            NotificationManagerCompat.from(this)
                .notify(NOTIFICATION_ID, buildNotification(ongoing = false))
        } else {
            // The user disabled notifications (or just this channel): the
            // final notification would be posted into the void and the
            // timeout would go completely unnoticed. Persist it instead so
            // the next app start can surface it in-app; Dart consumes (and
            // clears) the flag via MainActivity's
            // "consumePendingForegroundServiceTimeout".
            getSharedPreferences(TIMEOUT_PENDING_PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_TIMEOUT_PENDING, true)
                .apply()
        }
        stopSelf()
        // The process just lost its foreground protection and the system
        // may kill it at any moment. Tell Dart so the run winds down
        // through the normal cancel path instead of blindly burning API
        // tokens in the background.
        MainActivity.notifyForegroundServiceTimeout()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }?.let {
            lastTitle = it
        }
        intent?.getStringExtra(EXTRA_TEXT)?.let { lastText = it }
        intent?.getStringExtra(EXTRA_STOP_LABEL)?.takeIf { it.isNotBlank() }
            ?.let { stopLabel = it }
        intent?.getStringExtra(EXTRA_TIMEOUT_TEXT)?.takeIf { it.isNotBlank() }
            ?.let { timeoutText = it }
        // Updates stashed while the service wasn't running are applied only
        // on the first start, and only when they belong to this run: a
        // previous run whose service never started (start failed, Dart
        // swallowed the error and kept translating) must not pollute this
        // run's first notification frame with the old book title/progress.
        // The stash is always cleared once consumed so the next run starts
        // clean.
        if (!hasStarted) {
            hasStarted = true
            val runId = intent?.getStringExtra(EXTRA_RUN_ID).orEmpty()
            if (pendingRunId.isNotEmpty() && pendingRunId == runId) {
                lastProgress = pendingProgress
                if (pendingText.isNotBlank()) {
                    lastText = pendingText
                }
            }
            pendingProgress = 0
            pendingText = ""
            pendingRunId = ""
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

    private fun buildNotification(ongoing: Boolean = true): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(lastTitle)
            .setContentText(lastText.ifBlank { null })
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(ongoing)
            .setOnlyAlertOnce(true)
            .setProgress(100, lastProgress.coerceIn(0, 100), false)
            .setContentIntent(launchPendingIntent())
        if (ongoing) {
            // Tapping Stop brings the app forward; MainActivity forwards it
            // to Dart, which cancels the translation run through the same
            // path as the in-app cancel button.
            stopPendingIntent()?.let { pendingIntent ->
                builder.addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    stopLabel,
                    pendingIntent,
                )
            }
        }
        return builder.build()
    }

    private fun stopPendingIntent(): PendingIntent? {
        val stopIntent = Intent(this, MainActivity::class.java).apply {
            action = ACTION_STOP_TRANSLATION
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(this, 1, stopIntent, flags)
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
        // The channel name is frozen by the system after first creation, so
        // localize it up front; a later in-app language switch won't rename
        // it, which matches platform behavior.
        val channelName =
            if (java.util.Locale.getDefault().language.startsWith("zh")) {
                "翻译进度"
            } else {
                "Translation progress"
            }
        val channel = NotificationChannel(
            CHANNEL_ID,
            channelName,
            NotificationManager.IMPORTANCE_LOW
        )
        manager.createNotificationChannel(channel)
    }

    /**
     * Whether the `translation_progress` channel can actually deliver: the
     * app-level `areNotificationsEnabled()` check is not enough, because the
     * user may disable this channel alone in system settings, in which case
     * posting is silently dropped. A deleted channel also counts as
     * undeliverable — the timeout must then take the persisted-flag path so
     * the next app start can surface it in-app.
     */
    private fun isProgressChannelEnabled(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        val manager = getSystemService(NotificationManager::class.java)
            ?: return false
        val channel = manager.getNotificationChannel(CHANNEL_ID)
        return channel != null &&
            channel.importance != NotificationManager.IMPORTANCE_NONE
    }

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_STOP_LABEL = "stopLabel"
        const val EXTRA_TIMEOUT_TEXT = "timeoutText"
        /**
         * Opaque Dart-side run token (see AndroidServiceBridge). Tags
         * stashed notification updates so a start only consumes updates
         * from its own run.
         */
        const val EXTRA_RUN_ID = "runId"

        /**
         * Intent action delivered to MainActivity when the user taps the
         * notification's Stop button. MainActivity forwards it to Dart,
         * which cancels the translation run; the service itself is stopped
         * by Dart's normal cleanup path.
         */
        const val ACTION_STOP_TRANSLATION =
            "com.yang.epubtranslator.action.STOP_TRANSLATION"
        private const val CHANNEL_ID = "translation_progress"
        private const val NOTIFICATION_ID = 7001

        /**
         * Prefs file for the persisted timeout notice. Must stay identical
         * to MainActivity.PREFS_NAME ("epub_translator_prefs") — the service
         * writes it here and MainActivity reads/clears it there.
         */
        const val TIMEOUT_PENDING_PREFS = "epub_translator_prefs"

        /**
         * Set in onTimeout() when notifications are disabled and the final
         * notification would be silently dropped. Consumed (and cleared) by
         * Dart through MainActivity's "consumePendingForegroundServiceTimeout"
         * so the next app start can show the timeout in-app instead.
         */
        const val KEY_TIMEOUT_PENDING = "fgs_timeout_pending"

        @Volatile
        private var instance: TranslationForegroundService? = null

        @Volatile
        private var pendingProgress: Int = 0

        @Volatile
        private var pendingText: String = ""

        /**
         * Identifies which translation run a stashed [pendingProgress] /
         * [pendingText] pair belongs to. The stash is only consumed by a
         * start whose [EXTRA_RUN_ID] matches, so a failed start can never
         * leak one run's title and progress into the next run's first
         * notification frame.
         */
        @Volatile
        private var pendingRunId: String = ""

        /**
         * Stops the service if it is currently running in this process.
         * Zombie sweep: the translation runs in the Dart isolate, so when
         * the activity is being (re)created, any previous Dart incarnation
         * is dead and a still-running service is by definition protecting
         * nothing — without this its frozen, non-dismissible notification
         * would lie about progress forever (swipe-away-from-recents leaves
         * the process alive with the engine destroyed). Starting a new
         * translation later re-starts the service cleanly.
         */
        fun stopIfRunning(context: Context) {
            if (instance != null) {
                context.stopService(
                    Intent(context, TranslationForegroundService::class.java)
                )
            }
        }

        /**
         * Updates the foreground notification. Safe to call when the
         * service isn't running: the values are stashed (tagged with
         * [runId]) and applied on the next start of the same run instead
         * of being dropped.
         */
        fun updateNotification(progress: Int, text: String, runId: String) {
            val service = instance
            if (service != null) {
                service.postUpdate(progress, text)
            } else {
                pendingProgress = progress.coerceIn(0, 100)
                pendingRunId = runId
                if (text.isNotBlank()) {
                    pendingText = text
                }
            }
        }
    }
}
