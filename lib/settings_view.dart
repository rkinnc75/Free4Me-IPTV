import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/multi_view_picker_dialog.dart';
import 'package:open_tv/backend/epg_service.dart';
import 'package:open_tv/backend/settings_io.dart';
import 'package:open_tv/views/epg_channel_mapping.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/update_checker.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/bottom_nav.dart';
import 'package:open_tv/confirm_delete.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/select_dialog.dart';
import 'package:open_tv/edit_dialog.dart';
import 'package:open_tv/widgets/dpad_text_field.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/setup.dart';
import 'package:open_tv/whats_new_modal.dart';
import 'package:open_tv/widgets/setting_help_dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

// ─── Help copy constants ─────────────────────────────────────────────────────
// All strings are final per the development handbook. Do not paraphrase.

const _helpDefaultView = (
  title: 'Default View',
  body:
      'Which content type the app opens to when you launch it. '
      '"All" shows livestreams, movies, and series together. '
      '"Livestreams" jumps straight to live TV. '
      '"Movies" or "Series" opens that section directly.\n\n'
      'Choose whichever you use most — saves a navigation tap every launch. '
      'Default: All.',
);

const _helpForceTvMode = (
  title: 'Force TV Mode',
  body:
      'Overrides automatic device detection and always uses the '
      'TV-optimised layout — larger tiles, D-pad navigation, no touch '
      'shortcuts.\n\n'
      '↑ ON — forces TV layout on any device. Use this if the app '
      'incorrectly starts in phone mode on your Android TV box or Onn 4K.\n\n'
      '↓ OFF — uses the touch-friendly phone/tablet layout. '
      'Default: OFF.',
);

const _helpLowLatency = (
  title: 'Low Latency (Live TV)',
  body:
      'Tells libmpv to request the lowest-bitrate HLS variant stream '
      'and reduces internal buffering targets.\n\n'
      '↑ ON — minimises the delay between broadcast and playback. '
      'Useful for live sports where score spoilers matter. '
      'May reduce picture quality on HLS streams.\n\n'
      '↓ OFF — requests the highest-quality variant and uses larger '
      'buffers for smoother playback on stable connections.\n\n'
      'Has no effect on non-HLS streams (MPEG-TS, RTMP). Default: OFF.',
);

const _helpRefreshOnStart = (
  title: 'Refresh Sources on Start',
  body:
      'Re-downloads all M3U playlists and Xtream channel lists every '
      'time the app launches.\n\n'
      '↑ ON — always starts with the freshest channel list. Useful if '
      'your provider changes URLs often. Adds a few seconds to startup '
      'and uses data on every launch.\n\n'
      '↓ OFF — uses the cached list for instant startup. '
      'You can still refresh manually from the Sources section. '
      'Default: OFF.',
);

const _helpShowLivestreams = (
  title: 'Show Livestreams',
  body:
      'Controls whether live TV channels appear in the channel grid, '
      'search results, and "All" view.\n\n'
      '↑ ON — live TV is visible everywhere in the app.\n\n'
      '↓ OFF — hides all live TV channels. Does not delete them — '
      'they reappear when turned back on. '
      'Useful if your source only has movies and series. Default: ON.',
);

const _helpShowMovies = (
  title: 'Show Movies',
  body:
      'Controls whether on-demand movies appear in the channel grid, '
      'search results, and "All" view.\n\n'
      '↑ ON — movies are visible.\n\n'
      '↓ OFF — hides the movie library. Does not delete content. '
      'Default: ON.',
);

const _helpShowSeries = (
  title: 'Show Series',
  body:
      'Controls whether TV series and episodes appear in the channel '
      'grid, search results, and "All" view.\n\n'
      '↑ ON — series are visible.\n\n'
      '↓ OFF — hides series content. Does not delete content. '
      'Default: ON.',
);

const _helpHwDecode = (
  title: 'Hardware Decoding',
  body:
      'Uses your device\'s dedicated video-decoder chip instead of the CPU.\n\n'
      '↑ ON — MediaCodec (Android) or VideoToolbox (iOS/Apple TV) '
      'handles decoding. Dramatically reduces CPU heat and load. '
      'Required for smooth 4K/HEVC playback on TV boxes. '
      'Recommended for all devices. '
      'Android TV / Nvidia Shield automatically uses a copy mode '
      '(mediacodec-copy) that is compatible with all TV chipsets.\n\n'
      '↓ OFF — software (CPU) decoding. Use only if you see video '
      'corruption, a green screen, or black video with audio — '
      'which indicates a buggy hardware decoder on your device. '
      'Default: ON.',
);

const _helpPreWarm = (
  title: 'Pre-warm Streams on Focus',
  body:
      'Resolves redirect URLs in the background as soon as you highlight '
      'a channel tile with the D-pad or hover over it.\n\n'
      '↑ ON — playback starts noticeably faster when you select a channel '
      'because the redirect is already resolved. Best for D-pad navigation '
      'on TV boxes.\n\n'
      '↓ OFF — URL resolution happens at tap time. Slightly slower channel '
      'start but no background network activity while browsing. '
      'Recommended on metered mobile connections. Default: ON.',
);

const _helpLiveCacheSecs = (
  title: 'Livestream Cache (seconds)',
  body:
      'How many seconds of live TV libmpv reads ahead into memory.\n\n'
      '↑ Raising — reduces rebuffering on unstable or congested connections. '
      'Also adds a small rewind window. Uses more RAM. '
      'Values above 45 s can cause audio/video sync drift on slow streams.\n\n'
      '↓ Lowering — reduces RAM use. Recommended on 1–2 GB Android TV boxes '
      '(Onn 4K, Fire TV Stick). May increase rebuffering on weak signals.\n\n'
      'Has no effect in Low Latency mode (which disables caching entirely). '
      'Default: 20 s. Range: 5–60 s.',
);

const _helpLiveDemuxerMB = (
  title: 'Livestream Demuxer Buffer (MB)',
  body:
      'Maximum RAM the stream-splitter (demuxer) may use while playing '
      'live TV. This is separate from and in addition to the cache.\n\n'
      '↑ Raising — gives the decoder a larger in-memory cushion, reducing '
      'dropped frames on high-bitrate 4K or HEVC streams. '
      'Also helps when two streams play simultaneously (mini-player + '
      'full-screen).\n\n'
      '↓ Lowering — frees RAM. Reduce this first if the app is killed by '
      'the system on a low-memory box. 32–64 MB is sufficient for '
      'standard 1080p IPTV streams.\n\n'
      'Max is capped at 75 % of your device RAM. '
      'Default: auto-detected from RAM. Range: 32–512 MB.',
);

const _helpVodCacheSecs = (
  title: 'VOD/Movie Cache (seconds)',
  body:
      'How many seconds ahead libmpv reads from a movie or on-demand '
      'stream into memory.\n\n'
      '↑ Raising — reduces pauses during seek (fast-forward/rewind) and '
      'smooths playback on slow connections. Large values also improve '
      'chapter-skip responsiveness.\n\n'
      '↓ Lowering — reduces RAM use. Has no effect on live TV streams. '
      'Default: 60 s. Range: 10–180 s.',
);

const _helpVodDemuxerMB = (
  title: 'VOD/Movie Demuxer Buffer (MB)',
  body:
      'Maximum RAM the demuxer may use while playing a movie or series '
      'episode.\n\n'
      '↑ Raising — improves seek performance and reduces pauses on '
      'high-bitrate VOD (Blu-ray remuxes, 4K HDR). '
      'Essential for smooth chapter navigation on large files.\n\n'
      '↓ Lowering — frees RAM. Has no effect on live TV streams. '
      '64–128 MB is sufficient for most 1080p VOD. '
      'Default: 256 MB. Range: 64–1024 MB.',
);

const _helpOpenTimeout = (
  title: 'Stream Open Timeout (seconds)',
  body:
      'How long the player waits for a stream to begin playing before '
      'giving up and showing an error.\n\n'
      '↑ Raising — gives slow or geographically distant servers more time '
      'to respond. Helpful on congested networks or with international '
      'streams. Also useful for streams that take longer to negotiate '
      'a session.\n\n'
      '↓ Lowering — surfaces failures faster so the app can retry sooner. '
      'Reduce if you find yourself waiting a long time for obviously '
      'dead streams.\n\n'
      'Default: 15 s. Range: 5–60 s.',
);

const _helpWatchdog = (
  title: 'Buffering Watchdog (seconds)',
  body:
      'If a live stream stalls in a buffering/loading state for longer '
      'than this value, the player automatically reconnects.\n\n'
      '↑ Raising — gives the server more time to recover on its own. '
      'Better on intermittent connections where a brief stall '
      'self-resolves within a few seconds. Reduces unnecessary reconnects '
      'during temporary network hiccups.\n\n'
      '↓ Lowering — forces a reconnect sooner. Useful for streams that '
      'silently freeze without ever recovering — you get picture back '
      'faster at the cost of more reconnects on shaky connections.\n\n'
      'Note: when two streams are playing simultaneously (mini-player + '
      'full-screen), both watchdogs run independently. If both fire at '
      'the same time, the reconnects compete for bandwidth — '
      'raising this value reduces that risk. '
      'Default: 12 s. Range: 5–60 s.',
);

// ─── Widget ──────────────────────────────────────────────────────────────────

class SettingsView extends StatefulWidget {
  final bool showNavBar;

  const SettingsView({super.key, this.showNavBar = true});

  @override
  State<SettingsView> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsView> {
  Settings settings = Settings();
  List<Source> sources = [];
  bool loading = true;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    initAsync();
  }

  Future<void> initAsync() async {
    final results = await Future.wait([
      SettingsService.getSettings(),
      Sql.getSources(),
      PackageInfo.fromPlatform(),
    ]);
    if (!mounted) return;
    setState(() {
      settings = results[0] as Settings;
      sources = results[1] as List<Source>;
      final info = results[2] as PackageInfo;
      _appVersion = 'v${info.version}';
      loading = false;
    });
  }

  void updateView(ViewType view) {
    if (view != ViewType.settings) {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (_, _, _) => Home(
            home: HomeManager(filters: Filters(viewType: view)),
          ),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              child,
        ),
        (route) => false,
      );
    }
  }

  Future<void> showEditDialog(BuildContext context, final Source source) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (builder) =>
          EditDialog(source: source, afterSave: reloadSources),
    );
  }

  Future<void> _showDefaultViewDialog(BuildContext context) async {
    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return SelectDialog(
          title: "Default view",
          data: ViewType.values
              .take(4)
              .map((x) => IdData(id: x.index, data: viewTypeToString(x)))
              .toList(),
          action: (view) {
            setState(() {
              settings.defaultView = ViewType.values[view];
              updateSettings();
            });
            Navigator.of(context).pop();
          },
        );
      },
    );
  }

  Future<void> toggleSource(Source source) async {
    await Error.tryAsyncNoLoading(
      () async => await Sql.setSourceEnabled(!source.enabled, source.id!),
      context,
    );
    await reloadSources();
    if (!mounted) return;
    // After reloadSources(), source.enabled has been flipped in the new list,
    // so we read the updated state from the refreshed sources list.
    final updated = sources.where((s) => s.id == source.id).firstOrNull;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "${source.name} ${updated?.enabled == true ? "enabled" : "disabled"}",
        ),
        duration: const Duration(milliseconds: 800),
      ),
    );
  }

  Widget getSource(Source source) {
    return Opacity(
      opacity: source.enabled ? 1.0 : 0.5,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        elevation: 5,
        child: ListTile(
          leading: Icon(source.enabled ? Icons.tv : Icons.tv_off),
          horizontalTitleGap: 25,
          contentPadding: const EdgeInsets.only(left: 20),
          title: Text(source.name),
          subtitle: Text(source.sourceType.label),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Enable/disable toggle — explicit switch for discoverability
              Switch(
                value: source.enabled,
                onChanged: (_) => toggleSource(source),
              ),
              Offstage(
                offstage: source.sourceType == SourceType.m3u,
                child: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    await Error.tryAsync(
                      () async {
                        await Utils.refreshSource(source);
                      },
                      context,
                      "Source has been refreshed successfully",
                    );
                  },
                ),
              ),
              Offstage(
                offstage: source.sourceType == SourceType.m3u,
                child: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () async => await showEditDialog(context, source),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () async => await showConfirmDeleteDialog(source),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> showConfirmDeleteDialog(Source source) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (builder) => ConfirmDelete(
        type: "source",
        name: source.name,
        confirm: () async {
          await Error.tryAsync(
            () async => await Sql.deleteSource(source.id!),
            context,
            "Successfully deleted source",
          );
          await reloadSources();
          if (sources.isEmpty && mounted) {
            // ignore: use_build_context_synchronously
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => const Setup()),
              (route) => false,
            );
          }
        },
      ),
    );
  }

  Future<void> reloadSources() async {
    await Error.tryAsyncNoLoading(
      () async => sources = await Sql.getSources(),
      context,
    );
    if (mounted) setState(() {});
  }

  /// Shows a live progress dialog while refreshing all EPG sources, then
  /// displays a summary of results.
  Future<void> _runEpgRefresh(BuildContext ctx) async {
    String status = 'Starting…';
    int programs = 0;
    int matchDone = 0;
    int matchTotal = 0;
    final results = <String>[];

    bool dialogOpen = true;
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (sCtx, setSt) {
          _refreshSetState = setSt;
          _refreshStatus = status;

          final isMatching = matchTotal > 0;
          final matchFraction =
              isMatching ? matchDone / matchTotal : null;

          return AlertDialog(
            title: const Text('Refreshing EPG…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Indeterminate during download; determinate during matching
                matchFraction != null
                    ? LinearProgressIndicator(value: matchFraction)
                    : const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(
                  _refreshStatus,
                  style: Theme.of(sCtx).textTheme.bodySmall,
                ),
                // Download phase: show loaded program count
                if (programs > 0 && !isMatching)
                  Text(
                    '$programs programs loaded',
                    style: Theme.of(sCtx).textTheme.bodySmall,
                  ),
                // Matching phase: bold X / Y channel counter
                if (isMatching)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Channels matched: $matchDone / $matchTotal',
                      style: Theme.of(sCtx).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ).then((_) => dialogOpen = false);

    for (final source in sources) {
      if (!source.enabled) continue;
      final hasManualUrl = source.epgUrl?.isNotEmpty == true;
      final isXtream = source.sourceType == SourceType.xtream;
      if (!hasManualUrl && !isXtream) continue;

      final url = hasManualUrl ? source.epgUrl : null;
      matchDone = 0;
      matchTotal = 0;
      status = 'Preparing "${source.name}"…';
      _updateRefreshDialog(status);

      int sourceInserted = 0;
      int sourceMatchedChannels = 0;
      int sourceTotalChannels = 0;
      String? sourceError;
      try {
        await EpgService.refreshSource(
          source,
          epgUrl: url,
          onProgress: (p) {
            sourceInserted = p.programsInserted;
            programs = p.programsInserted;

            if (p.isMatching) {
              matchDone = p.matchingChannelsDone;
              matchTotal = p.matchingChannelsTotal;
              // Capture running totals for the summary line
              sourceMatchedChannels = p.matchingChannelsDone;
              sourceTotalChannels = p.matchingChannelsTotal;
              status = '${source.name}: matching channels…';
              _updateRefreshDialog(status);
            } else {
              status = p.statusMessage != null
                  ? '${source.name}: ${p.statusMessage}'
                  : '${source.name}: $programs programs…';
              _updateRefreshDialog(status);
            }
          },
        );
        if (sourceInserted == 0) {
          results.add(
            '⚠ ${source.name}: refresh completed but 0 programs loaded '
            '(check EPG URL, server response, or date window)',
          );
        } else {
          final matchSuffix = sourceTotalChannels > 0
              ? ' · $sourceMatchedChannels/$sourceTotalChannels channels matched'
              : '';
          results.add(
            '✓ ${source.name}: $sourceInserted programs$matchSuffix',
          );
        }
      } catch (e) {
        sourceError = e.toString();
        results.add('✗ ${source.name}: $sourceError');
      }
    }
  
    if (dialogOpen && ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();

    if (!ctx.mounted) return;
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('EPG Refresh Complete'),
        content: SingleChildScrollView(
          child: Text(results.isEmpty
              ? 'No sources had an EPG URL configured.'
              : results.join('\n')),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Force a full EPG re-match for all sources (forceRematch=true).
  /// Only runs the matching step — does NOT re-download the XMLTV feed.
  Future<void> _runEpgRematch(BuildContext ctx) async {
    String status = 'Starting…';
    int matchDone = 0;
    int matchTotal = 0;
    bool dialogOpen = true;

    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (sCtx, setSt) {
          _refreshSetState = setSt;
          final fraction = matchTotal > 0 ? matchDone / matchTotal : null;
          return AlertDialog(
            title: const Text('Re-matching channels…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                fraction != null
                    ? LinearProgressIndicator(value: fraction)
                    : const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(status,
                    style: Theme.of(sCtx).textTheme.bodySmall),
                if (matchTotal > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Channels matched: $matchDone / $matchTotal',
                      style: Theme.of(sCtx).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ).then((_) => dialogOpen = false);

    final results = <String>[];
    for (final source in sources) {
      if (!source.enabled) continue;
      final epgUrl = EpgService.resolveEpgUrl(source);
      if (epgUrl == null) continue;

      status = 'Re-matching "${source.name}"…';
      _updateRefreshDialog(status);
      matchDone = 0;
      matchTotal = 0;

      try {
        // Download fresh XMLTV to get the latest channelMap, then force-match.
        final channelMap = await EpgService.downloadAndParseEpg(
          source,
          epgUrl: epgUrl,
          onProgress: (p) {
            status = '${source.name}: ${p.statusMessage ?? "downloading…"}';
            _updateRefreshDialog(status);
          },
        );
        if (channelMap == null) {
          results.add('⚠ ${source.name}: failed to download EPG');
          continue;
        }
        await EpgService.matchChannels(
          source,
          channelMap,
          forceAll: true,
          onProgress: (p) {
            matchDone = p.matchingChannelsDone;
            matchTotal = p.matchingChannelsTotal;
            status = '${source.name}: matching…';
            _updateRefreshDialog(status);
          },
        );
        results.add('✓ ${source.name}: re-match complete'
            '${matchTotal > 0 ? " ($matchDone/$matchTotal)" : ""}');
      } catch (e) {
        results.add('✗ ${source.name}: $e');
      }
    }

    if (dialogOpen && ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
    if (!ctx.mounted) return;
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Re-match Complete'),
        content: SingleChildScrollView(
          child: Text(results.isEmpty
              ? 'No sources with EPG configured.'
              : results.join('\n')),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // Mutable state for the refresh progress dialog
  void Function(void Function())? _refreshSetState;
  String _refreshStatus = '';

  void _updateRefreshDialog(String status) {
    _refreshStatus = status;
    _refreshSetState?.call(() {});
  }

  Future<void> updateSettings() async {
    await Error.tryAsyncNoLoading(
      () async => await SettingsService.updateSettings(settings),
      context,
    );
  }

  /// Shared confirmation + apply flow for both reset actions.
  ///
  /// [builder] produces the fresh [Settings] instance.
  ///
  /// The following session-state fields are ALWAYS preserved across both
  /// actions because the user wouldn't expect a "reset" to clobber them:
  ///   - `debugLogging`
  ///   - `multiViewLayout`, `multiViewCells1x2`, `multiViewCells2x2`
  ///
  /// When [preserveLibraryPreferences] is true (used by the Optimise
  /// action), these additional fields are preserved because they are
  /// personal library preferences with no relationship to device tuning:
  ///   - `defaultView`, `refreshOnStart`, `forceTVMode`
  ///   - `showLivestreams`, `showMovies`, `showSeries`
  ///   - All EPG settings
  Future<void> _confirmAndResetSettings({
    required String title,
    required String body,
    required Settings Function() builder,
    bool preserveLibraryPreferences = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final fresh = builder()
      ..debugLogging = settings.debugLogging
      ..multiViewLayout = settings.multiViewLayout
      ..multiViewCells1x2 = settings.multiViewCells1x2
      ..multiViewCells2x2 = settings.multiViewCells2x2;

    if (preserveLibraryPreferences) {
      fresh
        ..defaultView = settings.defaultView
        ..refreshOnStart = settings.refreshOnStart
        ..forceTVMode = settings.forceTVMode
        ..showLivestreams = settings.showLivestreams
        ..showMovies = settings.showMovies
        ..showSeries = settings.showSeries
        ..epgAutoRefresh = settings.epgAutoRefresh
        ..epgRefreshHours = settings.epgRefreshHours
        ..epgRefreshHour = settings.epgRefreshHour
        ..epgPastDays = settings.epgPastDays
        ..epgForecastDays = settings.epgForecastDays;
    }

    setState(() => settings = fresh);
    await updateSettings();

    if (!mounted) return;
    AppLog.info('Settings: reset applied — $title');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Settings updated. Restart the app for buffer-size changes '
          'to take full effect.',
        ),
      ),
    );
  }

  // ─── Reusable helper widgets ──────────────────────────────────────────────

  /// A section header with the standard style.
  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(label, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  /// Small info icon button that opens [title] / [body] help dialog.
  Widget _helpIcon({
    required String title,
    required String body,
  }) {
    return IconButton(
      icon: Icon(
        Icons.info_outline,
        size: 18,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
      ),
      tooltip: 'About this setting',
      onPressed: () => SettingHelpDialog.show(context, title: title, body: body),
    );
  }

  /// A switch row where tapping the label also opens the help dialog.
  Widget _switchTile({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    required ({String title, String body}) help,
  }) {
    return ListTile(
      title: GestureDetector(
        onTap: () => SettingHelpDialog.show(
          context,
          title: help.title,
          body: help.body,
        ),
        child: Row(
          children: [
            Text(label),
            const SizedBox(width: 4),
            _helpIcon(title: help.title, body: help.body),
          ],
        ),
      ),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }

  /// A slider row where tapping the label also opens the help dialog.
  Widget _bufferSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required ({String title, String body}) help,
  }) {
    return ListTile(
      title: GestureDetector(
        onTap: () => SettingHelpDialog.show(
          context,
          title: help.title,
          body: help.body,
        ),
        child: Row(
          children: [
            Text(label),
            const SizedBox(width: 4),
            _helpIcon(title: help.title, body: help.body),
          ],
        ),
      ),
      subtitle: _DpadFriendlySlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: value.round().toString(),
        onChanged: onChanged,
      ),
      trailing: SizedBox(
        width: 56,
        child: Text(
          value.round().toString(),
          textAlign: TextAlign.right,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  /// A "popup menu" tile for the global engine selection setting.
  Widget _engineSelectionTile(Settings settings) {
    return ListTile(
      title: Row(
        children: [
          const Text('Player engine'),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(
              Icons.info_outline,
              size: 18,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.4),
            ),
            tooltip: 'About this setting',
            onPressed: () => SettingHelpDialog.show(
              context,
              title: 'Player Engine',
              body:
                  'Controls which media engine plays your streams.\n\n'
                  '"Auto (recommended)" picks automatically: HLS (.m3u8), DASH (.mpd) '
                  'and MP4 streams use ExoPlayer for better adaptive bitrate and battery '
                  'efficiency; everything else (MPEG-TS, RTMP) uses libmpv.\n\n'
                  '"libmpv" forces libmpv for all streams — best for MPEG-TS and RTMP '
                  'sources that ExoPlayer cannot handle.\n\n'
                  '"ExoPlayer" forces ExoPlayer — use only if Auto selects the wrong '
                  'engine for your source. Note: track selection (subtitles/audio) is '
                  'not available in ExoPlayer mode.',
            ),
          ),
        ],
      ),
      trailing: TextButton(
        onPressed: () => _showEnginePickerDialog(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _engineShortLabel(settings.forcedEngine),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  String _engineShortLabel(EngineType engine) => switch (engine) {
        EngineType.auto => 'Auto',
        EngineType.libmpv => 'libmpv',
        EngineType.exoplayer => 'ExoPlayer',
      };

  Future<void> _showEnginePickerDialog(BuildContext context) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return SelectDialog(
          title: 'Player engine',
          data: EngineType.values
              .map((e) => IdData(id: e.index, data: _engineShortLabel(e)))
              .toList(),
          action: (idx) {
            setState(() {
              settings.forcedEngine = EngineType.values[idx];
              updateSettings();
            });
            Navigator.of(context).pop();
          },
        );
      },
    );
  }

  Widget _multiViewTile(Settings settings) {
    return ListTile(
      title: Row(
        children: [
          const Text('Multi-view layout'),
          const SizedBox(width: 4),
          _helpIcon(
            title: 'Multi-view',
            body: 'Play multiple streams simultaneously in a split-screen '
                'grid.\n\n'
                '1×2 shows two streams side-by-side.\n'
                '2×2 shows four streams in a quad grid.\n\n'
                'Tap a cell to give it audio focus. Tap + to assign a '
                'channel to an empty cell. Double-tap to promote a cell to '
                'full-screen.\n\n'
                'Each stream uses its own decoder. On lower-end devices, '
                '2×2 may cause thermal throttling — start with 1×2.',
          ),
        ],
      ),
      trailing: TextButton(
        onPressed: () => _showMultiViewPickerDialog(settings),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _multiViewShortLabel(settings.multiViewLayout),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  String _multiViewShortLabel(MultiViewLayout layout) => switch (layout) {
        MultiViewLayout.none => 'Off',
        MultiViewLayout.oneByTwo => '1×2',
        MultiViewLayout.twoByTwo => '2×2',
      };

  void _showMultiViewPickerDialog(Settings settings) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => MultiViewPickerDialog(
        current: settings.multiViewLayout,
        onSelected: (layout) {
          setState(() => settings.multiViewLayout = layout);
          updateSettings();
        },
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Visibility(
        visible: !loading,
        child: Loading(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(vertical: 10),
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: ListView(
                children: [
                  const SizedBox(height: 10),
                  const Padding(
                    padding: EdgeInsets.only(left: 10),
                    child: Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ── Donate ──────────────────────────────────────────────
                  ListTile(
                    autofocus: true,
                    title: const Text("Donate"),
                    subtitle: const Text(
                      "Free4Me-IPTV is a fork of Fred TV. Support the original project ❤️",
                    ),
                    onTap: () async => await launchUrl(
                      Uri.parse(
                        "https://github.com/rkinnc75/Free4Me-IPTV/discussions",
                      ),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),

                  // ── Default view ─────────────────────────────────────────
                  ListTile(
                    title: GestureDetector(
                      onTap: () => SettingHelpDialog.show(
                        context,
                        title: _helpDefaultView.title,
                        body: _helpDefaultView.body,
                      ),
                      child: Row(
                        children: [
                          const Text("Default view"),
                          const SizedBox(width: 4),
                          _helpIcon(
                            title: _helpDefaultView.title,
                            body: _helpDefaultView.body,
                          ),
                        ],
                      ),
                    ),
                    subtitle: Text(viewTypeToString(settings.defaultView)),
                    onTap: () async => await _showDefaultViewDialog(context),
                  ),

                  // ── Force TV mode ────────────────────────────────────────
                  _switchTile(
                    label: "Force TV Mode",
                    value: settings.forceTVMode,
                    help: _helpForceTvMode,
                    onChanged: (v) {
                      setState(() => settings.forceTVMode = v);
                      updateSettings();
                    },
                  ),

                  // ── Low latency ──────────────────────────────────────────
                  _switchTile(
                    label: "Low latency livestreams",
                    value: settings.lowLatency,
                    help: _helpLowLatency,
                    onChanged: (v) {
                      setState(() => settings.lowLatency = v);
                      updateSettings();
                    },
                  ),

                  const Divider(),

                  // ── Buffering section ─────────────────────────────────────
                  _sectionHeader("Buffering (Android TV)"),

                  _bufferSlider(
                    label: "Livestream cache (seconds)",
                    value: settings.liveCacheSecs.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 55,
                    help: _helpLiveCacheSecs,
                    onChanged: (v) {
                      setState(() => settings.liveCacheSecs = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Livestream demuxer max (MB)",
                    value: settings.liveDemuxerMaxMB.toDouble(),
                    min: 32,
                    max: DeviceMemory.maxLiveDemuxerMb.toDouble(),
                    divisions:
                        ((DeviceMemory.maxLiveDemuxerMb - 32) / 8).round(),
                    help: _helpLiveDemuxerMB,
                    onChanged: (v) {
                      setState(() => settings.liveDemuxerMaxMB = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Mini-player demuxer cache (MB)",
                    value: settings.miniDemuxerMaxMB.toDouble(),
                    min: 8,
                    max: DeviceMemory.maxMiniDemuxerMb.toDouble(),
                    divisions:
                        ((DeviceMemory.maxMiniDemuxerMb - 8) / 8).round(),
                    help: (
                      title: 'Mini-Player Demuxer Buffer (MB)',
                      body:
                          'Maximum RAM the demuxer may use for the mini-player '
                          '/ overlay stream running alongside the full-screen '
                          'player.\n\n'
                          '↑ Raising — smoother mini-player playback on '
                          'high-bitrate streams. Reduces buffering oscillation '
                          'when both streams compete for bandwidth. Uses more '
                          'RAM — ensure full-screen + mini-player total stays '
                          'below ~60 % of device RAM.\n\n'
                          '↓ Lowering — frees RAM for the full-screen stream '
                          'and the OS. 16–32 MB is usually sufficient for '
                          '1080p IPTV. Reduce first if the app is killed by '
                          'the system.\n\n'
                          'Max is capped at 75 % of your device RAM ÷ 2. '
                          'Default: auto-detected '
                          '(${DeviceMemory.defaultMiniDemuxerMb} MB '
                          'on this ${DeviceMemory.totalMb} MB device). '
                          'Range: 8–${DeviceMemory.maxMiniDemuxerMb} MB.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.miniDemuxerMaxMB = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Player buffer size (MB)",
                    value: settings.bufferSizeMB.toDouble(),
                    min: 16,
                    max: DeviceMemory.maxBufferSizeMb.toDouble(),
                    divisions:
                        ((DeviceMemory.maxBufferSizeMb - 16) / 16).round(),
                    help: (
                      title: 'Player Buffer Size (MB)',
                      body:
                          'Internal libmpv read-ahead buffer allocated per '
                          'player instance at startup. The mini-player '
                          'automatically uses half this value.\n\n'
                          '↑ Raising — larger in-memory read buffer. Helps on '
                          'very high bitrate streams (4K HEVC above 25 Mbps). '
                          'Takes effect on the next app restart.\n\n'
                          '↓ Lowering — reduces per-instance RAM use. '
                          'Essential on devices with 2 GB or less RAM, '
                          'especially when the mini-player is active '
                          '(two instances = 2× this value). '
                          'Values below 32 MB may cause frequent stalls on '
                          '4K streams.\n\n'
                          'Max is capped at 75 % of your device RAM ÷ 2. '
                          'Requires app restart to take effect. '
                          'Default: auto-detected '
                          '(${DeviceMemory.defaultBufferSizeMb} MB '
                          'on this ${DeviceMemory.totalMb} MB device). '
                          'Range: 16–${DeviceMemory.maxBufferSizeMb} MB.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.bufferSizeMB = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "VOD/Movie cache (seconds)",
                    value: settings.vodCacheSecs.toDouble(),
                    min: 10,
                    max: 180,
                    divisions: 34,
                    help: _helpVodCacheSecs,
                    onChanged: (v) {
                      setState(() => settings.vodCacheSecs = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "VOD/Movie demuxer max (MB)",
                    value: settings.vodDemuxerMaxMB.toDouble(),
                    min: 64,
                    max: 1024,
                    divisions: 60,
                    help: _helpVodDemuxerMB,
                    onChanged: (v) {
                      setState(() => settings.vodDemuxerMaxMB = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Stream open timeout (seconds)",
                    value: settings.openTimeoutSecs.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 55,
                    help: _helpOpenTimeout,
                    onChanged: (v) {
                      setState(() => settings.openTimeoutSecs = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Buffering watchdog (seconds)",
                    value: settings.bufferingWatchdogSecs.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 55,
                    help: _helpWatchdog,
                    onChanged: (v) {
                      setState(
                        () => settings.bufferingWatchdogSecs = v.round(),
                      );
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Stable playback threshold (seconds)",
                    value: settings.stableThresholdSecs.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 55,
                    help: (
                      title: 'Stable Playback Threshold (seconds)',
                      body:
                          'How long a stream must play without any buffering '
                          'event before the reconnect retry counter resets to '
                          'zero.\n\n'
                          '↑ Raising — requires more sustained stability before '
                          'considering the stream "healthy". Keeps the retry '
                          'counter active longer after a shaky period, so the '
                          'app gives up sooner on persistently unstable '
                          'streams.\n\n'
                          '↓ Lowering — resets the counter sooner after a brief '
                          'blip, allowing more retries on streams that recover '
                          'quickly. Reduce if good streams are hitting '
                          'max-reconnect and giving up prematurely.\n\n'
                          'Default: 30 s. Range: 5–60 s.',
                    ),
                    onChanged: (v) {
                      setState(
                        () => settings.stableThresholdSecs = v.round(),
                      );
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Startup grace window (ms)",
                    value: settings.startupGraceMs.toDouble(),
                    min: 100,
                    max: 3000,
                    divisions: 29,
                    help: (
                      title: 'Startup Grace Window (ms)',
                      body:
                          'How long after buffering begins to suppress mpv '
                          'errors that could otherwise cause an immediate '
                          'false reconnect on every channel open.\n\n'
                          'Note: as of the current version, seek errors are '
                          'suppressed unconditionally (not just during the '
                          'grace window), so this setting primarily affects '
                          'other false-positive errors that may fire during '
                          'stream initialisation.\n\n'
                          '↑ Raising — catches errors that arrive later during '
                          'startup. Increase to 1000–1500 ms on slower TV '
                          'hardware (Onn 4K, older Fire TV Stick) if streams '
                          'still double-start.\n\n'
                          '↓ Lowering — allows genuine errors to surface and '
                          'trigger a reconnect sooner after stream open. '
                          'Default: 500 ms. Range: 100–3000 ms.',
                    ),
                    onChanged: (v) {
                      setState(
                        () => settings.startupGraceMs = v.round(),
                      );
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Stream-ended reconnect delay (ms)",
                    value: settings.streamCompletedDelayMs.toDouble(),
                    min: 0,
                    max: 10000,
                    divisions: 20,
                    help: (
                      title: 'Stream-Ended Reconnect Delay (ms)',
                      body:
                          'How long to wait before reconnecting when the '
                          'stream signals it has ended (TCP connection closed '
                          'by provider).\n\n'
                          'IPTV providers sometimes briefly close the TCP '
                          'connection at segment boundaries or during '
                          'load-balancer rotation — the stream is not actually '
                          'dead, just rotating. A short wait lets the provider '
                          're-establish without triggering a full reconnect.\n\n'
                          '↑ Raising — gives the provider more time to '
                          're-establish. Reduces unnecessary reconnects on '
                          'providers that frequently rotate connections. Values '
                          'above 5000 ms may cause a visible freeze.\n\n'
                          '↓ Lowering — reconnects faster when the stream '
                          'genuinely ends. Set to 0 to reconnect immediately '
                          '(original behaviour).\n\n'
                          'Default: 2000 ms (2 seconds). Range: 0–10 000 ms.',
                    ),
                    onChanged: (v) {
                      setState(
                        () => settings.streamCompletedDelayMs = v.round(),
                      );
                      updateSettings();
                    },
                  ),

                  // ── Stream scanner (radar) ────────────────────────────────
                  _sectionHeader("Stream Scanner"),
                  _bufferSlider(
                    label: "Streams per scan",
                    value: settings.streamScanMaxCount.toDouble(),
                    min: 1,
                    max: 100,
                    divisions: 99,
                    help: (
                      title: 'Streams Per Scan',
                      body:
                          'Maximum number of visible channels the radar button '
                          'probes in a single scan run.\n\n'
                          '↑ Raising — tests more channels per run. Scan time '
                          'increases proportionally '
                          '(count × timeout per stream). '
                          '100 streams at 8 s timeout = up to ~13 minutes '
                          'worst-case.\n\n'
                          '↓ Lowering — faster scan. The scanner always tests '
                          'channels in the order they appear on screen, so '
                          'put your favourites first.\n\n'
                          'Green border = valid MPEG-TS or HLS confirmed. '
                          'Default: 20. Range: 1–100.',
                    ),
                    onChanged: (v) {
                      setState(
                        () => settings.streamScanMaxCount = v.round(),
                      );
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Scan timeout (sec)",
                    value: settings.streamScanTimeoutSecs.toDouble(),
                    min: 3,
                    max: 30,
                    divisions: 27,
                    help: (
                      title: 'Scan Timeout (seconds)',
                      body:
                          'How long the scanner waits per stream to receive '
                          'and validate the first media bytes (MPEG-TS sync '
                          'bytes at 0, 188, 376; or "#EXTM3U" for HLS).\n\n'
                          '↑ Raising — gives slow CDNs and geographically '
                          'distant servers more time to respond. Reduces false '
                          'negatives. Increases total scan time '
                          'proportionally.\n\n'
                          '↓ Lowering — faster scans. May produce false '
                          'negatives on slow or international streams.\n\n'
                          '8 s covers most IPTV providers. Only increase if '
                          'you see streams your player can open but the scanner '
                          'marks as failed. Default: 8 s. Range: 3–30 s.',
                    ),
                    onChanged: (v) {
                      setState(
                        () => settings.streamScanTimeoutSecs = v.round(),
                      );
                      updateSettings();
                    },
                  ),

                  // ── Hardware decode / pre-warm / engine ───────────────────
                  _switchTile(
                    label: "Hardware decoding",
                    value: settings.hwDecode,
                    help: _helpHwDecode,
                    onChanged: (v) {
                      setState(() => settings.hwDecode = v);
                      updateSettings();
                    },
                  ),
                  _switchTile(
                    label: "Pre-warm streams on focus",
                    value: settings.preWarmOnFocus,
                    help: _helpPreWarm,
                    onChanged: (v) {
                      setState(() => settings.preWarmOnFocus = v);
                      updateSettings();
                    },
                  ),
                  _engineSelectionTile(settings),
                  _multiViewTile(settings),

                  const Divider(),

                  // ── Content visibility ────────────────────────────────────
                  _switchTile(
                    label: "Refresh sources on start",
                    value: settings.refreshOnStart,
                    help: _helpRefreshOnStart,
                    onChanged: (v) {
                      setState(() => settings.refreshOnStart = v);
                      updateSettings();
                    },
                  ),
                  _switchTile(
                    label: "Show livestreams",
                    value: settings.showLivestreams,
                    help: _helpShowLivestreams,
                    onChanged: (v) {
                      setState(() => settings.showLivestreams = v);
                      updateSettings();
                    },
                  ),
                  _switchTile(
                    label: "Show movies",
                    value: settings.showMovies,
                    help: _helpShowMovies,
                    onChanged: (v) {
                      setState(() => settings.showMovies = v);
                      updateSettings();
                    },
                  ),
                  _switchTile(
                    label: "Show series",
                    value: settings.showSeries,
                    help: _helpShowSeries,
                    onChanged: (v) {
                      setState(() => settings.showSeries = v);
                      updateSettings();
                    },
                  ),

                  const Divider(),

                  // ── EPG ───────────────────────────────────────────────────
                  _sectionHeader("EPG / Program Guide"),
                  ...sources.map(
                    (source) => ListTile(
                      leading: Icon(
                        source.epgUrl?.isNotEmpty == true
                            ? Icons.check_circle_outline
                            : Icons.tv_outlined,
                        color: source.epgUrl?.isNotEmpty == true
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text('EPG for "${source.name}"'),
                      subtitle: Text(
                        source.epgUrl?.isNotEmpty == true
                            ? source.epgUrl!
                            : 'Tap to set — default US guide pre-filled',
                      ),
                      onTap: () async {
                        // Pre-fill with current URL or the benchmark default
                        // so the user can accept it with one tap.
                        final initialText = source.epgUrl?.isNotEmpty == true
                            ? source.epgUrl!
                            : 'https://iptv-epg.org/files/epg-us.xml';
                        final controller = TextEditingController(
                          text: initialText,
                        );
                        // Select all text so the user can immediately replace
                        controller.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: controller.text.length,
                        );
                        final result = await showDialog<String?>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text('EPG URL for "${source.name}"'),
                            content: DpadTextField(
                              controller: controller,
                              decoration: const InputDecoration(
                                labelText: 'XMLTV feed URL',
                              ),
                              keyboardType: TextInputType.url,
                              autofocus: true,
                              // Enter/OK on D-pad saves immediately
                              onSubmitted: (text) =>
                                  Navigator.pop(ctx, text.trim()),
                            ),
                            // Save first so one D-pad-down from the field
                            // lands on Save, not Cancel.
                            actions: [
                              FilledButton(
                                onPressed: () => Navigator.pop(
                                  ctx,
                                  controller.text.trim(),
                                ),
                                child: const Text('Save'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(ctx, ''),
                                child: const Text('Clear'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, null),
                                child: const Text('Cancel'),
                              ),
                            ],
                          ),
                        );
                        if (result != null && source.id != null) {
                          await Sql.setSourceEpgUrl(
                            source.id!,
                            result.isEmpty ? null : result,
                          );
                          await initAsync();
                        }
                      },
                    ),
                  ),
                  _switchTile(
                    label: "Auto-refresh EPG",
                    value: settings.epgAutoRefresh,
                    help: (
                      title: 'Auto-refresh EPG',
                      body:
                          'Automatically downloads updated program guide data '
                          'in the background at the scheduled hour.\n\n'
                          '↑ ON — program guide stays current without manual '
                          'action. Uses data and battery during the refresh '
                          'window.\n\n'
                          '↓ OFF — EPG only updates when you tap "Refresh EPG" '
                          'manually. Useful on metered connections or if your '
                          'EPG source rarely changes. Default: ON.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgAutoRefresh = v);
                      updateSettings();
                      EpgService.scheduleBackgroundRefresh();
                    },
                  ),
                  _bufferSlider(
                    label: "Refresh every (hours)",
                    value: settings.epgRefreshHours.toDouble(),
                    min: 6,
                    max: 168,
                    divisions: 162,
                    help: (
                      title: 'EPG Refresh Interval (hours)',
                      body:
                          'How often the background EPG refresh runs.\n\n'
                          '↑ Raising — less frequent downloads. Reduces data '
                          'and battery use. EPG data may become stale.\n\n'
                          '↓ Lowering — more frequent downloads. Guide stays '
                          'current. Each refresh downloads and re-parses the '
                          'full XMLTV file — avoid values below 12 h on '
                          'metered or slow connections.\n\n'
                          'Note: only unmatched channels are re-matched on '
                          'each refresh — already-matched channels are skipped '
                          'keeping refresh fast. '
                          'Default: 24 h. Range: 6–168 h (7 days).',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgRefreshHours = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Refresh hour (local, 24h)",
                    value: settings.epgRefreshHour.toDouble(),
                    min: 0,
                    max: 23,
                    divisions: 23,
                    help: (
                      title: 'EPG Refresh Hour',
                      body:
                          'The hour of the day (local time, 24-hour clock) '
                          'when the background EPG refresh runs.\n\n'
                          'Choose a time when the device is plugged in and on '
                          'Wi-Fi — EPG parsing is CPU-intensive (up to 2 min '
                          'on slower boxes). 3:00 AM is the default as most '
                          'devices are idle then. '
                          'Default: 3 (03:00). Range: 0–23.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgRefreshHour = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Past days to keep",
                    value: settings.epgPastDays.toDouble(),
                    min: 0,
                    max: 3,
                    divisions: 3,
                    help: (
                      title: 'EPG Past Days',
                      body:
                          'How many days of already-aired program data to '
                          'retain.\n\n'
                          '↑ Raising — lets you see what aired recently in '
                          'the guide. Uses more storage.\n\n'
                          '↓ Lowering / 0 — keeps only current and future '
                          'programs. Reduces storage and speeds up parsing. '
                          'Set to 0 on low-storage devices. '
                          'Default: 1. Range: 0–3.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgPastDays = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Forecast days",
                    value: settings.epgForecastDays.toDouble(),
                    min: 3,
                    max: 14,
                    divisions: 11,
                    help: (
                      title: 'EPG Forecast Days',
                      body:
                          'How many days ahead of program guide data to '
                          'download.\n\n'
                          '↑ Raising — more advance schedule visibility. '
                          'Increases download size and parse time '
                          'proportionally (each extra day ≈ +70 k programs '
                          'for large guides).\n\n'
                          '↓ Lowering — faster EPG refresh, less storage. '
                          '3 days is sufficient if you only use the guide for '
                          '"what\'s on now/next". '
                          'Default: 7. Range: 3–14.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgForecastDays = v.round());
                      updateSettings();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text("Refresh EPG now"),
                    subtitle: const Text("Download latest program guide"),
                    onTap: () async {
                      final noUrls = sources.every(
                        (s) =>
                            (s.epgUrl?.isEmpty ?? true) &&
                            s.sourceType != SourceType.xtream,
                      );
                      if (noUrls) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'No EPG URL configured. Tap the EPG row for '
                              'your source and save a URL first.',
                            ),
                            duration: Duration(seconds: 5),
                          ),
                        );
                        return;
                      }
                      await _runEpgRefresh(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.manage_search),
                    title: const Text("Re-match all channels"),
                    subtitle: const Text(
                      "Force full EPG re-match — use after feed or "
                      "matcher changes",
                    ),
                    onTap: () async {
                      await _runEpgRematch(context);
                    },
                  ),
                  ...sources
                      .where((s) => s.id != null)
                      .map(
                        (source) => ListTile(
                          leading: const Icon(Icons.tune),
                          title: Text(
                            'Channel mappings — ${source.name}',
                          ),
                          subtitle: const Text(
                            'Manually assign EPG IDs to unmatched channels',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => EpgChannelMappingView(
                                source: source,
                              ),
                            ),
                          ),
                        ),
                      ),

                  const Divider(),

                  // ── Diagnostics ───────────────────────────────────────────
                  _sectionHeader("Diagnostics"),
                  _switchTile(
                    label: "Enable debug logging",
                    value: settings.debugLogging,
                    help: (
                      title: 'Debug Logging',
                      body:
                          'Writes a timestamped log of every significant action '
                          '(EPG refresh, source reload, errors, settings changes) '
                          'to a file in app storage. Turn ON only when '
                          'troubleshooting — leaves a file you can export and '
                          'share. Auto-rotates at 2 MB. Default: OFF.',
                    ),
                    onChanged: (v) async {
                      setState(() => settings.debugLogging = v);
                      await AppLog.setEnabled(v);
                      AppLog.info('Debug logging ${v ? "enabled" : "disabled"}');
                      updateSettings();
                    },
                  ),
                  ListTile(
                    enabled: settings.debugLogging,
                    leading: const Icon(Icons.download_outlined),
                    title: const Text("Export log file"),
                    subtitle: const Text(
                      "Save the debug log to a file you can share",
                    ),
                    onTap: settings.debugLogging
                        ? () async {
                            final log = await AppLog.readLog();
                            if (!mounted) return;
                            if (log.isEmpty) {
                              // ignore: use_build_context_synchronously
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Log file is empty.'),
                                ),
                              );
                              return;
                            }
                            await SettingsIo.exportStringToFile(
                              // ignore: use_build_context_synchronously
                              context,
                              content: log,
                              suggestedName:
                                  'free4me_log_${DateTime.now().millisecondsSinceEpoch}.txt',
                            );
                          }
                        : null,
                  ),
                  ListTile(
                    enabled: settings.debugLogging,
                    leading: const Icon(Icons.delete_outline),
                    title: const Text("Clear log"),
                    onTap: settings.debugLogging
                        ? () async {
                            await AppLog.clearLog();
                            if (!mounted) return;
                            // ignore: use_build_context_synchronously
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Log cleared.'),
                              ),
                            );
                          }
                        : null,
                  ),

                  const Divider(),

                  // ── Backup & Restore ──────────────────────────────────────
                  _sectionHeader("Backup & Restore"),
                  ListTile(
                    leading: const Icon(Icons.upload_file),
                    title: const Text("Export settings to file"),
                    subtitle: const Text(
                      "Save sources and settings as a JSON backup",
                    ),
                    onTap: () async {
                      final includeCredentials = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Include credentials?'),
                          content: const Text(
                            'Include Xtream usernames and passwords in the backup?\n\n'
                            'Only choose YES if you are saving the file somewhere secure.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('No (safer)'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Yes'),
                            ),
                          ],
                        ),
                      );
                      if (includeCredentials == null || !mounted) return;
                      await SettingsIo.exportToFile(
                        // ignore: use_build_context_synchronously
                        context,
                        includeCredentials: includeCredentials,
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.download_for_offline),
                    title: const Text("Import settings from file"),
                    subtitle: const Text(
                      "Restore sources and settings from a backup",
                    ),
                    onTap: () async {
                      await SettingsIo.importFromFile(context);
                      await initAsync(); // Reload UI after import
                    },
                  ),

                  const Divider(),

                  // ── Reset ─────────────────────────────────────────────────
                  _sectionHeader("Reset"),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text("Reset settings to defaults"),
                    subtitle: const Text(
                      "Restore the hardcoded defaults. Preserves sources, "
                      "debug-logging toggle, and any active multi-view "
                      "channel layout.",
                    ),
                    onTap: () => _confirmAndResetSettings(
                      title: 'Reset to defaults?',
                      body: 'This restores every tunable setting to its '
                          'hardcoded default. Your sources, credentials, '
                          'debug-logging toggle, and multi-view channel '
                          'assignments are preserved.\n\n'
                          'Some changes (buffer size) take effect on the '
                          'next app launch.',
                      builder: () => Settings.defaults(),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.auto_fix_high),
                    title: const Text("Optimise for this device"),
                    subtitle: const Text(
                      "Calculate the best values for your device's RAM, "
                      "form factor, and current multi-view layout.",
                    ),
                    onTap: () async {
                      final isTV = await DeviceDetector.isTV();
                      if (!mounted) return;
                      _confirmAndResetSettings(
                        title: 'Optimise for this device?',
                        body: 'This computes recommended values for your '
                            'device based on:\n\n'
                            '  • Detected RAM: ${DeviceMemory.totalMb} MB\n'
                            '  • Form factor: ${isTV ? "TV" : "phone/tablet"}\n'
                            '  • Multi-view layout: '
                            '${settings.multiViewLayout.label}\n\n'
                            'Only buffer / cache / timing / decoder '
                            'settings change. Your library view, EPG, '
                            'show/hide preferences, sources, credentials, '
                            'debug-logging toggle, and multi-view channel '
                            'assignments are all preserved.\n\n'
                            'Some changes (buffer size) take effect on '
                            'the next app launch.',
                        builder: () => Settings.optimisedFor(
                          isTV: isTV,
                          layout: settings.multiViewLayout,
                        ),
                        preserveLibraryPreferences: true,
                      );
                    },
                  ),

                  const Divider(),

                  // ── App ───────────────────────────────────────────────────
                  _sectionHeader("App"),
                  ListTile(
                    leading: const Icon(Icons.system_update_outlined),
                    title: const Text("Check for updates"),
                    subtitle: const Text("Check for a newer version of the app"),
                    onTap: () async {
                      // checkNow bypasses the throttle and shows
                      // "up to date" feedback, unlike checkOnLaunch.
                      await UpdateChecker.checkNow(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('App version'),
                    subtitle: Text(_appVersion.isEmpty ? '…' : _appVersion),
                    onTap: _appVersion.isEmpty
                        ? null
                        : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const FullChangelogPage(),
                              ),
                            ),
                    trailing: _appVersion.isEmpty
                        ? null
                        : const Icon(Icons.chevron_right),
                  ),

                  const Divider(),

                  // ── Sources section ───────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 10),
                        child: Text(
                          'Sources',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            onPressed: () async => await Error.tryAsync(
                              () async => await Utils.refreshAllSources(),
                              context,
                              "Successfully refreshed all sources",
                            ),
                            icon: const Icon(Icons.refresh),
                          ),
                          IconButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const Setup(showAppBar: true),
                              ),
                            ),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...sources.map(getSource),
                ],
              ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: widget.showNavBar
          ? BottomNav(
              updateViewMode: updateView,
              startingView: ViewType.settings,
            )
          : null,
    );
  }
}

/// A [Slider] that does not consume D-pad up/down key events.
///
/// Flutter's stock [Slider] treats up/down arrow keys the same as right/left
/// (nudging the value), which on Android TV traps focus on the first slider
/// in a list — the user cannot move past it. This wrapper handles
/// left/right itself (so the value can still be adjusted) but returns
/// [KeyEventResult.ignored] for up/down, allowing the parent
/// [FocusTraversalGroup] / [ListView] to move focus to the next row.
class _DpadFriendlySlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  const _DpadFriendlySlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  @override
  State<_DpadFriendlySlider> createState() => _DpadFriendlySliderState();
}

class _DpadFriendlySliderState extends State<_DpadFriendlySlider> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'DpadSlider');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  double get _step =>
      (widget.max - widget.min) / widget.divisions;

  void _nudge(double delta) {
    final next = (widget.value + delta).clamp(widget.min, widget.max);
    if (next != widget.value) widget.onChanged(next);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    // Let up/down propagate so the ListView can move focus.
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _nudge(-_step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _nudge(_step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
      child: Slider(
        value: widget.value.clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        label: widget.label,
        // Do not let the stock Slider grab keyboard focus — our outer
        // Focus node receives keys and forwards left/right manually.
        focusNode: FocusNode(skipTraversal: true, canRequestFocus: false),
        onChanged: widget.onChanged,
      ),
    );
  }
}
