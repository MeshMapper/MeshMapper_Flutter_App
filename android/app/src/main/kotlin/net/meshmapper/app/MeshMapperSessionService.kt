package net.meshmapper.app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// The foreground service that keeps the radio session's BLE and GPS running
/// while the app is in the background, with a notification the whole time.
/// Dart drives it over [SessionServiceChannel].
///
/// It is only ever started by the app, never at boot, and nothing restarts
/// it: onStartCommand answers START_NOT_STICKY and there is no onTaskRemoved,
/// because the manifest's stopWithTask stops it when the app is swiped away.
/// A start that fails here (startForeground refused) is kept in [lastError]
/// for Dart's next status read, since the channel call answered before this
/// service ran.
class MeshMapperSessionService : Service() {
    companion object {
        const val NOTIFICATION_ID = 888
        private const val CHANNEL_ID = "meshmapper_wardriving"
        private const val CHANNEL_NAME = "MeshMapper Wardriving"
        private const val CHANNEL_DESCRIPTION =
            "Shows while MeshMapper is connected to your radio"
        private const val WAKE_LOCK_TAG = "MeshMapper:session"
        private const val LOG_TAG = "MeshMapperSession"
        private const val FOREGROUND_TYPES =
            ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE

        /// The instance that reached the foreground, until it is stopped. A
        /// stop clears it at once, so a start right after one starts a new
        /// instance instead of updating the dying one.
        @Volatile var current: MeshMapperSessionService? = null

        /// A start sent to Android whose onStartCommand has not run yet.
        @Volatile var pendingStart: Boolean = false

        /// A stop that arrived during [pendingStart]. The service stops
        /// itself as soon as it is foreground.
        @Volatile var stopRequested: Boolean = false

        /// Why the last start failed inside the service. Cleared when read.
        @Volatile var lastError: String? = null

        /// The latest content from any channel call. A start still pending
        /// builds its notification from these, so an update sent meanwhile
        /// is not lost.
        @Volatile var title: String = "MeshMapper"
        @Volatile var body: String = ""
        @Volatile var keepAwake: Boolean = false
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground comes first, before anything can stop the service:
        // stopping a service started with startForegroundService before it
        // has called startForeground crashes the app.
        try {
            val notification = buildNotification(title, body)
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, FOREGROUND_TYPES)
        } catch (e: Exception) {
            // Android stopped waiting for startForeground when it was
            // called, so stopping now is safe even though it threw.
            lastError = "${e.javaClass.simpleName}: ${e.message}"
            pendingStart = false
            stopRequested = false
            Log.w(LOG_TAG, "startForeground failed: $lastError")
            stopSelfResult(startId)
            return START_NOT_STICKY
        }

        pendingStart = false
        if (stopRequested) {
            // Never published as current: a start arriving before onDestroy
            // must start a new instance, not update this one.
            stopRequested = false
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        current = this
        applyKeepAwake(keepAwake)
        return START_NOT_STICKY
    }

    /// New content for the running service. Only reposts the notification:
    /// startForeground is never called again.
    fun update(title: String, body: String, keepAwake: Boolean) {
        // On 33+ with notifications denied Android drops the post anyway.
        val mayPost = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (mayPost) {
            NotificationManagerCompat.from(this)
                .notify(NOTIFICATION_ID, buildNotification(title, body))
        }
        applyKeepAwake(keepAwake)
    }

    override fun onDestroy() {
        if (current === this) current = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        releaseWakeLock()
        super.onDestroy()
    }

    private fun buildNotification(title: String, body: String): Notification {
        val manager = NotificationManagerCompat.from(this)
        if (manager.getNotificationChannelCompat(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
                    .setName(CHANNEL_NAME)
                    .setDescription(CHANNEL_DESCRIPTION)
                    .setShowBadge(false)
                    .build(),
            )
        }
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_meshmapper)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    /// Holds the wake lock while [keepAwake] is true and releases it when
    /// false. Not reference counted, so repeated calls hold it once.
    @SuppressLint("WakelockTimeout")
    private fun applyKeepAwake(keepAwake: Boolean) {
        if (!keepAwake) {
            releaseWakeLock()
            return
        }
        val lock = wakeLock
            ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
                .also {
                    it.setReferenceCounted(false)
                    wakeLock = it
                }
        if (!lock.isHeld) lock.acquire()
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
    }
}

/// The `meshmapper/session_service` channel: start, update, stop and status
/// for [MeshMapperSessionService]. Runs on the main thread, like the
/// service's own callbacks. Holds the application context, never the
/// activity.
class SessionServiceChannel(private val context: Context) {
    private companion object {
        const val METHOD_CHANNEL = "meshmapper/session_service"
    }

    fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                // Kept first, whatever the method, for a start still pending.
                call.argument<String>("title")?.let { MeshMapperSessionService.title = it }
                call.argument<String>("body")?.let { MeshMapperSessionService.body = it }
                call.argument<Boolean>("keepAwake")?.let { MeshMapperSessionService.keepAwake = it }
                when (call.method) {
                    "start" -> result.success(start())
                    "update" -> {
                        update()
                        result.success(null)
                    }
                    "stop" -> {
                        stop()
                        result.success(null)
                    }
                    "status" -> result.success(status())
                    else -> result.notImplemented()
                }
            }
    }

    /// A running or pending service only takes the new content.
    private fun start(): Map<String, Any?> {
        if (MeshMapperSessionService.current != null) {
            update()
            return started(null)
        }
        if (MeshMapperSessionService.pendingStart) {
            MeshMapperSessionService.stopRequested = false
            return started(null)
        }
        MeshMapperSessionService.pendingStart = true
        MeshMapperSessionService.stopRequested = false
        return try {
            ContextCompat.startForegroundService(context, serviceIntent())
            started(null)
        } catch (e: IllegalStateException) {
            // Covers ForegroundServiceStartNotAllowedException (12+, from the
            // background).
            MeshMapperSessionService.pendingStart = false
            started("${e.javaClass.simpleName}: ${e.message}")
        } catch (e: SecurityException) {
            MeshMapperSessionService.pendingStart = false
            started("${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun update() {
        MeshMapperSessionService.current?.update(
            MeshMapperSessionService.title,
            MeshMapperSessionService.body,
            MeshMapperSessionService.keepAwake,
        )
    }

    /// Also called from MainActivity.onDestroy.
    fun stop() {
        if (MeshMapperSessionService.pendingStart) {
            // Stopping before startForeground crashes the app (AOSP
            // bringDownServiceLocked posts SERVICE_FOREGROUND_CRASH_MSG), so
            // the service stops itself once it is foreground instead.
            MeshMapperSessionService.stopRequested = true
            return
        }
        MeshMapperSessionService.current = null
        context.stopService(serviceIntent())
    }

    /// running covers a start still pending. Reading clears lastError.
    private fun status(): Map<String, Any?> {
        val error = MeshMapperSessionService.lastError
        MeshMapperSessionService.lastError = null
        val running = MeshMapperSessionService.current != null ||
            MeshMapperSessionService.pendingStart
        return mapOf("running" to running, "lastError" to error)
    }

    private fun started(error: String?): Map<String, Any?> =
        mapOf("started" to (error == null), "error" to error)

    private fun serviceIntent() = Intent(context, MeshMapperSessionService::class.java)
}
