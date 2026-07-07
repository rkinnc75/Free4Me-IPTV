package me.free4me.iptv

import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.tvprovider.media.tv.Channel
import androidx.tvprovider.media.tv.ChannelLogoUtils
import androidx.tvprovider.media.tv.PreviewProgram
import androidx.tvprovider.media.tv.TvContractCompat

/**
 * fix665: publishes the user's favorites to the Android TV home-screen as a
 * preview-channel row ("Free4Me Favorites"). Each card deep-links back into the
 * app (free4me://play/{channelId}). TV-only; called from Dart via the
 * me.free4me.iptv/tvhome MethodChannel.
 *
 * Data (which channels, ordering=last_watched, count cap) is decided in Dart
 * (Sql.getFavoritesByLastWatched) and passed in as a list of maps, so this file
 * stays a thin TvContractCompat adapter with no DB knowledge.
 */
object TvHomeChannelPublisher {
    private const val TAG = "TvHomeChannelPublisher"
    private const val PREFS = "free4me_tv_channel_prefs"
    private const val KEY_CHANNEL_ID = "home_channel_id"
    private const val SCHEME = "free4me"
    private const val HOST = "play"

    private fun buildDeepLink(channelId: Int): Uri =
        Uri.parse("$SCHEME://$HOST/$channelId")

    /** Register (or return the existing) app channel on the TV home screen. */
    private fun ensureChannel(context: Context): Long {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getLong(KEY_CHANNEL_ID, -1L)
        if (stored != -1L) return stored

        val channel = Channel.Builder()
            .setType(TvContractCompat.Channels.TYPE_PREVIEW)
            .setDisplayName("Free4Me Favorites")
            .setAppLinkIntentUri(Uri.parse("$SCHEME://home"))
            .build()

        return try {
            val uri = context.contentResolver.insert(
                TvContractCompat.Channels.CONTENT_URI,
                channel.toContentValues(),
            ) ?: return -1L
            val id = ContentUris.parseId(uri)
            prefs.edit().putLong(KEY_CHANNEL_ID, id).apply()
            // Ask the system to surface the row (user approves once).
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                TvContractCompat.requestChannelBrowsable(context, id)
            }
            id
        } catch (e: Exception) {
            Log.w(TAG, "Failed to register TV channel: ${e.message}")
            -1L
        }
    }

    /**
     * Publish [favorites] (already ordered + capped by Dart) as preview
     * programs. Each entry is a map with keys: id (Int), name (String),
     * image (String?, logo URL).
     */
    fun publishFavorites(context: Context, favorites: List<Map<String, Any?>>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channelId = ensureChannel(context)
        if (channelId == -1L) return

        try {
            // Clear stale programs so the row reflects the current favorites.
            context.contentResolver.delete(
                TvContractCompat.buildPreviewProgramsUriForChannel(channelId),
                null, null,
            )

            for (fav in favorites) {
                val id = (fav["id"] as? Number)?.toInt() ?: continue
                val name = fav["name"] as? String ?: continue
                val logo = fav["image"] as? String

                val builder = PreviewProgram.Builder()
                    .setChannelId(channelId)
                    .setType(TvContractCompat.PreviewPrograms.TYPE_CHANNEL)
                    .setTitle(name)
                    .setIntentUri(buildDeepLink(id))
                    .setInternalProviderId(id.toString())

                if (!logo.isNullOrBlank()) {
                    builder.setPosterArtUri(Uri.parse(logo))
                }

                val programUri = context.contentResolver.insert(
                    TvContractCompat.PreviewPrograms.CONTENT_URI,
                    builder.build().toContentValues(),
                )

                // Best-effort logo bitmap (some launchers want the bitmap set
                // explicitly rather than just the poster URI).
                if (programUri != null && !logo.isNullOrBlank()) {
                    runCatching {
                        val programId = ContentUris.parseId(programUri)
                        ChannelLogoUtils.storeChannelLogo(
                            context, programId, Uri.parse(logo),
                        )
                    }
                }
            }
            Log.d(TAG, "Published ${favorites.size} favorite card(s)")
        } catch (e: Exception) {
            Log.w(TAG, "publishFavorites failed: ${e.message}")
        }
    }

    /** Remove the row entirely (called when the user turns the feature off). */
    fun clear(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val id = prefs.getLong(KEY_CHANNEL_ID, -1L)
        if (id == -1L) return
        try {
            context.contentResolver.delete(
                TvContractCompat.buildChannelUri(id), null, null,
            )
        } catch (e: Exception) {
            Log.w(TAG, "clear failed: ${e.message}")
        } finally {
            prefs.edit().remove(KEY_CHANNEL_ID).apply()
        }
    }
}
