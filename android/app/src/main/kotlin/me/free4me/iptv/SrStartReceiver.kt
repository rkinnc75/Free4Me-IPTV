package me.free4me.iptv

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * fix678: starts [RecordingCaptureService] from the alarm BACKGROUND ISOLATE.
 *
 * The scheduled-recording alarm callback runs in android_alarm_manager_plus's
 * headless Flutter engine. That engine only has the plugins listed in
 * GeneratedPluginRegistrant (pub packages) attached — it has NO MainActivity,
 * so the `me.free4me.iptv/recording` MethodChannel (registered in
 * MainActivity.configureFlutterEngine) does not exist there. Calling it threw
 * `MissingPluginException(No implementation found for method startCapture ...)`
 * and every scheduled recording failed at capture start (confirmed on device
 * via the fix676 [SRDBG] trace).
 *
 * The fix: the Dart callback sends an EXPLICIT broadcast (via android_intent_plus,
 * a pub plugin that IS attached to the background engine and uses
 * applicationContext, so it works with no Activity) to this receiver, which then
 * starts the foreground capture service. Explicit (component-targeted) +
 * exported=false keeps it off the implicit-broadcast restrictions and private to
 * the app. Starting a foreground service here is permitted: this runs in-process
 * immediately after an exact `allowWhileIdle` alarm, within the alarm's
 * foreground-service-start grace window.
 */
class SrStartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        // The extras arrive via android_intent_plus's message codec, which may
        // encode a Dart int as either Java Integer or Long depending on value
        // and version. Read them type-agnostically so a codec change can't
        // silently break the id/duration lookup.
        val extras = intent.extras
        val id = (extras?.get(EXTRA_ID) as? Number)?.toInt() ?: -1
        val durationMs = (extras?.get(EXTRA_DURATION_MS) as? Number)?.toLong() ?: -1L
        val url = extras?.get(EXTRA_URL) as? String
        val name = (extras?.get(EXTRA_NAME) as? String) ?: "Recording"
        val remux = (extras?.get(EXTRA_REMUX) as? Boolean) ?: false
        val debugLogging = (extras?.get(EXTRA_DEBUG) as? Boolean) ?: false
        if (id == -1 || url == null || durationMs <= 0L) {
            Log.w(TAG, "SrStartReceiver: bad extras id=$id durationMs=$durationMs url=${url != null}")
            return
        }
        Log.i(TAG, "SrStartReceiver: starting capture id=$id durationMs=$durationMs")
        // fix681: gate on the passed flag — no DB read here either (single-writer).
        if (debugLogging) srDebug(context, "SrStartReceiver: starting capture id=$id durationMs=$durationMs")
        RecordingCaptureService.start(context.applicationContext, id, url, durationMs, name, remux, debugLogging)
    }

    // fix681: gated plugin-free breadcrumb (append to app_log.txt). Gate is the
    // caller's passed flag; no DB access.
    private fun srDebug(context: Context, msg: String) {
        try {
            val line = "[${java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss",
                java.util.Locale.US).format(java.util.Date())}] [SRDBG] $msg\n"
            java.io.File(context.applicationContext.filesDir, "app_log.txt").appendText(line)
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val TAG = "SRCapture"
        const val ACTION = "me.free4me.iptv.SR_START"
        const val EXTRA_ID = "id"
        const val EXTRA_URL = "url"
        const val EXTRA_DURATION_MS = "durationMs"
        const val EXTRA_NAME = "name"
        const val EXTRA_REMUX = "remux"
        const val EXTRA_DEBUG = "debugLogging"
    }
}
