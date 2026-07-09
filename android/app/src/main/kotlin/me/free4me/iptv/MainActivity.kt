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
        // fix665: deep-link scheme/host for TV home-row favorite cards.
        private const val SCHEME = "free4me"
        private const val HOST = "play"
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
                        RecordingCaptureService.stop(applicationContext, id)
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

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (isVideoPlaying && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
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
            builder.setAutoEnterEnabled(isVideoPlaying)
        }
        return builder.build()
    }
}
