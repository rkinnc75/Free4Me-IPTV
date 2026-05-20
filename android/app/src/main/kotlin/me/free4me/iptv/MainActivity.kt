package me.free4me.iptv

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var pipEventSink: EventChannel.EventSink? = null
    // Dart tells us whether the player is active so onUserLeaveHint
    // only triggers PiP when video is actually playing.
    private var isVideoPlaying = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(CastPlugin())

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

        // ── PiP EventChannel — streams mode changes to Flutter ────────────
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

    // Enter PiP automatically when the user presses Home (phone) or Back
    // out to the launcher, as long as video is playing.
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
