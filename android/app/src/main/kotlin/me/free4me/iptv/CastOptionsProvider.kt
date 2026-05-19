package me.free4me.iptv

import android.content.Context
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider

/**
 * Tells the Google Cast SDK to use the Default Media Receiver.
 * The receiver ID CC1AD845 supports HLS, DASH, and MP4 — which is exactly
 * the set of formats the ExoPlayer engine handles, so all castable streams
 * should work without a custom receiver app.
 *
 * The AndroidManifest points to this class via:
 *   <meta-data
 *       android:name="com.google.android.gms.cast.framework.OPTIONS_PROVIDER_CLASS_NAME"
 *       android:value="me.free4me.iptv.CastOptionsProvider" />
 */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions {
        return CastOptions.Builder()
            .setReceiverApplicationId("CC1AD845") // Default Media Receiver
            .build()
    }

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}
