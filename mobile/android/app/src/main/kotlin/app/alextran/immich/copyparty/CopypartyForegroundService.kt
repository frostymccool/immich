package app.alextran.immich.copyparty

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import app.alextran.immich.MainActivity
import app.alextran.immich.R

/**
 * A minimal, do-nothing-else foreground service whose ONLY job is to keep this
 * app's process at foreground OOM-kill priority for the duration of a
 * copyparty memory-card import.
 *
 * The actual upload logic keeps running exactly as before, live in the main
 * Flutter engine/isolate (ImportSessionNotifier) — this service does not touch
 * that. It exists purely because, on Samsung devices, neither a plain
 * WakelockPlus wakelock nor the standard per-app "Unrestricted" battery
 * setting were enough to stop the OS from silently killing the process during
 * a long (many-hour) import: neither mechanism raises the process's priority
 * the way an active foreground service with a visible notification does.
 *
 * Controlled from Dart via CopypartyForegroundServicePlugin (start/stop),
 * called in lockstep with the upload session lifecycle — enabled alongside
 * the wakelock in startUpload(), disabled in its teardown.
 */
class CopypartyForegroundService : Service() {
    companion object {
        private const val NOTIFICATION_CHANNEL_ID = "immich::copyparty_foreground::notif"
        // Arbitrary, distinct from BackgroundWorker's NOTIFICATION_ID (100).
        private const val NOTIFICATION_ID = 4171
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            getString(R.string.copyparty_foreground_notification_channel_name),
            NotificationManager.IMPORTANCE_LOW
        )
        notificationManager.createNotificationChannel(channel)

        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.notification_icon)
            .setContentTitle(getString(R.string.copyparty_foreground_notification_title))
            .setContentText(getString(R.string.copyparty_foreground_notification_text))
            .setContentIntent(contentIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // We manage the lifecycle explicitly via start()/stop() from Dart; don't
        // let Android restart this on its own if the process is later killed.
        return START_NOT_STICKY
    }
}
