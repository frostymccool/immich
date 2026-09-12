package app.alextran.immich.copyparty

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import app.alextran.immich.MainActivity
import app.alextran.immich.R

/**
 * A minimal foreground service whose job is to keep this app's process at
 * foreground OOM-kill priority AND its WiFi radio at full performance for the
 * duration of a copyparty memory-card import.
 *
 * The actual upload logic keeps running exactly as before, live in the main
 * Flutter engine/isolate (ImportSessionNotifier) — this service does not touch
 * that. It exists because, on Samsung devices, a plain WakelockPlus wakelock
 * (a CPU-only PARTIAL_WAKE_LOCK) plus the standard per-app "Unrestricted"
 * battery setting were confirmed NOT enough to stop the OS from silently
 * killing the process during a long (many-hour) import — a foreground service
 * with a visible notification raises the process's OOM priority in a way
 * neither of those does.
 *
 * The WifiLock addresses a SEPARATE, previously-unaddressed failure mode found
 * in diagnostic logs: two crashes both showed every in-flight chunk upload
 * abort simultaneously ("connection abort"), then every retry fail with
 * "No route to host" for a sustained period with no recovery, then the log
 * just stops. A CPU wakelock does not keep the WiFi radio out of its own
 * power-save state during screen-off — that requires a distinct
 * WifiManager.WifiLock. This is a hypothesis prompted by that log pattern, not
 * a confirmed fix; if it doesn't hold, the next diagnostic log will show the
 * same signature again despite this being active.
 *
 * Controlled from Dart via CopypartyForegroundServicePlugin (start/stop),
 * called in lockstep with the upload session lifecycle — enabled alongside
 * the wakelock in startUpload(), disabled in its teardown.
 */
class CopypartyForegroundService : Service() {
    companion object {
        private const val TAG = "CopypartyFgService"
        private const val NOTIFICATION_CHANNEL_ID = "immich::copyparty_foreground::notif"
        // Arbitrary, distinct from BackgroundWorker's NOTIFICATION_ID (100).
        private const val NOTIFICATION_ID = 4171
    }

    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Every call in here (NotificationManager, startForeground with a
        // FOREGROUND_SERVICE_TYPE) can throw for OEM/OS-version-specific reasons
        // (e.g. Android 14's stricter foreground-service-type enforcement, or a
        // vendor-specific restriction). This whole method runs on the main
        // thread as part of Service startup — an uncaught exception here would
        // crash the ENTIRE app process, not just fail the foreground promotion.
        // That would be strictly worse than the crash this service exists to
        // prevent, so every failure here must be caught and logged, never let
        // to propagate. (see CLAUDE.md: instrument, don't theorise — this log
        // line is what will prove/disprove whether this service is the culprit
        // behind a future crash.)
        try {
            val notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                getString(R.string.copyparty_foreground_notification_channel_name),
                NotificationManager.IMPORTANCE_LOW
            )
            notificationManager.createNotificationChannel(channel)

            // NOTE: Intent.setFlags(Int) returns Intent (not void), so Kotlin does
            // NOT synthesize a mutable `var flags` from it — only a read-only `val`
            // getter. Must call setFlags() explicitly rather than `flags = ...`.
            val openAppIntent = Intent(this, MainActivity::class.java).apply {
                setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
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
            Log.i(TAG, "startForeground succeeded")
        } catch (e: Exception) {
            // Foreground promotion failed — the import continues without it
            // (wakelock only), exactly as if this service didn't exist. Only
            // visible in logcat for now; nothing here can write to the Dart-side
            // diagnostic log (this runs outside the Flutter engine).
            Log.e(TAG, "startForeground failed — import continues without foreground priority", e)
        }

        // Separate from startForeground above: keep the WiFi radio at full
        // performance for the import's duration, independent of whether the FG
        // promotion itself succeeded. A held WifiLock survives even if this
        // service later gets demoted, since it's tied to this acquire/release,
        // not to foreground status.
        try {
            if (wifiLock == null) {
                val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                wifiLock = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "immich:copyparty_import")
                    .apply {
                        setReferenceCounted(false)
                        acquire()
                    }
                Log.i(TAG, "WifiLock acquired")
            }
        } catch (e: Exception) {
            Log.e(TAG, "WifiLock acquire failed — import continues without it", e)
        }

        // We manage the lifecycle explicitly via start()/stop() from Dart; don't
        // let Android restart this on its own if the process is later killed.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.e(TAG, "WifiLock release failed", e)
        }
        wifiLock = null
        super.onDestroy()
    }
}
