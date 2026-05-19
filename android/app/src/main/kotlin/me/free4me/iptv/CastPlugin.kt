package me.free4me.iptv

import android.content.Context
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastState
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/**
 * Flutter plugin that bridges the Google Cast SDK to Dart via a MethodChannel.
 *
 * Registered in [MainActivity] on app start.
 *
 * Exposed methods (channel name "me.free4me.iptv/cast"):
 *   isAvailable()   → Boolean
 *   getState()      → String  ("connected"|"connecting"|"not_connected"|"no_devices"|"unavailable")
 *   showDevicePicker() → void  (opens the native MediaRouter device picker)
 *   startCast(url, title, contentType) → void  (throws NO_SESSION if no cast session)
 *   stopCast()      → void
 *   getPosition()   → Long (milliseconds)
 */
class CastPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var context: Context? = null

    // ── FlutterPlugin ─────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "me.free4me.iptv/cast")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    // ── MethodCallHandler ─────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("NO_CONTEXT", "Plugin detached", null)
        when (call.method) {
            "isAvailable" -> result.success(isPlayServicesAvailable(ctx))
            "getState"    -> result.success(getCastStateString(ctx))
            "showDevicePicker" -> {
                showDevicePicker(ctx)
                result.success(null)
            }
            "startCast"   -> startCast(ctx, call, result)
            "stopCast"    -> {
                stopCast(ctx)
                result.success(null)
            }
            "getPosition" -> result.success(getPosition(ctx))
            else          -> result.notImplemented()
        }
    }

    // ── Implementation ────────────────────────────────────────────────────────

    private fun isPlayServicesAvailable(ctx: Context): Boolean {
        return try {
            GoogleApiAvailability.getInstance()
                .isGooglePlayServicesAvailable(ctx) == ConnectionResult.SUCCESS
        } catch (_: Exception) { false }
    }

    private fun getCastStateString(ctx: Context): String {
        if (!isPlayServicesAvailable(ctx)) return "unavailable"
        return try {
            when (CastContext.getSharedInstance(ctx).castState) {
                CastState.NO_DEVICES_AVAILABLE -> "no_devices"
                CastState.NOT_CONNECTED        -> "not_connected"
                CastState.CONNECTING           -> "connecting"
                CastState.CONNECTED            -> "connected"
                else                           -> "unavailable"
            }
        } catch (_: Exception) { "unavailable" }
    }

    private fun showDevicePicker(ctx: Context) {
        if (!isPlayServicesAvailable(ctx)) return
        try {
            val activity = (ctx.applicationContext as? Free4MeApplication)
                ?.currentActivity as? androidx.fragment.app.FragmentActivity
                ?: return

            // Show the standard Cast device chooser dialog via MediaRouter.
            val selector = androidx.mediarouter.media.MediaRouteSelector.Builder()
                .addControlCategory(
                    com.google.android.gms.cast.CastMediaControlIntent
                        .categoryForCast(com.google.android.gms.cast.CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
                )
                .build()

            val dialog = androidx.mediarouter.app.MediaRouteChooserDialogFragment()
            dialog.routeSelector = selector
            dialog.show(activity.supportFragmentManager, "mediaRoute")
        } catch (_: Exception) {}
    }

    private fun startCast(ctx: Context, call: MethodCall, result: MethodChannel.Result) {
        if (!isPlayServicesAvailable(ctx)) {
            return result.error("UNAVAILABLE", "Play Services not available", null)
        }
        val url         = call.argument<String>("url")         ?: return result.error("INVALID", "url required", null)
        val title       = call.argument<String>("title")       ?: ""
        val contentType = call.argument<String>("contentType") ?: "video/mp4"

        try {
            val castContext = CastContext.getSharedInstance(ctx)
            val session     = castContext.sessionManager.currentCastSession
                ?: return result.error("NO_SESSION", "No active cast session", null)

            val remoteClient = session.remoteMediaClient
                ?: return result.error("NO_SESSION", "No remote media client", null)

            val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MOVIE).apply {
                putString(MediaMetadata.KEY_TITLE, title)
            }
            val mediaInfo = MediaInfo.Builder(url)
                .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
                .setContentType(contentType)
                .setMetadata(metadata)
                .build()

            remoteClient.load(MediaLoadRequestData.Builder().setMediaInfo(mediaInfo).build())
            result.success(null)
        } catch (e: Exception) {
            result.error("CAST_ERROR", e.message, null)
        }
    }

    private fun stopCast(ctx: Context) {
        if (!isPlayServicesAvailable(ctx)) return
        try {
            CastContext.getSharedInstance(ctx).sessionManager.endCurrentSession(true)
        } catch (_: Exception) {}
    }

    private fun getPosition(ctx: Context): Long {
        if (!isPlayServicesAvailable(ctx)) return 0L
        return try {
            val session = CastContext.getSharedInstance(ctx)
                .sessionManager.currentCastSession
            session?.remoteMediaClient?.approximateStreamPosition ?: 0L
        } catch (_: Exception) { 0L }
    }
}
