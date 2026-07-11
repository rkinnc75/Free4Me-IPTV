package me.free4me.iptv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent

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
        // fix697: a SEPARATE channel + id range for the one-shot "recording
        // complete/failed" notification (item 2). IMPORTANCE_DEFAULT so it makes
        // a heads-up/sound (the ongoing capture channel is LOW/silent). A distinct
        // id (48000+id) is essential: stopForeground(STOP_FOREGROUND_REMOVE) at
        // teardown only clears the ongoing FGS notification (47000+id), so this
        // one survives.
        private const val DONE_CHANNEL_ID = "free4me_recording_done"
        // Far from NOTI_ID_BASE (47000) so completion id (DONE_NOTI_ID_BASE+id)
        // can never alias a future FGS id (NOTI_ID_BASE+id') — they share one OS
        // notification-id namespace and recordings.id is unbounded AUTOINCREMENT.
        private const val DONE_NOTI_ID_BASE = 1_000_000

        const val EXTRA_ID = "recording_id"
        const val EXTRA_URL = "url"
        const val EXTRA_DURATION_MS = "duration_ms"
        const val EXTRA_NAME = "channel_name"
        const val EXTRA_REMUX = "remux"
        const val EXTRA_DEBUG = "debug_logging"
        // fix697: on a stop intent, whether to DELETE the partial capture file
        // instead of finalizing it (the "Delete + remove file" choice on a
        // still-recording row). The service owns the file it created, so it does
        // the delete itself after its output stream closes — no cross-isolate
        // open-fd race.
        const val EXTRA_DELETE_FILE = "delete_file"
        // fix697: the output content:// URI, passed on a delete-on-cancel stop so
        // ACTION_STOP can remove the file itself when NO live capture thread
        // exists to (the capture already finished/finalized, or the process was
        // killed and restarted). A live capture ignores it and deletes after its
        // own output stream closes.
        const val EXTRA_URI = "output_uri"
        const val ACTION_START = "me.free4me.iptv.SR_START"
        const val ACTION_STOP = "me.free4me.iptv.SR_STOP"

        // recordingId -> cancel flag, so a stop intent (or manual stop) ends the
        // copy loop cleanly.
        private val cancelFlags = ConcurrentHashMap<Int, Boolean>()
        // fix697: recordingId -> "delete the partial file when this capture is
        // cancelled" (set by a stop intent carrying EXTRA_DELETE_FILE).
        private val deleteOnCancel = ConcurrentHashMap<Int, Boolean>()

        fun start(
            context: Context, id: Int, url: String, durationMs: Long, name: String,
            remux: Boolean, debugLogging: Boolean,
        ) {
            val i = Intent(context, RecordingCaptureService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ID, id)
                putExtra(EXTRA_URL, url)
                putExtra(EXTRA_DURATION_MS, durationMs)
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_REMUX, remux)
                putExtra(EXTRA_DEBUG, debugLogging)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context, id: Int, deleteFile: Boolean = false, uri: String? = null) {
            cancelFlags[id] = true
            if (deleteFile) deleteOnCancel[id] = true
            val i = Intent(context, RecordingCaptureService::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_ID, id)
                putExtra(EXTRA_DELETE_FILE, deleteFile)
                if (uri != null) putExtra(EXTRA_URI, uri)
            }
            context.startService(i)
        }
    }

    private val active = ConcurrentHashMap<Int, Thread>()

    // fix680: comprehensive, plugin-free native trace of the whole capture
    // lifecycle, written to the SAME app_log.txt the in-app reporter transmits
    // (so it's readable on devices without adb, like the SM-S938U). GATED by the
    // user's debugLogging setting, read once per process from the Settings table
    // and cached. This mirrors the Dart-side [SRDBG] breadcrumbs; every stage
    // logs (not just the current failure point) so a future capture issue can be
    // traced end-to-end from one exported log. debugLogging off => no-op.
    // fix681: debug-logging flag is passed in from Dart per capture (extra), so
    // the service never opens the DB. Set at ACTION_START before any srDebug.
    @Volatile private var srDebugEnabled: Boolean = false

    private fun srDebug(msg: String) {
        Log.i(TAG, msg) // always to logcat (adb); harmless
        if (!srDebugEnabled) return
        try {
            val line = "[${java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss",
                java.util.Locale.US).format(java.util.Date())}] [SRDBG] $msg\n"
            File(applicationContext.filesDir, "app_log.txt")
                .appendText(line)
        } catch (_: Exception) {
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return START_NOT_STICKY
        val id = intent.getIntExtra(EXTRA_ID, -1)
        when (intent.action) {
            ACTION_STOP -> {
                if (id != -1) {
                    cancelFlags[id] = true
                    // fix697: a stop that also wants the partial file removed.
                    if (intent.getBooleanExtra(EXTRA_DELETE_FILE, false)) {
                        deleteOnCancel[id] = true
                        // If NO live capture thread will observe the flag — the
                        // capture already finished/finalized (stale-'recording'
                        // row not yet drained), or the process was killed and
                        // restarted — delete the file here from the URI Dart
                        // passed. A live capture instead deletes after its own
                        // output stream closes (the deleteOnCancel branch in
                        // runCapture), so we must NOT delete under it (open fd).
                        if (!active.containsKey(id)) {
                            val uri = intent.getStringExtra(EXTRA_URI)
                            if (uri != null) {
                                srDebug("id=$id ACTION_STOP delete (no live capture)")
                                runCatching {
                                    contentResolver.delete(Uri.parse(uri), null, null)
                                }
                            }
                            deleteOnCancel.remove(id)
                            cancelFlags.remove(id)
                        }
                    }
                }
                stopSelfIfIdle()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val url = intent.getStringExtra(EXTRA_URL) ?: return stopAndReturn(id)
                val durationMs = intent.getLongExtra(EXTRA_DURATION_MS, 0L)
                val name = intent.getStringExtra(EXTRA_NAME) ?: "Recording"
                val remux = intent.getBooleanExtra(EXTRA_REMUX, false)
                srDebugEnabled = intent.getBooleanExtra(EXTRA_DEBUG, false)
                if (id == -1 || durationMs <= 0L) return stopAndReturn(id)

                srDebug("onStartCommand ACTION_START id=$id durationMs=$durationMs remux=$remux")
                startForeground(NOTI_ID_BASE + id, buildNotification(name))
                cancelFlags[id] = false
                deleteOnCancel[id] = false // fix697: clean delete-intent per capture
                val t = thread(start = true, name = "sr-capture-$id") {
                    runCapture(id, url, durationMs, name, remux)
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

    private fun runCapture(id: Int, url: String, durationMs: Long, name: String, remux: Boolean) {
        srDebug("runCapture START id=$id durationMs=$durationMs urlLen=${url.length}")
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
            srDebug("id=$id locks acquired; creating output entry")

            mediaUri = createMediaStoreEntry(name)
            srDebug("id=$id createMediaStoreEntry -> ${mediaUri ?: "NULL"}")
            if (mediaUri == null) {
                updateStatus(id, "failed", null, "Could not create output file")
                postCompletion(id, name, false, "Could not create output file")
                return
            }
            // fix697: persist the output URI AT status=recording (was written null
            // and only filled in on 'done'). A still-recording row is now trackable,
            // so the Recordings UI offers "remove file" and can clean up the partial
            // instead of orphaning it (item 1 orphan fix).
            srDebug("id=$id writing status=recording (uri persisted)")
            updateStatus(id, "recording", mediaUri.toString(), null)

            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 30_000
                instanceFollowRedirects = true
            }
            srDebug("id=$id connecting…")
            conn.connect()
            srDebug("id=$id HTTP responseCode=${conn.responseCode}")
            if (conn.responseCode !in 200..299) {
                // fix697: this (offline channel / expired token at broadcast time)
                // is the most common UNATTENDED failure. Delete the empty pending
                // entry we just created (else it orphans), mark failed, and NOTIFY
                // — the other failure branches all do, and this one was silent.
                srDebug("id=$id HTTP ${conn.responseCode}; deleting pending entry + status=failed")
                runCatching { contentResolver.delete(mediaUri, null, null) }
                // fix697: "" clears output_path (Sql treats empty as CLEAR) so the
                // failed row does not keep pointing at the URI we just deleted —
                // else the UI would offer "remove file" for bytes that are gone.
                updateStatus(id, "failed", "", "HTTP ${conn.responseCode}")
                if (cancelFlags[id] != true) {
                    postCompletion(id, name, false, "HTTP ${conn.responseCode}")
                }
                return
            }

            val deadline = System.currentTimeMillis() + durationMs
            var total = 0L
            var lastHeartbeat = System.currentTimeMillis()
            srDebug("id=$id copy loop START (deadline in ${durationMs}ms)")
            contentResolver.openOutputStream(mediaUri)?.use { out ->
                conn.inputStream.use { input ->
                    val buf = ByteArray(64 * 1024)
                    while (System.currentTimeMillis() < deadline &&
                        cancelFlags[id] != true
                    ) {
                        val n = input.read(buf)
                        if (n < 0) {
                            srDebug("id=$id stream ended early at ${total} bytes")
                            break // stream ended
                        }
                        out.write(buf, 0, n)
                        total += n
                        val now = System.currentTimeMillis()
                        if (now - lastHeartbeat >= 5_000L) {
                            srDebug("id=$id copying… ${total} bytes, " +
                                "${(deadline - now).coerceAtLeast(0)}ms left")
                            lastHeartbeat = now
                        }
                    }
                    out.flush()
                }
            }
            val userCancelled = cancelFlags[id] == true
            val exitReason = when {
                userCancelled -> "cancelled"
                System.currentTimeMillis() >= deadline -> "deadline"
                else -> "stream-end"
            }
            srDebug("id=$id copy loop EXIT ($exitReason) total=${total} bytes")

            // fix697: a "Delete + remove file" on a still-recording row asked us to
            // remove the partial. The output stream is now closed (the use{} block
            // above returned), so the service deletes the file it owns with no
            // open-fd race, skips finalize + the completion notification, and lets
            // Dart drop the row (any status we'd journal is a no-op on a row Dart
            // is deleting in parallel).
            if (userCancelled && deleteOnCancel[id] == true) {
                srDebug("id=$id delete-on-cancel: removing partial file")
                runCatching { contentResolver.delete(mediaUri, null, null) }
                return
            }

            finalizeMediaStore(mediaUri)
            srDebug("id=$id finalizeMediaStore done")
            if (total < 64 * 1024) {
                srDebug("id=$id too little data (${total}); writing status=failed")
                updateStatus(id, "failed", mediaUri.toString(),
                    "Captured too little data (${total} bytes)")
                // fix697: notify only for UNATTENDED completions — a user-initiated
                // stop means they are already in the app looking at it.
                if (!userCancelled) postCompletion(id, name, false, "Captured too little data")
            } else {
                // fix685: the native MediaExtractor/MediaMuxer remux (fix671) was a
                // dead end — Android's extractor cannot parse these live-TV .ts
                // streams ("Failed to instantiate extractor"). Container work now
                // happens in Dart via FFI over the libmpv-exported libavformat
                // (RecordingRemux), triggered from RecordingStatusJournal.drain.
                // The service always finishes on the .ts and records whether remux
                // was requested; Dart picks it up on the next Recordings load.
                srDebug("id=$id capture done; status=done (remux=$remux, deferred to Dart)")
                updateStatus(id, "done", mediaUri.toString(), null, remux = remux)
                // fix697: item 2 — tell the user their recording finished. Native
                // (not a Flutter toast) because completion happens in the fg service
                // when the app may be backgrounded/killed. Suppressed on user stop.
                if (!userCancelled) postCompletion(id, name, true, null)
            }
            srDebug("id=$id runCapture COMPLETE")
        } catch (e: Exception) {
            srDebug("id=$id runCapture THREW ${e.javaClass.simpleName}: ${e.message}")
            Log.w(TAG, "capture $id failed: ${e.message}")
            val userCancelled = cancelFlags[id] == true
            mediaUri?.let { uri ->
                // fix697: honor delete-on-cancel on the error path too.
                if (userCancelled && deleteOnCancel[id] == true) {
                    runCatching { contentResolver.delete(uri, null, null) }
                } else {
                    runCatching { finalizeMediaStore(uri) }
                }
            }
            updateStatus(id, "failed", mediaUri?.toString(), e.message ?: "error")
            if (!userCancelled) postCompletion(id, name, false, e.message ?: "error")
        } finally {
            runCatching { conn?.disconnect() }
            runCatching { if (wakeLock.isHeld) wakeLock.release() }
            runCatching { if (wifiLock.isHeld) wifiLock.release() }
            // fix697: honor a delete-on-cancel flag that arrived DURING finalize —
            // a natural deadline completed the copy the same instant the user chose
            // "remove file", so the copy-loop delete branch had already been passed
            // (userCancelled was false) and ACTION_STOP deferred to this (still
            // active) thread. The file is finalized by now; remove it. Idempotent
            // if the copy-loop branch already deleted it.
            if (mediaUri != null && deleteOnCancel[id] == true) {
                srDebug("id=$id finally: honoring late delete-on-cancel")
                runCatching { contentResolver.delete(mediaUri, null, null) }
            }
            active.remove(id)
            cancelFlags.remove(id)
            deleteOnCancel.remove(id) // fix697
            srDebug("id=$id capture thread cleanup; stopSelfIfIdle")
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

    // fix681: single-writer. The service NO LONGER opens db.sqlite (its framework
    // SQLiteDatabase handle raced the app's sqlite_async WAL and matched 0 rows,
    // so status never reached the UI's row). Instead it appends one JSON line per
    // status change to sr_status.jsonl in the app files dir; Dart
    // (RecordingStatusJournal.drain) is the sole DB writer and applies these on
    // the next Recordings load / app resume. Append-only + isolate-agnostic.
    private fun updateStatus(
        id: Int, status: String, outputPath: String?, error: String?,
        remux: Boolean = false,
    ) {
        try {
            val obj = org.json.JSONObject().apply {
                put("id", id)
                put("status", status)
                if (outputPath != null) put("output_path", outputPath)
                if (error != null) put("error", error)
                if (remux) put("remux", true) // fix685: Dart remuxes this .ts on next load
                put("ts", System.currentTimeMillis())
            }
            File(applicationContext.filesDir, "sr_status.jsonl")
                .appendText(obj.toString() + "\n")
            srDebug("updateStatus id=$id status=$status journaled")
        } catch (e: Exception) {
            srDebug("updateStatus id=$id status=$status journal THREW ${e.javaClass.simpleName}: ${e.message}")
            Log.w(TAG, "updateStatus($id,$status) journal failed: ${e.message}")
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

    // fix697: item 2 — one-shot "recording complete/failed" notification. Posted
    // on a SEPARATE, audible channel (IMPORTANCE_DEFAULT) with a distinct id
    // (DONE_NOTI_ID_BASE+id) so the ongoing-capture teardown — stopForeground(
    // STOP_FOREGROUND_REMOVE), which clears only NOTI_ID_BASE+id — does not remove
    // it. auto-cancel; tapping launches the app. Needs POST_NOTIFICATIONS granted
    // on API 33+ (MainActivity requests it); best-effort — a denied permission
    // just drops the notify. Requires no live Dart engine, so it works when the
    // app is backgrounded or killed (the whole point vs a Flutter SnackBar).
    private fun postCompletion(id: Int, name: String, ok: Boolean, detail: String?) {
        try {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                mgr.getNotificationChannel(DONE_CHANNEL_ID) == null
            ) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        DONE_CHANNEL_ID, "Recording finished",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply { description = "A scheduled recording finished or failed" }
                )
            }
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, DONE_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            builder
                .setContentTitle(if (ok) "Recording complete" else "Recording failed")
                .setContentText(
                    if (ok || detail.isNullOrBlank()) name else "$name — $detail"
                )
                .setSmallIcon(
                    if (ok) android.R.drawable.stat_sys_download_done
                    else android.R.drawable.stat_notify_error
                )
                .setAutoCancel(true)
            val launch = packageManager.getLaunchIntentForPackage(packageName)
            if (launch != null) {
                builder.setContentIntent(
                    PendingIntent.getActivity(
                        this, DONE_NOTI_ID_BASE + id, launch,
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    )
                )
            }
            mgr.notify(DONE_NOTI_ID_BASE + id, builder.build())
            srDebug("id=$id postCompletion ok=$ok posted")
        } catch (e: Exception) {
            srDebug("id=$id postCompletion THREW ${e.javaClass.simpleName}: ${e.message}")
            Log.w(TAG, "postCompletion($id) failed: ${e.message}")
        }
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
