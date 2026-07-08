package me.free4me.iptv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.MediaStore
import android.util.Log
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/**
 * fix668: Scheduled Recording (SR) capture engine.
 *
 * A foreground Service that copies a channel's HTTP stream to a MediaStore file
 * for [durationMs], holding its own wake + wifi locks so a multi-hour capture
 * survives Doze (the alarm's own wakelock only covers the short callback
 * window, which is why capture lives here and not in the alarm isolate).
 *
 * Status is written back DIRECTLY to the app's SQLite DB
 * (context.filesDir/db.sqlite — the same file Dart's DbFactory opens), updating
 * the `recordings` row's status/output_path. Status strings match
 * RecordingStatus.name on the Dart side ('recording','done','failed').
 *
 * This is distinct from the app's live "DVR" (rewind-within-live-stream)
 * feature — SR writes a file for later playback.
 */
class RecordingCaptureService : Service() {

    companion object {
        private const val TAG = "SRCapture"
        private const val CHANNEL_ID = "free4me_recording"
        private const val NOTI_ID_BASE = 47000

        const val EXTRA_ID = "recording_id"
        const val EXTRA_URL = "url"
        const val EXTRA_DURATION_MS = "duration_ms"
        const val EXTRA_NAME = "channel_name"
        const val ACTION_START = "me.free4me.iptv.SR_START"
        const val ACTION_STOP = "me.free4me.iptv.SR_STOP"

        // recordingId -> cancel flag, so a stop intent (or manual stop) ends the
        // copy loop cleanly.
        private val cancelFlags = ConcurrentHashMap<Int, Boolean>()

        fun start(context: Context, id: Int, url: String, durationMs: Long, name: String) {
            val i = Intent(context, RecordingCaptureService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ID, id)
                putExtra(EXTRA_URL, url)
                putExtra(EXTRA_DURATION_MS, durationMs)
                putExtra(EXTRA_NAME, name)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context, id: Int) {
            cancelFlags[id] = true
            val i = Intent(context, RecordingCaptureService::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_ID, id)
            }
            context.startService(i)
        }
    }

    private val active = ConcurrentHashMap<Int, Thread>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return START_NOT_STICKY
        val id = intent.getIntExtra(EXTRA_ID, -1)
        when (intent.action) {
            ACTION_STOP -> {
                if (id != -1) cancelFlags[id] = true
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val url = intent.getStringExtra(EXTRA_URL) ?: return stopAndReturn(id)
                val durationMs = intent.getLongExtra(EXTRA_DURATION_MS, 0L)
                val name = intent.getStringExtra(EXTRA_NAME) ?: "Recording"
                if (id == -1 || durationMs <= 0L) return stopAndReturn(id)

                startForeground(NOTI_ID_BASE + id, buildNotification(name))
                cancelFlags[id] = false
                val t = thread(start = true, name = "sr-capture-$id") {
                    runCapture(id, url, durationMs, name)
                }
                active[id] = t
                return START_REDELIVER_INTENT
            }
        }
        return START_NOT_STICKY
    }

    private fun stopAndReturn(id: Int): Int {
        if (id != -1) updateStatus(id, "failed", null, "Missing capture parameters")
        stopSelfIfIdle()
        return START_NOT_STICKY
    }

    private fun runCapture(id: Int, url: String, durationMs: Long, name: String) {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG:wl:$id")
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val wifiLock = wifiManager.createWifiLock(
            WifiManager.WIFI_MODE_FULL_HIGH_PERF, "$TAG:wifi:$id"
        )

        var mediaUri: Uri? = null
        var conn: HttpURLConnection? = null
        try {
            wakeLock.acquire(durationMs + 60_000L)
            wifiLock.acquire()
            updateStatus(id, "recording", null, null)

            mediaUri = createMediaStoreEntry(name)
            if (mediaUri == null) {
                updateStatus(id, "failed", null, "Could not create output file")
                return
            }

            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 30_000
                instanceFollowRedirects = true
            }
            conn.connect()
            if (conn.responseCode !in 200..299) {
                updateStatus(id, "failed", null, "HTTP ${conn.responseCode}")
                return
            }

            val deadline = System.currentTimeMillis() + durationMs
            var total = 0L
            contentResolver.openOutputStream(mediaUri)?.use { out ->
                conn.inputStream.use { input ->
                    val buf = ByteArray(64 * 1024)
                    while (System.currentTimeMillis() < deadline &&
                        cancelFlags[id] != true
                    ) {
                        val n = input.read(buf)
                        if (n < 0) break // stream ended
                        out.write(buf, 0, n)
                        total += n
                    }
                    out.flush()
                }
            }

            finalizeMediaStore(mediaUri)
            if (total < 64 * 1024) {
                // Almost nothing captured — treat as failure but keep the file.
                updateStatus(id, "failed", mediaUri.toString(),
                    "Captured too little data (${total} bytes)")
            } else {
                updateStatus(id, "done", mediaUri.toString(), null)
            }
        } catch (e: Exception) {
            Log.w(TAG, "capture $id failed: ${e.message}")
            mediaUri?.let { runCatching { finalizeMediaStore(it) } }
            updateStatus(id, "failed", mediaUri?.toString(), e.message ?: "error")
        } finally {
            runCatching { conn?.disconnect() }
            runCatching { if (wakeLock.isHeld) wakeLock.release() }
            runCatching { if (wifiLock.isHeld) wifiLock.release() }
            active.remove(id)
            cancelFlags.remove(id)
            stopSelfIfIdle()
        }
    }

    // ── MediaStore (Movies/Free4Me) ────────────────────────────────────────

    private fun createMediaStoreEntry(name: String): Uri? {
        val safe = name.replace(Regex("[^A-Za-z0-9 ._-]"), "_").take(80)
        val fileName = "${safe}_${System.currentTimeMillis()}.ts"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "video/mp2t")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, "Movies/Free4Me")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        return contentResolver.insert(collection, values)
    }

    private fun finalizeMediaStore(uri: Uri) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            contentResolver.update(uri, values, null, null)
        }
    }

    // ── DB write-back (same file DbFactory opens) ──────────────────────────

    private fun updateStatus(id: Int, status: String, outputPath: String?, error: String?) {
        val dbFile = File(applicationContext.filesDir, "db.sqlite")
        if (!dbFile.exists()) {
            Log.w(TAG, "db.sqlite missing; cannot write status for $id")
            return
        }
        var db: SQLiteDatabase? = null
        try {
            db = SQLiteDatabase.openDatabase(
                dbFile.absolutePath, null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
            )
            val values = ContentValues().apply {
                put("status", status)
                if (outputPath != null) put("output_path", outputPath)
                if (error != null) put("error", error)
            }
            db.update("recordings", values, "id = ?", arrayOf(id.toString()))
        } catch (e: Exception) {
            Log.w(TAG, "updateStatus($id,$status) failed: ${e.message}")
        } finally {
            runCatching { db?.close() }
        }
    }

    // ── notification / lifecycle ───────────────────────────────────────────

    private fun buildNotification(name: String): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "Recording",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply { description = "Scheduled recording in progress" }
                )
            }
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Recording")
            .setContentText(name)
            .setSmallIcon(android.R.drawable.ic_menu_save)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun stopSelfIfIdle() {
        if (active.isEmpty()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
        }
    }

    override fun onDestroy() {
        cancelFlags.keys.forEach { cancelFlags[it] = true }
        super.onDestroy()
    }
}
