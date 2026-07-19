package me.free4me.iptv

import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.speech.RecognizerIntent
import android.util.Rational
import android.view.KeyEvent
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var pipEventSink: EventChannel.EventSink? = null
    // Dart tells us whether the player is active so onUserLeaveHint
    // only triggers PiP when video is actually playing.
    private var isVideoPlaying = false

    // fix758: while the updater hands the downloaded APK to the system
    // installer, PiP/auto-enter must not keep the OLD version visible over the
    // install prompt. This flag suppresses PiP for the handoff and is cleared
    // when the user returns (onResume) or if the installer could not open
    // (endApkInstall). The old task is intentionally NOT removed: OpenFilex
    // serves the APK through this app's FileProvider, so the process must stay
    // alive for the (later, post-tap) package read — PackageManager kills it
    // during the real replace.
    private var apkInstallHandoff = false

    // ── fix647: voice search ──────────────────────────────────────────────
    // The remote's mic button is an Assistant key the system consumes, so the
    // app launches the RecognizerIntent dialog itself instead: from the Search
    // tab's mic button (Dart calls "start") or a hardware KEYCODE_SEARCH press
    // on any screen (onKeyDown below). Recognized text is delivered INTO Dart
    // as an inbound "voiceResult" method call; Dart routes it to the Search
    // tab. Phone mode never binds a handler, so inbound calls are dropped.
    private var voiceChannel: MethodChannel? = null
    private var voicePending = false

    // ── fix665: Android TV home-screen favorites row ──────────────────────
    // Dart pushes the ordered+capped favorites list here to publish, and
    // clears the row when the feature is turned off. Inbound deep links
    // (free4me://play/{id}) from the launcher cards are forwarded INTO Dart as
    // a "playChannel" method call; a link that arrives before Dart binds the
    // handler is stashed in pendingDeepLinkId and flushed on bind.
    private var tvHomeChannel: MethodChannel? = null
    private var pendingDeepLinkChannelId: Int? = null

    companion object {
        private const val VOICE_REQUEST_CODE = 64701
        // fix697: runtime POST_NOTIFICATIONS request code (API 33+).
        private const val NOTI_PERM_REQUEST_CODE = 64702
        // fix665: deep-link scheme/host for TV home-row favorite cards.
        private const val SCHEME = "free4me"
        private const val HOST = "play"
    }

    // fix697: request POST_NOTIFICATIONS once on API 33+ so the one-shot
    // recording-complete/failed notification (RecordingCaptureService.postCompletion)
    // can be shown. The ongoing foreground-service notification is exempt, but an
    // independent mgr.notify() is silently dropped without this runtime grant.
    // Non-blocking: a denial only suppresses the completion heads-up; capture and
    // the ongoing notification still work. Called from the single onCreate below.
    private fun maybeRequestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            runCatching {
                requestPermissions(
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    NOTI_PERM_REQUEST_CODE,
                )
            }
        }
    }

    private fun launchVoiceRecognition() {
        if (voicePending) return
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Search channels and what's on…")
        }
        try {
            voicePending = true
            @Suppress("DEPRECATION")
            startActivityForResult(intent, VOICE_REQUEST_CODE)
        } catch (_: ActivityNotFoundException) {
            voicePending = false
            voiceChannel?.invokeMethod("voiceUnavailable", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VOICE_REQUEST_CODE) {
            voicePending = false
            if (resultCode == RESULT_OK) {
                val text = data
                    ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                    ?.firstOrNull()
                if (!text.isNullOrBlank()) {
                    voiceChannel?.invokeMethod("voiceResult", text)
                }
            }
            // Cancel / no match: do nothing — the user backed out.
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    // Remotes/keyboards with a dedicated SEARCH key can start voice search
    // from ANY screen. (The Assistant mic key never reaches the app.)
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_SEARCH) {
            launchVoiceRecognition()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(CastPlugin())

        // ── fix647: voice-search MethodChannel ────────────────────────────
        voiceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "me.free4me.iptv/voice",
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        launchVoiceRecognition()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // ── fix665: Android TV home-row MethodChannel ─────────────────────
        tvHomeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "me.free4me.iptv/tvhome",
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "publish" -> {
                        @Suppress("UNCHECKED_CAST")
                        val favs = (call.argument<List<Map<String, Any?>>>("favorites"))
                            ?: emptyList()
                        try {
                            TvHomeChannelPublisher.publishFavorites(
                                applicationContext, favs,
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("publish_failed", e.message, null)
                        }
                    }
                    "clear" -> {
                        try {
                            TvHomeChannelPublisher.clear(applicationContext)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("clear_failed", e.message, null)
                        }
                    }
                    // Dart calls this once it has bound the handler, to pull any
                    // deep link that launched the app before Dart was ready.
                    "consumePendingDeepLink" -> {
                        val id = pendingDeepLinkChannelId
                        pendingDeepLinkChannelId = null
                        result.success(id)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // A deep link may have launched us before the channel existed.
        handleDeepLinkIntent(intent)

        // ── fix506: render-cap pref bridge ────────────────────────────────
        // Flutter's render-cap toggle writes the SharedPref that
        // attachBaseContext/onCreate read at the NEXT launch.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "me.free4me.iptv/render",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setCap" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    getSharedPreferences("free4me_prefs", Context.MODE_PRIVATE)
                        .edit().putBoolean("render_1080p_cap", enabled).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ── PiP MethodChannel ─────────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "me.free4me.iptv/pip",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" ->
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)

                "enterPip" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        enterPictureInPictureMode(buildPipParams())
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }

                // Flutter calls this to keep the native side in sync with
                // playback state so onUserLeaveHint knows whether to PiP.
                "setPlaying" -> {
                    isVideoPlaying = call.argument<Boolean>("playing") ?: false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        // Android 12+: update auto-enter enabled live
                        setPictureInPictureParams(buildPipParams())
                    }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        // ── fix758: in-app update install handoff (PiP suppression only) ──
        // No task removal and no isVideoPlaying mutation: the installer reads
        // the APK via this app's FileProvider, so the process must stay alive,
        // and the apkInstallHandoff flag alone fully suppresses PiP (see
        // buildPipParams / onUserLeaveHint). onResume clears it on return.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "me.free4me.iptv/update_install",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "beginApkInstall" -> {
                    apkInstallHandoff = true
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        setPictureInPictureParams(buildPipParams())
                    }
                    result.success(null)
                }

                "endApkInstall" -> {
                    // Installer could not open — restore normal PiP behaviour.
                    apkInstallHandoff = false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        setPictureInPictureParams(buildPipParams())
                    }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        // ── fix668: Scheduled Recording capture control ───────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "me.free4me.iptv/recording",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // fix682: the "startCapture" MethodChannel case was removed. Since
                // fix678, Dart starts capture via an explicit SR_START broadcast to
                // SrStartReceiver (so it works from the alarm background isolate,
                // where this Activity-scoped channel does not exist). This handler
                // was dead code and still called the old RecordingCaptureService
                // .start() signature (pre-fix681, no remux/debugLogging), which
                // broke :app:compileReleaseKotlin. stopCapture/getFreeBytes remain
                // (still invoked from the main isolate).
                "stopCapture" -> {
                    val id = call.argument<Int>("id")
                    if (id == null) {
                        result.error("bad_args", "id required", null)
                    } else {
                        // fix697: deleteFile=true means the user chose "Delete +
                        // remove file" on a still-recording row — the service
                        // removes the partial itself when the copy stream closes,
                        // or (no live capture) deletes the passed URI directly.
                        val deleteFile = call.argument<Boolean>("deleteFile") ?: false
                        val uri = call.argument<String>("uri")
                        RecordingCaptureService.stop(applicationContext, id, deleteFile, uri)
                        result.success(true)
                    }
                }
                "getFreeBytes" -> {
                    // fix670: free space on external storage (where MediaStore
                    // recordings land). Falls back to internal filesDir.
                    try {
                        val dir = applicationContext.getExternalFilesDir(null)
                            ?: applicationContext.filesDir
                        val stat = android.os.StatFs(dir.absolutePath)
                        result.success(stat.availableBytes)
                    } catch (e: Exception) {
                        result.error("statfs_failed", e.message, null)
                    }
                }
                // ── fix693: recording file metadata for the details sheet ─────
                "recordingFileInfo" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) { result.error("bad_args", "uri required", null); return@setMethodCallHandler }
                    val out = HashMap<String, Any?>()
                    val u = android.net.Uri.parse(uri)
                    // Size + a human-readable relative path from MediaStore.
                    try {
                        contentResolver.query(
                            u,
                            arrayOf(
                                android.provider.MediaStore.MediaColumns.SIZE,
                                android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                                android.provider.MediaStore.MediaColumns.DISPLAY_NAME,
                            ),
                            null, null, null,
                        )?.use { c ->
                            if (c.moveToFirst()) {
                                val si = c.getColumnIndex(android.provider.MediaStore.MediaColumns.SIZE)
                                val ri = c.getColumnIndex(android.provider.MediaStore.MediaColumns.RELATIVE_PATH)
                                val di = c.getColumnIndex(android.provider.MediaStore.MediaColumns.DISPLAY_NAME)
                                if (si >= 0 && !c.isNull(si)) out["sizeBytes"] = c.getLong(si)
                                val rel = if (ri >= 0) c.getString(ri) ?: "" else ""
                                val disp = if (di >= 0) c.getString(di) ?: "" else ""
                                if (rel.isNotEmpty() || disp.isNotEmpty()) out["path"] = "$rel$disp"
                            }
                        }
                    } catch (_: Exception) {
                        // best-effort: fall through with whatever we have
                    }
                    // Media metadata (resolution, duration, bitrate, mime).
                    val mmr = android.media.MediaMetadataRetriever()
                    try {
                        mmr.setDataSource(applicationContext, u)
                        fun m(k: Int) = mmr.extractMetadata(k)
                        m(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()?.let { out["width"] = it }
                        m(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()?.let { out["height"] = it }
                        m(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.let { out["durationMs"] = it }
                        m(android.media.MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull()?.let { out["bitrate"] = it }
                        m(android.media.MediaMetadataRetriever.METADATA_KEY_MIMETYPE)?.let { out["mime"] = it }
                    } catch (_: Exception) {
                        // metadata is best-effort; sheet shows what resolved
                    } finally {
                        try { mmr.release() } catch (_: Exception) {}
                    }
                    result.success(out)
                }
                // ── fix685: MediaStore fds for the Dart FFI remux ─────────────
                // The .ts capture and its .mp4/.mkv output live in MediaStore
                // (content:// Uris). Dart's libavformat remux (RecordingRemux)
                // opens them via the ffmpeg "fd:" protocol, so these methods do
                // the ContentResolver work and hand back detached, dup'd file
                // descriptors as plain ints. Dart closes each fd via remuxCloseFd.
                "remuxOpenRead" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) { result.error("bad_args", "uri required", null); return@setMethodCallHandler }
                    try {
                        val pfd = contentResolver.openFileDescriptor(
                            android.net.Uri.parse(uri), "r")
                        if (pfd == null) result.success(null)
                        else result.success(pfd.detachFd())
                    } catch (e: Exception) {
                        result.error("open_read_failed", e.message, null)
                    }
                }
                "remuxCreateOutput" -> {
                    val name = call.argument<String>("name") ?: "recording"
                    val ext = call.argument<String>("ext") ?: "mp4"
                    try {
                        val mime = if (ext == "mkv") "video/x-matroska" else "video/mp4"
                        val safe = name.replace(Regex("[^A-Za-z0-9 ._-]"), "_").take(80)
                        val fileName = "${safe}_${System.currentTimeMillis()}.$ext"
                        val values = android.content.ContentValues().apply {
                            put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                            put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, "Movies/Free4Me")
                                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
                            }
                        }
                        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            android.provider.MediaStore.Video.Media.getContentUri(
                                android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
                        } else {
                            android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        }
                        val dstUri = contentResolver.insert(collection, values)
                        if (dstUri == null) { result.success(null); return@setMethodCallHandler }
                        val pfd = contentResolver.openFileDescriptor(dstUri, "rw")
                        if (pfd == null) {
                            runCatching { contentResolver.delete(dstUri, null, null) }
                            result.success(null)
                        } else {
                            result.success(mapOf("uri" to dstUri.toString(), "fd" to pfd.detachFd()))
                        }
                    } catch (e: Exception) {
                        result.error("create_output_failed", e.message, null)
                    }
                }
                "remuxFinalize" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) { result.error("bad_args", "uri required", null); return@setMethodCallHandler }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val values = android.content.ContentValues().apply {
                                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
                            }
                            contentResolver.update(android.net.Uri.parse(uri), values, null, null)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("finalize_failed", e.message, null)
                    }
                }
                "remuxDiscard", "remuxDeleteTs" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) { result.error("bad_args", "uri required", null); return@setMethodCallHandler }
                    try {
                        contentResolver.delete(android.net.Uri.parse(uri), null, null)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("delete_failed", e.message, null)
                    }
                }
                "remuxCloseFd" -> {
                    val fd = call.argument<Int>("fd")
                    if (fd == null) { result.error("bad_args", "fd required", null); return@setMethodCallHandler }
                    try {
                        android.os.ParcelFileDescriptor.adoptFd(fd).close()
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "me.free4me.iptv/pip_events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                pipEventSink = sink
            }
            override fun onCancel(arguments: Any?) {
                pipEventSink = null
            }
        })
    }

    // ── fix506: 1080p render cap for low-RAM 4K TV boxes ──────────────────
    // A weak GPU (onn 4K Plus / Mali-G310) renders the Flutter UI far more
    // smoothly at 1080p than native 4K. We halve BOTH the surface buffer
    // (setFixedSize) AND the density (attachBaseContext) so the LOGICAL layout
    // is unchanged while a quarter of the pixels are rendered; SurfaceFlinger
    // upscales to the panel. Gated on TV + low-RAM + >1080p + the user pref
    // (default on); disable in Settings → Playback. Applies at launch.
    private var renderScale: Double = 1.0

    override fun attachBaseContext(newBase: Context) {
        val scale = renderCapScale(newBase)
        renderScale = scale
        if (scale > 1.0) {
            val config = Configuration(newBase.resources.configuration)
            config.densityDpi = (config.densityDpi / scale).toInt()
            super.attachBaseContext(newBase.createConfigurationContext(config))
        } else {
            super.attachBaseContext(newBase)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        maybeRequestNotificationPermission() // fix697
        if (renderScale > 1.0) {
            // Buffer is sized in PHYSICAL pixels (widthPixels is unaffected by
            // the density override above), so /renderScale yields 1080p on 4K.
            window.decorView.post {
                try {
                    val sv = findSurfaceView(findViewById(android.R.id.content))
                    val m = resources.displayMetrics
                    sv?.holder?.setFixedSize(
                        (m.widthPixels / renderScale).toInt(),
                        (m.heightPixels / renderScale).toInt(),
                    )
                } catch (_: Throwable) {
                    // Best-effort; never block launch.
                }
            }
        }
    }

    // Downscale factor (>1.0) when the render cap should apply, else 1.0:
    // user pref on (default) + leanback TV + low-RAM (<2300 MB, matching the
    // Dart DeviceDetector cutoff) + a panel wider than 1080p.
    private fun renderCapScale(ctx: Context): Double {
        return try {
            val prefs =
                ctx.getSharedPreferences("free4me_prefs", Context.MODE_PRIVATE)
            if (!prefs.getBoolean("render_1080p_cap", true)) return 1.0
            if (!ctx.packageManager
                    .hasSystemFeature(PackageManager.FEATURE_LEANBACK)) {
                return 1.0
            }
            val am = ctx.getSystemService(Context.ACTIVITY_SERVICE)
                as ActivityManager
            val mem = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mem)
            if (mem.totalMem >= 2300L * 1024 * 1024) return 1.0
            val m = ctx.resources.displayMetrics
            val maxDim = maxOf(m.widthPixels, m.heightPixels)
            if (maxDim <= 1920) 1.0 else maxDim / 1920.0
        } catch (_: Throwable) {
            1.0
        }
    }

    private fun findSurfaceView(v: View?): SurfaceView? {
        if (v is SurfaceView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                val r = findSurfaceView(v.getChildAt(i))
                if (r != null) return r
            }
        }
        return null
    }

    // Enter PiP automatically when the user presses Home (phone) or Back
    // out to the launcher, as long as video is playing.
    // fix665: singleTop launch activity — a deep link tapped while the app is
    // already running arrives here rather than through onCreate.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDeepLinkIntent(intent)
    }

    // fix665: parse free4me://play/{channelId}. If Dart's handler is bound,
    // deliver immediately; otherwise stash for Dart to pull on bind.
    private fun handleDeepLinkIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != SCHEME || data.host != HOST) return
        val id = data.lastPathSegment?.toIntOrNull() ?: return
        val ch = tvHomeChannel
        if (ch != null) {
            ch.invokeMethod("playChannel", id)
        } else {
            pendingDeepLinkChannelId = id
        }
    }

    override fun onResume() {
        super.onResume()
        // fix758: the user returned to the app (e.g. cancelled the install
        // prompt) — clear the handoff flag so PiP works normally again.
        if (apkInstallHandoff) {
            apkInstallHandoff = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setPictureInPictureParams(buildPipParams())
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // fix758: never enter PiP while handing the APK to the installer, or a
        // playing video would keep the old version visible over the prompt.
        if (!apkInstallHandoff &&
            isVideoPlaying &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            enterPictureInPictureMode(buildPipParams())
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipEventSink?.success(isInPictureInPictureMode)
    }

    private fun buildPipParams(): PictureInPictureParams {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            // Should never be reached — callers guard on SDK >= O.
            throw UnsupportedOperationException("PiP requires API 26+")
        }
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Auto-enter PiP when the user navigates away (Android 12+).
            // fix758: never auto-enter during the APK install handoff.
            builder.setAutoEnterEnabled(isVideoPlaying && !apkInstallHandoff)
        }
        return builder.build()
    }
}
