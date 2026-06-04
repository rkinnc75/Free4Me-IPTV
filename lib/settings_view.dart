import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:io';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/export_server.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:open_tv/backend/playback_analyzer.dart';
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
import 'package:open_tv/source_color_picker.dart';
import 'package:open_tv/backend/stream_scanner.dart';
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
import 'package:open_tv/widgets/sources_refresh_dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _helpDefaultView = (
  title: 'Default View',
  body:
      'Chooses the content view the app opens to at launch.\n\n'
      'Default: All.\n\n'
      'All shows every enabled content type together. Livestreams opens '
      'directly to live TV. Movies and Series open directly to those '
      'libraries.\n\n'
      'Use the view you open most often to save a navigation step every '
      'time the app starts. This does not hide or delete content; it only '
      'changes the first screen you see.',
);

const _helpForceTvMode = (
  title: 'Force TV Mode',
  body:
      'Forces the TV-style interface even if the device is detected as a '
      'phone or tablet.\n\n'
      'Default: OFF.\n\n'
      'ON: Uses larger TV-focused controls and D-pad navigation. Turn this '
      'on if an Android TV box, Onn 4K, Fire TV, or similar device is '
      'detected as a touch device.\n\n'
      'OFF: Lets the app choose the layout automatically. Best for phones '
      'and tablets where touch controls are easier to use.',
);

const _helpLowLatency = (
  title: 'Low Latency (Live TV)',
  body:
      'Reduces the delay between the live broadcast and what you see on '
      'screen.\n\n'
      'Default: OFF.\n\n'
      'ON: Requests the lowest-latency HLS behavior and reduces buffering. '
      'Useful for live sports or events where being several seconds behind '
      'matters. May reduce picture quality and can make unstable streams '
      'buffer more often.\n\n'
      'OFF: Uses normal buffering for smoother playback and better quality '
      'selection on stable connections. Recommended for most users.\n\n'
      'This mainly affects HLS streams. Non-HLS streams (MPEG-TS, RTMP) '
      'may not benefit.',
);

const _helpRefreshOnStart = (
  title: 'Refresh Sources on Start',
  body:
      'Refreshes your channel lists automatically every time the app '
      'opens.\n\n'
      'Default: OFF.\n\n'
      'ON: Downloads the latest M3U and Xtream data at startup. Use this '
      'if your provider changes channels or stream URLs often. Startup '
      'takes longer and uses network data every launch.\n\n'
      'OFF: Starts faster using the saved channel list. You can still '
      'refresh manually from the Sources section whenever you want fresh '
      'data.',
);

const _helpShowLivestreams = (
  title: 'Show Livestreams',
  body:
      'Controls whether live TV channels appear in browsing and search.\n\n'
      'Default: ON.\n\n'
      'ON: Live TV appears in All, Livestreams, search results, and the '
      'multi-view channel picker.\n\n'
      'OFF: Hides live TV from normal browsing and search. Nothing is '
      'deleted; turn it back on to show live channels again.\n\n'
      'At least one content type must stay enabled.',
);

const _helpShowMovies = (
  title: 'Show Movies',
  body:
      'Controls whether on-demand movies appear in browsing and search.\n\n'
      'Default: ON.\n\n'
      'ON: Movies appear in All, Movies, and search results.\n\n'
      'OFF: Hides the movie library from normal browsing and search. '
      'Nothing is deleted; turn it back on to show movies again.\n\n'
      'At least one content type must stay enabled.',
);

const _helpShowSeries = (
  title: 'Show Series',
  body:
      'Controls whether series and episodes appear in browsing and '
      'search.\n\n'
      'Default: ON.\n\n'
      'ON: Series appear in All, Series, and search results.\n\n'
      'OFF: Hides series content from normal browsing and search. Nothing '
      'is deleted; turn it back on to show series again.\n\n'
      'At least one content type must stay enabled.',
);

const _helpSafeMode = (
  title: 'Safe Mode',
  body:
      'Hides channels and categories whose name or group contains '
      'adult-content keywords.\n\n'
      'Default: OFF.\n\n'
      'ON: Adult-labeled channels are hidden from browsing, categories, '
      'search results, and picker screens. The filter is applied '
      'immediately.\n\n'
      'OFF: Shows all channels from your enabled sources.\n\n'
      'Safe Mode uses a keyword blocklist (e.g. xxx, 18+, erotic, porn, '
      'x-rated). It is a practical filter, not a parental-control '
      'guarantee.',
);

const _helpHwDecode = (
  title: 'Hardware Decoding',
  body:
      'Uses the device video decoder instead of relying only on the CPU.\n\n'
      'Default: ON.\n\n'
      'ON: Usually gives smoother playback, lower CPU use, less heat, and '
      'better battery life. Recommended for most devices, especially 4K or '
      'HEVC streams. Android TV and Nvidia Shield automatically use a safer '
      'copy mode where needed.\n\n'
      'OFF: Uses software decoding. Turn this off only if hardware decoding '
      'causes black video, green video, corruption, or device-specific '
      'playback problems.',
);

const _helpPreWarm = (
  title: 'Pre-warm Streams on Focus',
  body:
      'Starts resolving a stream URL when a channel tile receives focus, '
      'before you press play.\n\n'
      'Default: ON.\n\n'
      'ON: Channels often start faster because redirects and basic network '
      'setup have already happened. Best for TV remotes where focus moves '
      'deliberately.\n\n'
      'OFF: Does no background stream checks while browsing. Uses less '
      'network activity and can be better on metered or slow connections. '
      'Playback may take slightly longer to begin.',
);

const _helpLiveCacheSecs = (
  title: 'Livestream Cache (seconds)',
  body:
      'Controls how many seconds of live TV playback are buffered ahead.\n\n'
      'Default: 20 s. Range: 5–60 s.\n\n'
      'Increasing: Gives the player more cushion on unstable connections '
      'and can reduce buffering. Uses more RAM and increases live delay. '
      'Very high values can make slow streams feel less live.\n\n'
      'Decreasing: Uses less RAM and reduces live delay. May buffer more '
      'often on weak Wi-Fi or unreliable providers.\n\n'
      'Interacts with:\n'
      '• Low Latency mode — reduces or bypasses this buffer for a more '
      'live feed at the cost of stability.\n'
      '• Livestream Demuxer Buffer — the cache lives inside the demuxer '
      'buffer; a large cache needs enough demuxer MB to hold it.',
);

const _helpLiveDemuxerMB = (
  title: 'Livestream Demuxer Buffer (MB)',
  body:
      'Sets the maximum RAM the stream demuxer can use while playing live '
      'TV.\n\n'
      'Default: calculated from device RAM. Range: 32–512 MB.\n\n'
      'Increasing: Helps high-bitrate, 4K, HEVC, or unstable live streams '
      'keep enough data ready for decoding. May reduce stutter, but uses '
      'more RAM.\n\n'
      'Decreasing: Frees RAM for the system and other players. Lower this '
      'first on 1–2 GB TV boxes if the app closes in the background or '
      'during multi-player use.\n\n'
      'Interacts with:\n'
      '• Livestream Cache — the cache must fit inside this buffer; raise '
      'this if you raise the cache.\n'
      '• Multi-view — each cell allocates its own (smaller) demuxer '
      'buffer, so total RAM use scales with the number of cells.\n\n'
      'The maximum is capped from detected RAM to avoid unsafe values.',
);

const _helpVodCacheSecs = (
  title: 'VOD/Movie Cache (seconds)',
  body:
      'Controls how many seconds of movies or series are buffered ahead.\n\n'
      'Default: 60 s. Range: 10–180 s.\n\n'
      'Increasing: Helps long movies, large files, and slow servers play '
      'more smoothly. Can also make seeking feel better. Uses more RAM and '
      'may take longer to fill after a seek.\n\n'
      'Decreasing: Uses less RAM and may respond faster after jumps, but '
      'can buffer more often on slow VOD servers.\n\n'
      'Interacts with:\n'
      '• VOD/Movie Demuxer Buffer — the cache lives inside that buffer; '
      'a large cache needs enough demuxer MB.\n\n'
      'Does not affect live TV streams.',
);

const _helpVodDemuxerMB = (
  title: 'VOD/Movie Demuxer Buffer (MB)',
  body:
      'Sets the maximum RAM the demuxer can use for movies and series '
      'episodes.\n\n'
      'Default: 256 MB. Range: 64–1024 MB.\n\n'
      'Increasing: Helps high-bitrate VOD, 4K movies, and large files play '
      'and seek more smoothly. Uses more RAM.\n\n'
      'Decreasing: Frees RAM for the system and other streams. Most 1080p '
      'VOD works well around 64–128 MB, while large 4K files may need '
      'more.\n\n'
      'Interacts with:\n'
      '• VOD/Movie Cache — the cache must fit inside this buffer; raise '
      'this if you raise the cache.\n\n'
      'Does not affect live TV streams.',
);

const _helpOpenTimeout = (
  title: 'Stream Open Timeout (seconds)',
  body:
      'How long the app waits for the open() call to start a stream '
      'before counting that attempt as a failure.\n\n'
      'Default: 5 s. Range: 5–60 s.\n\n'
      '↑ Increasing — gives slow or distant servers more time to '
      'respond before failing. Fewer false failures, but you wait '
      'longer before a retry or give-up.\n\n'
      '↓ Decreasing — fails faster on dead servers.\n\n'
      'Interacts with:\n'
      '• Max Reconnect Attempts — each open failure counts toward that '
      'limit. With a low timeout and a low attempt limit, a dead stream '
      'gives up very quickly.\n'
      '• Buffering Watchdog — the open timeout only covers the open() '
      'call. Once a stream opens but then stalls without a picture, the '
      'Buffering Watchdog (not this setting) catches it.',
);

const _helpMaxReconnectAttempts = (
  title: 'Max Reconnect Attempts',
  body:
      'How many times the app tries a stream before giving up. This is '
      'the single limit for ALL failure types: a stream that won\'t '
      'open, one that opens then drops, and one that opens but never '
      'shows a picture.\n\n'
      'Default: 3. Range: 1–10.\n\n'
      'Applies to both full-screen playback and multi-view cells.\n\n'
      'Full-screen: when the limit is reached the player returns to the '
      'channel list and shows a message.\n'
      'Multi-view: when the limit is reached the cell shows "Stream '
      'unavailable" with a manual Retry button.\n\n'
      '↑ Increasing — gives flaky streams more chances to recover. '
      'Useful for providers that drop briefly then come back.\n\n'
      '↓ Decreasing — fails faster on dead streams. Set to 1 for '
      'immediate give-up with no retry; 2–3 for a couple of chances.\n\n'
      'Interacts with:\n'
      '• Stream Open Timeout — each attempt can wait up to this long for '
      'open() to respond.\n'
      '• Buffering Watchdog — each attempt can wait up to this long for '
      'a stalled stream to recover before counting as a failed attempt.\n'
      '• Total wait before give-up ≈ attempts × (open timeout or '
      'watchdog, whichever applies). Example: 3 attempts × 10 s '
      'watchdog ≈ 30 s worst case on a dead stream.',
);

const _helpWatchdog = (
  title: 'Buffering Watchdog (seconds)',
  body:
      'How long a live stream may stay frozen — buffering, or opened but '
      'showing no picture — before the app counts it as a failed attempt '
      'and reconnects or gives up.\n\n'
      'Default: 12 s. Range: 5–60 s.\n\n'
      '↑ Increasing — gives a stuck stream more time to recover on its '
      'own. Fewer needless reconnects on brief pauses, but longer waits '
      'when a stream is truly stuck.\n\n'
      '↓ Decreasing — reacts faster when playback freezes. Quicker '
      'recovery, but may reconnect during short network dips.\n\n'
      'Interacts with:\n'
      '• Max Reconnect Attempts — every time this watchdog fires it uses '
      'one attempt. Total give-up time ≈ attempts × this value on a '
      'stuck stream.\n'
      '• Startup Grace — during the brief grace window right after open, '
      'the watchdog uses a longer timeout so a slow but real start is '
      'not killed early.\n'
      '• It also covers the "opened but never produced a frame" case '
      '(a dead stream that returns success then sends nothing).\n\n'
      'In mini-player or multi-view, each active stream has its own '
      'watchdog.',
);


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
    // fix182: land D-pad focus on the first settings row when the
    // screen opens (ExpansionTile has no autofocus; nextFocus() on a
    // scope with no focused child moves to the first focusable).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).nextFocus();
    });
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
          // fix196: tap the monitor icon to pick a per-source tag color.
          leading: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () async {
              final result =
                  await showSourceColorPicker(context, current: source.color);
              if (result == null) return;
              source.color = result.color;
              await Sql.updateSource(source);
              await reloadSources();
            },
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (source.color != null)
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Color(source.color!),
                      shape: BoxShape.circle,
                    ),
                  ),
                Icon(source.enabled ? Icons.tv : Icons.tv_off),
              ],
            ),
          ),
          horizontalTitleGap: 25,
          contentPadding: const EdgeInsets.only(left: 20),
          title: Text(source.name),
          // fix192: show the auto-detected provider connection limit (read-only)
          // alongside the source type. Hidden when unknown (null).
          subtitle: Text(
            source.maxConnections == null
                ? source.sourceType.label
                : '${source.sourceType.label} · '
                    '${source.maxConnections} '
                    '${source.maxConnections == 1 ? "connection" : "connections"}',
          ),
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
                    await _refreshSingleSource(source);
                    if (mounted) await reloadSources();
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

  /// Refresh a single Xtream source with a live progress dialog.
  /// Uses the Completer pattern so the async callback can drive the
  /// StatefulBuilder dialog — same approach as showSourcesRefreshDialog.
  Future<void> _refreshSingleSource(Source source) async {
    AppLog.info('Settings: refresh single source "${source.name}"');

    String status = 'Connecting…';
    bool done = false;
    String? errorMsg;

    final dialogReady = Completer<void>();
    late void Function(void Function()) setSt;

    final dialogClosed = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (sCtx, s) {
          setSt = s;
          if (!dialogReady.isCompleted) dialogReady.complete();
          return PopScope(
            canPop: done,
            child: AlertDialog(
              title: Text('Refreshing "${source.name}"…'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!done) const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    status,
                    style: Theme.of(sCtx).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: done
                  ? [
                      FilledButton(
                          autofocus: true,
                        onPressed: () => Navigator.pop(sCtx),
                        child: const Text('OK'),
                      ),
                    ]
                  : null,
            ),
          );
        },
      ),
    );

    unawaited(() async {
      await dialogReady.future;
      try {
        await Utils.refreshSource(
          source,
          onProgress: (msg) => setSt(() {
            status = msg.length > 60 ? '${msg.substring(0, 60)}…' : msg;
          }),
        );
        AppLog.info('Settings: refresh "${source.name}" — done');
        setSt(() {
          done = true;
          status = 'Refresh complete.';
        });
      } catch (e, st) {
        errorMsg = e.toString();
        AppLog.warn('Settings: refresh "${source.name}" — ERROR: $e\n$st');
        setSt(() {
          done = true;
          status = 'Error: $errorMsg';
        });
      }
    }());

    await dialogClosed;
  }

  /// Shows a live progress dialog while refreshing all EPG sources, then
  /// displays a summary of results.
  Future<void> _runEpgRefresh(BuildContext ctx) async {
    final enabledWithEpg = sources.where((s) {
      if (!s.enabled) return false;
      final hasManualUrl = s.epgUrl?.isNotEmpty == true;
      final isXtream = s.sourceType == SourceType.xtream;
      return hasManualUrl || isXtream;
    }).toList();

    AppLog.info(
      'EpgRefresh: starting — ${enabledWithEpg.length} eligible source(s):'
      ' ${enabledWithEpg.map((s) => '"${s.name}"').join(", ")}',
    );

    String status = 'Starting…';
    int programs = 0;
    int matchDone = 0;
    int matchTotal = 0;
    final results = <String>[];

    bool dialogOpen = true;
    // a new one. After a dialog closes, _refreshSetState still holds its
    // disposed widget's setSt. Calling it throws "Null check operator used
    // on a null value" inside Flutter's State.setState (_element! is null
    // after dispose), crashing the for-loop and leaving the next dialog
    // frozen at "Starting…" forever.
    _refreshSetState = null;
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
      programs = 0;
      status = 'Preparing "${source.name}"…';
      _updateRefreshDialog(status);

      AppLog.info('EpgRefresh: source "${source.name}" — starting');

      int sourceInserted = 0;
      int sourceMatchedChannels = 0;
      int sourceTotalChannels = 0;
      String? sourceError;
      try {
        await EpgService.refreshSource(
          source,
          epgUrl: url,
          onProgress: (p) {
            // matchChannels fires onProgress with programsInserted: 0
            // (it doesn't insert programs). Without this guard the
            // match-phase callbacks overwrite sourceInserted with 0,
            // producing a false "0 programs loaded" warning.
            if (!p.isMatching) {
              sourceInserted = p.programsInserted;
              programs = p.programsInserted;
            }

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
          AppLog.warn(
            'EpgRefresh: source "${source.name}" — 0 programs loaded'
            ' (check EPG URL / server / date window)',
          );
          results.add(
            '⚠ ${source.name}: refresh completed but 0 programs loaded '
            '(check EPG URL, server response, or date window)',
          );
        } else {
          AppLog.info(
            'EpgRefresh: source "${source.name}" — done'
            ' programs=$sourceInserted'
            ' matched=$sourceMatchedChannels/$sourceTotalChannels',
          );
          final matchSuffix = sourceTotalChannels > 0
              ? ' · $sourceMatchedChannels/$sourceTotalChannels channels matched'
              : '';
          results.add(
            '✓ ${source.name}: $sourceInserted programs$matchSuffix',
          );
        }
      } catch (e, st) {
        sourceError = e.toString();
        AppLog.warn('EpgRefresh: source "${source.name}" — ERROR: $e\n$st');
        results.add('✗ ${source.name}: $sourceError');
      }
    }

    AppLog.info(
      'EpgRefresh: complete — ${results.length} source(s) processed\n'
      '${results.join("\n")}',
    );
  
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
              autofocus: true,
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
    final eligibleSources = sources.where((s) {
      if (!s.enabled) return false;
      return EpgService.resolveEpgUrl(s) != null;
    }).toList();

    AppLog.info(
      'EpgRematch: starting — ${eligibleSources.length} eligible source(s):'
      ' ${eligibleSources.map((s) => '"${s.name}"').join(", ")}',
    );

    String status = 'Starting…';
    int matchDone = 0;
    int matchTotal = 0;
    bool dialogOpen = true;
    _refreshSetState = null;

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

      AppLog.info('EpgRematch: source "${source.name}" — downloading EPG');

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
          AppLog.warn('EpgRematch: source "${source.name}" — download returned null');
          results.add('⚠ ${source.name}: failed to download EPG');
          continue;
        }
        AppLog.info(
          'EpgRematch: source "${source.name}" — EPG downloaded'
          ' (${channelMap.length} channel entries),'
          ' starting force-match',
        );
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
        AppLog.info(
          'EpgRematch: source "${source.name}" — force-match done'
          ' $matchDone/$matchTotal',
        );
        results.add('✓ ${source.name}: re-match complete'
            '${matchTotal > 0 ? " ($matchDone/$matchTotal)" : ""}');
      } catch (e, st) {
        AppLog.warn('EpgRematch: source "${source.name}" — ERROR: $e\n$st');
        results.add('✗ ${source.name}: $e');
      }
    }

    AppLog.info(
      'EpgRematch: complete — ${results.length} source(s) processed\n'
      '${results.join("\n")}',
    );

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
              autofocus: true,
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
  // fix158: start server, show URL + QR dialog (TV export).
  Future<void> _showExportServerDialog(
    List<ExportItem> items, {
    String? capturedAt,
  }) async {
    final server = ExportServer(items, capturedAt: capturedAt);
    List<String> urls;
    try {
      urls = await server.start();
    } catch (e) {
      if (mounted) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start export server: $e')));
      }
      return;
    }
    if (urls.isEmpty) {
      await server.stop();
      if (mounted) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No network found. Connect to Wi-Fi and retry.')));
      }
      return;
    }
    if (!mounted) { await server.stop(); return; }
    final primary = urls.first;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      // ignore: use_build_context_synchronously
      builder: (ctx) => AlertDialog(
        title: const Text('Download on your phone or PC'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'On a device on the same Wi-Fi, scan this code or '
                'type the address, then tap a file to download:'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: QrImageView(
                  data: primary,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              for (final u in urls)
                SelectableText(
                  u,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
              const SizedBox(height: 8),
              const Text(
                'Server stops after 10 minutes.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () async {
              await server.stop();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
    await server.stop();
  }

  // fix222: long-press on "Export log file" exports the raw Xtream source
  // dumps (xtream_dump_*.json written during refresh when debug logging is on),
  // concatenated into one text file with delimiters so a single SAF save
  // captures all of them. Diagnostic aid for refresh-perf investigation.
  Future<void> _exportSourceDumps() async {
    final dir = await Utils.appDir;
    final d = Directory(dir);
    final dumps = <File>[];
    if (await d.exists()) {
      await for (final e in d.list()) {
        if (e is File &&
            e.path.contains('xtream_dump_') &&
            e.path.endsWith('.json')) {
          dumps.add(e);
        }
      }
    }
    if (!mounted) return;
    if (dumps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'No source dumps found. Enable debug logging, refresh a source, '
              'then try again.'),
        ),
      );
      return;
    }
    final buf = StringBuffer();
    for (final f in dumps) {
      final name = f.path.split(Platform.pathSeparator).last;
      buf.writeln('===== FILE: $name =====');
      buf.writeln(await f.readAsString());
      buf.writeln();
    }
    if (!mounted) return;
    final isTV = await DeviceDetector.isTV();
    if (!mounted) return;
    final stamp = SettingsIo.exportStamp(DateTime.now());
    if (isTV) {
      await _showExportServerDialog([
        ExportItem(
          key: 'sourcedump',
          filename: 'free4me-source-dump-$stamp.txt',
          label: 'Raw source dumps',
          bytes: utf8.encode(buf.toString()),
          contentType: 'text/plain; charset=utf-8',
        ),
      ], capturedAt: stamp);
    } else {
      await SettingsIo.exportStringToFile(
        // ignore: use_build_context_synchronously
        context,
        content: buf.toString(),
        suggestedName: 'free4me-source-dump-$stamp.txt',
      );
    }
  }

  // fix158: build backup + log payloads and serve via LAN (TV only).
  Future<void> _exportEverythingViaServer(
      {required bool includeCredentials}) async {
    final items = <ExportItem>[];
    // fix166: one stamp shared by backup + log.
    final captured = DateTime.now();
    final stamp = SettingsIo.exportStamp(captured);
    final backup = await SettingsIo.buildBackupPayload(
        includeCredentials: includeCredentials);
    items.add(ExportItem(
      key: 'backup',
      filename: 'free4me-backup-$stamp.json',
      label: 'Settings backup',
      bytes: utf8.encode(backup),
      contentType: 'application/json',
    ));
    if (settings.debugLogging) {
      final log = await AppLog.readLog();
      if (log.isNotEmpty) {
        items.add(ExportItem(
          key: 'log',
          filename: 'free4me_log-$stamp.txt',
          label: 'Debug log',
          bytes: utf8.encode(log),
          contentType: 'text/plain; charset=utf-8',
        ));
      }
    }
    if (!mounted) return;
    final capturedLabel = captured.toString().split('.').first;
    await _showExportServerDialog(items, capturedAt: capturedLabel);
  }

  // fix154: analyze playback log and suggest settings changes.
  Future<void> _runPlaybackAnalysis() async {
    if (!AppLog.enabled) {
      final enable = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Enable debug logging first'),
          content: const Text(
            'Playback analysis needs the debug log. Enable it, '
            'watch a few channels for at least 20 minutes, '
            'then run this again.',
          ),
          actions: [
            TextButton(
                autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
                autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enable logging'),
            ),
          ],
        ),
      );
      if (enable == true) {
        await AppLog.setEnabled(true);
        if (mounted) setState(() => settings.debugLogging = true);
        updateSettings(); // fix160: persist via standard helper
      }
      return;
    }

    // Snapshot current session, then aggregate history.
    try {
      final text = await AppLog.readLog();
      final m = PlaybackAnalyzer.parseLatestSession(text);
      if (m.streamsOpened > 0) await Sql.insertPlaybackMetrics(m);
    } catch (_) {}

    if (!mounted) return;
    final agg = await Sql.getAggregatedMetrics();
    AppLog.info('PlaybackAnalysis: aggregate '
        'minutes=${agg.totalMinutes.round()} streams=${agg.totalStreams} '
        'sessions=${agg.sessionCount} sufficient=${agg.hasSufficientData}');
    if (!mounted) return;

    if (!agg.hasSufficientData) {
      await showDialog<void>(
        context: context,
        // ignore: use_build_context_synchronously
        builder: (_) => AlertDialog(
          title: const Text('Not enough data yet'),
          content: Text(
            'Need at least 20 minutes of logged playback across 3+ '
            'streams. Current: '
            '${agg.totalMinutes.round()} min, ${agg.totalStreams} streams.'
            '\n\nWatch a few more channels and try again.',
          ),
          actions: [TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          )],
        ),
      );
      return;
    }

    final recs = Recommender.recommend(agg, settings);

    AppLog.info('PlaybackAnalysis: ${recs.length} recommendation(s)');
    if (!mounted) return;
    if (recs.isEmpty) {
      await showDialog<void>(
        context: context,
        // ignore: use_build_context_synchronously
        builder: (_) => AlertDialog(
          title: const Text('Playback looks healthy'),
          content: Text(
            'No setting changes recommended based on '
            '${agg.totalMinutes.round()} min across '
            '${agg.totalStreams} streams.',
          ),
          actions: [TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          )],
        ),
      );
      return;
    }

    if (!mounted) return;
    final apply = await showDialog<bool>(
      context: context,
      // ignore: use_build_context_synchronously
      builder: (_) => AlertDialog(
        title: const Text('Suggested settings'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Based on ${agg.totalMinutes.round()} min across '
                '${agg.totalStreams} streams:',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              for (final r in recs) ...
                [
                  Text(r.label,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold)),
                  Text(
                    '${r.currentValue} → ${r.suggestedValue}'
                    '${r.requiresRestart ? ' (next launch)' : ''}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Text(r.rationale,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 12),
                ],
            ],
          ),
        ),
        actions: [
          TextButton(
              autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
              autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply all'),
          ),
        ],
      ),
    );

    if (apply != true || !mounted) return;

    final updated = settings;
    for (final r in recs) {
      switch (r.settingKey) {
        case 'liveCacheSecs':
          updated.liveCacheSecs = r.suggestedValue as int; break;
        case 'bufferSizeMB':
          updated.bufferSizeMB = r.suggestedValue as int; break;
        case 'startupGraceMs':
          updated.startupGraceMs = r.suggestedValue as int; break;
        case 'bufferingWatchdogSecs':
          updated.bufferingWatchdogSecs = r.suggestedValue as int; break;
        case 'openTimeoutSecs':
          updated.openTimeoutSecs = r.suggestedValue as int; break;
      }
    }
    await SettingsService.updateSettings(updated);
    if (mounted) setState(() => settings = updated);

    final hasRestart = recs.any((r) => r.requiresRestart);
    if (mounted) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Applied ${recs.length} change(s).'
          '${hasRestart ? ' Buffer size takes effect on next launch.' : ''}',
        ),
      ));
    }
  }

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
              autofocus: true,
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

    // Only `bufferSizeMB` is baked into `PlayerConfiguration` at MpvEngine
    // construction (lib/player/mpv_engine.dart), so it is the one field
    // that genuinely requires an app restart to take effect. The demuxer-MB
    // and cache-secs fields are re-applied via `reapplyOptions()` on the
    // next stream open. Choose the snackbar copy accordingly so users
    // aren't told to restart when nothing restart-bound changed.
    final restartNeeded = fresh.bufferSizeMB != settings.bufferSizeMB;

    setState(() => settings = fresh);
    await updateSettings();

    if (!mounted) return;
    AppLog.info(
      'Settings: reset applied — $title'
      ' bufferSizeChanged=$restartNeeded',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          restartNeeded
              ? 'Settings updated. Restart the app for buffer-size changes '
                  'to take full effect.'
              : 'Settings updated.',
        ),
      ),
    );
  }


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
    // fix156: SwitchListTile makes the whole row D-pad focusable;
    // select toggles the switch. Help is a separate focus stop.
    return SwitchListTile(
      title: Text(label),
      value: value,
      onChanged: onChanged,
      secondary: _helpIcon(title: help.title, body: help.body),
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
      // fix156/160: plain text title so the row body is the D-pad target.
      title: Text(label),
      subtitle: _DpadFriendlySlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: value.round().toString(),
        onChanged: onChanged,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              value.round().toString(),
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          _helpIcon(title: help.title, body: help.body),
        ],
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
                  'Chooses which playback engine opens streams.\n\n'
                  'Default: Auto.\n\n'
                  'Auto: Recommended. The app chooses the best engine for each URL. '
                  'HLS, DASH, and MP4 streams generally use ExoPlayer for adaptive '
                  'streaming and battery efficiency. MPEG-TS, RTMP, and less standard '
                  'streams generally use libmpv for compatibility.\n\n'
                  'libmpv: Forces libmpv for every stream. Use this if a provider '
                  'works better with mpv or if ExoPlayer cannot open the stream.\n\n'
                  'ExoPlayer: Forces ExoPlayer for every stream. Use this only if '
                  'Auto picks the wrong engine for your source. Some advanced track '
                  'controls may not be available in ExoPlayer mode.',
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
            body: 'Plays multiple Live TV channels at the same time in a '
                'split-screen grid.\n\n'
                'Default: Off.\n\n'
                'Off: Multi-view is hidden and no extra streams are '
                'started.\n\n'
                '1×2: Plays up to two Live TV channels side by side. This '
                'is the safest multi-view option for most TV boxes.\n\n'
                '2×2: Plays up to four Live TV channels. Needs more CPU, '
                'decoder capacity, network bandwidth, and RAM. Use it on '
                'stronger devices or with lower-bitrate streams.\n\n'
                'Tap an empty cell to choose a Live TV channel. Tap a '
                'playing cell to give it audio focus.',
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


  String _searchMethodShortLabel(SearchMethod m) => switch (m) {
        SearchMethod.ftsAnd => 'FTS AND',
        SearchMethod.ftsTrigram => 'FTS Phrase',
        SearchMethod.likeSubstring => 'LIKE Scan',
        SearchMethod.inMemory => 'In-Memory',
      };

  Widget _searchMethodTile(Settings s) {
    return ListTile(
      title: Row(
        children: [
          const Text('Search method'),
          const SizedBox(width: 4),
          _helpIcon(
            title: 'Search Method',
            body:
                'Controls how channel-name searches are performed in the '
                'Live TV grid and channel picker screens.\n\n'
                'Default: FTS AND.\n\n'
                'FTS AND: Recommended. Splits your search into words and '
                'requires every word to match. Fast on large channel lists '
                'and usually best for names like "sky sports" or '
                '"espn hd".\n\n'
                'FTS Phrase: Uses the full query as one phrase. Can be '
                'useful when word order matters, but may be slower or less '
                'forgiving for multi-word searches.\n\n'
                'LIKE Scan: Checks channel names directly without the '
                'full-text index. Can match very short searches such as '
                '1–2 characters, but may be slow on large sources.\n\n'
                'In-Memory: Loads lightweight channel search data into RAM '
                'and searches it without disk reads. Fast for repeated '
                'searches after warmup, but uses more memory and may take '
                'a moment to prepare after startup or source refresh.',
          ),
        ],
      ),
      trailing: TextButton(
        onPressed: () => _showSearchMethodDialog(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _searchMethodShortLabel(s.searchMethod),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  static const _searchMethodOptions = [
    (method: SearchMethod.ftsAnd,        label: 'FTS AND (recommended)'),
    (method: SearchMethod.ftsTrigram,    label: 'FTS Phrase (original)'),
    (method: SearchMethod.likeSubstring, label: 'LIKE Scan (any length)'),
    (method: SearchMethod.inMemory,      label: 'In-Memory (fastest)'),
  ];

  Future<void> _showSearchMethodDialog(BuildContext context) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (_) => SelectDialog(
        title: 'Search method',
        data: _searchMethodOptions
            .asMap()
            .entries
            .map((e) => IdData(id: e.key, data: e.value.label))
            .toList(),
        action: (idx) {
          setState(() {
            settings.searchMethod = _searchMethodOptions[idx].method;
            updateSettings();
          });
          Navigator.of(context).pop();
        },
      ),
    );
  }

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

                  ExpansionTile(
                    key: const PageStorageKey('playback'),
                    leading: const Icon(Icons.play_circle_outline),
                    title: Text(
                      'Playback',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: false,
                    children: [
                      _switchTile(
                        label: "Force TV Mode",
                        value: settings.forceTVMode,
                        help: _helpForceTvMode,
                        onChanged: (v) {
                          setState(() => settings.forceTVMode = v);
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Low latency livestreams",
                        value: settings.lowLatency,
                        help: _helpLowLatency,
                        onChanged: (v) {
                          setState(() => settings.lowLatency = v);
                          updateSettings();
                        },
                      ),
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
                    ],
                  ),

                  const Divider(),

                  ExpansionTile(
                    key: const PageStorageKey('buffering'),
                    leading: const Icon(Icons.tune),
                    title: Text(
                      'Buffering',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: false,
                    children: [

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
                          'Sets the maximum RAM the demuxer can use for the '
                          'mini-player or overlay stream while another player '
                          'may also be active.\n\n'
                          'Default: calculated from device RAM '
                          '(${DeviceMemory.defaultMiniDemuxerMb} MB on this '
                          '${DeviceMemory.totalMb} MB device). '
                          'Range: 8–${DeviceMemory.maxMiniDemuxerMb} MB.\n\n'
                          'Increasing: Can smooth the mini-player on '
                          'higher-bitrate streams and reduce buffer swings '
                          'when two streams are active. Uses more RAM.\n\n'
                          'Decreasing: Frees RAM for the main player, '
                          'multi-view cells, and the OS. Use lower values on '
                          'low-memory TV boxes or if the app is closed by the '
                          'system.\n\n'
                          'For many 1080p streams, 16–32 MB is enough.',
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
                          'Sets the internal libmpv read buffer allocated '
                          'when a player instance is created.\n\n'
                          'Default: calculated from device RAM '
                          '(${DeviceMemory.defaultBufferSizeMb} MB on this '
                          '${DeviceMemory.totalMb} MB device). '
                          'Range: 16–${DeviceMemory.maxBufferSizeMb} MB.\n\n'
                          'Increasing: Can help very high-bitrate streams, '
                          'especially 4K or HEVC, keep enough data ready. '
                          'Uses more RAM per player. Multi-view and '
                          'mini-player sessions multiply that cost.\n\n'
                          'Decreasing: Reduces per-player RAM use and is '
                          'safer on 1–2 GB devices. Very low values can '
                          'cause more stalls on high-bitrate streams.\n\n'
                          'Restart required: this value is applied when '
                          'player instances are created.',
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
                          'Controls how long playback must stay healthy '
                          'before the reconnect retry counter resets.\n\n'
                          'Default: 30 s. Range: 5–60 s.\n\n'
                          'Increasing: Requires a longer stable period before '
                          'the app trusts the stream again. This is stricter '
                          'for unreliable streams and can make the app give up '
                          'sooner after repeated problems.\n\n'
                          'Decreasing: Resets the retry counter sooner after '
                          'a brief recovery. More forgiving for streams that '
                          'have small hiccups but usually recover.\n\n'
                          'If good streams are reaching the maximum retry '
                          'limit too easily, lower this value.',
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
                          'Gives a newly opened stream a short grace period '
                          'before certain startup errors are allowed to '
                          'trigger reconnect behavior.\n\n'
                          'Default: 500 ms. Range: 100–3000 ms.\n\n'
                          'Increasing: Helps slower TV hardware and slow '
                          'providers that emit harmless startup errors shortly '
                          'after playback begins. Try 1000–1500 ms if streams '
                          'double-start or reconnect immediately after '
                          'opening.\n\n'
                          'Decreasing: Lets real startup failures surface '
                          'sooner. Use lower values if bad streams take too '
                          'long to fail.\n\n'
                          'Seek-related startup errors are already suppressed '
                          'separately, so this setting mainly covers other '
                          'startup noise.',
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
                          'Controls how long the app waits before '
                          'reconnecting after a live stream reports that it '
                          'ended or the provider closes the connection.\n\n'
                          'Default: 2000 ms. Range: 0–10 000 ms.\n\n'
                          'Increasing: Gives providers more time to rotate '
                          'servers or reconnect at a segment boundary without '
                          'an immediate full reconnect. Can reduce connection '
                          'churn, but values above about 5000 ms may create '
                          'a visible freeze.\n\n'
                          'Decreasing: Reconnects faster when the stream '
                          'really ended. Set to 0 for immediate reconnect '
                          'behavior.',
                    ),
                      onChanged: (v) {
                        setState(
                          () => settings.streamCompletedDelayMs = v.round(),
                        );
                        updateSettings();
                      },
                    ),
                  _bufferSlider(
                    label: "Max reconnect attempts",
                    value: settings.maxReconnectAttempts.toDouble(),
                    min: 1,
                    max: 10,
                    divisions: 9,
                    help: _helpMaxReconnectAttempts,
                    onChanged: (v) {
                      setState(
                        () => settings.maxReconnectAttempts = v.round(),
                      );
                      updateSettings();
                    },
                  ),
                    ],
                  ),

                  ExpansionTile(
                    key: const PageStorageKey('multiview'),
                    leading: const Icon(Icons.grid_view),
                    title: Text(
                      'Multi-view',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: false,
                    children: [
                      _multiViewTile(settings),
                      SwitchListTile(
                        title: Row(
                          children: [
                            const Expanded(
                              child: Text('Restore last channels on open'),
                            ),
                            const SizedBox(width: 4),
                            _helpIcon(
                              title: 'Auto-restore channels',
                              body:
                                  'Controls whether multi-view reopens with '
                                  'the Live TV channels you used last time.\n\n'
                                  'Default: ON.\n\n'
                                  'ON: Opening multi-view restores the saved '
                                  'channels for the selected layout. Fastest '
                                  'if you usually watch the same channel '
                                  'group.\n\n'
                                  'OFF: Multi-view opens with empty cells. '
                                  'Use this if you prefer to choose fresh '
                                  'channels each session.\n\n'
                                  'Your previous picks are still remembered. '
                                  'Turning this back on restores them the '
                                  'next time multi-view opens.',
                            ),
                          ],
                        ),
                        value: settings.multiViewAutoRestoreChannels,
                        onChanged: settings.multiViewLayout == MultiViewLayout.none
                            ? null // greyed when multi-view itself is off
                            : (v) {
                                setState(
                                  () => settings.multiViewAutoRestoreChannels = v,
                                );
                                updateSettings();
                              },
                      ),
                    ],
                  ),

                  const Divider(),

                  ExpansionTile(
                    key: const PageStorageKey('content'),
                    leading: const Icon(Icons.filter_list),
                    title: Text(
                      'Content',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: false,
                    children: [
                      ListTile(
                        // fix156: plain text title so ListTile is the
                        // focusable D-pad target (select opens picker).
                        // Help icon moved to trailing as a separate stop.
                        title: const Text("Default view"),
                        subtitle: Text(viewTypeToString(settings.defaultView)),
                        trailing: _helpIcon(
                          title: _helpDefaultView.title,
                          body: _helpDefaultView.body,
                        ),
                        onTap: () async => await _showDefaultViewDialog(context),
                      ),
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
                          if (!v &&
                              !settings.showMovies &&
                              !settings.showSeries) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'At least one content type must be enabled.'),
                              ),
                            );
                            return;
                          }
                          setState(() {
                            settings.showLivestreams = v;
                            if (!settings
                                .availableContentFilters()
                                .contains(settings.contentTypeFilter)) {
                              settings.contentTypeFilter =
                                  ContentTypeFilter.all;
                            }
                          });
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Show movies",
                        value: settings.showMovies,
                        help: _helpShowMovies,
                        onChanged: (v) {
                          if (!v &&
                              !settings.showLivestreams &&
                              !settings.showSeries) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'At least one content type must be enabled.'),
                              ),
                            );
                            return;
                          }
                          setState(() {
                            settings.showMovies = v;
                            if (!settings
                                .availableContentFilters()
                                .contains(settings.contentTypeFilter)) {
                              settings.contentTypeFilter =
                                  ContentTypeFilter.all;
                            }
                          });
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Show series",
                        value: settings.showSeries,
                        help: _helpShowSeries,
                        onChanged: (v) {
                          if (!v &&
                              !settings.showLivestreams &&
                              !settings.showMovies) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'At least one content type must be enabled.'),
                              ),
                            );
                            return;
                          }
                          setState(() {
                            settings.showSeries = v;
                            if (!settings
                                .availableContentFilters()
                                .contains(settings.contentTypeFilter)) {
                              settings.contentTypeFilter =
                                  ContentTypeFilter.all;
                            }
                          });
                          updateSettings();
                        },
                      ),
                      _searchMethodTile(settings),
                      _switchTile(
                        label: 'Safe mode',
                        value: settings.safeMode,
                        help: _helpSafeMode,
                        onChanged: (v) async {
                          setState(() => settings.safeMode = v);
                          await updateSettings();
                          if (!mounted) return;
                          // Capture messenger before the async gap is crossed.
                          final messenger = ScaffoldMessenger.of(context);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                v
                                    ? 'Safe mode enabled — adult channels hidden.'
                                    : 'Safe mode disabled — all channels visible.',
                              ),
                            ),
                          );
                        },
                      ),
                      // Stream scanner
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
                    ],
                  ),

                  const Divider(),

                  ExpansionTile(
                    key: const PageStorageKey('epg'),
                    leading: const Icon(Icons.calendar_month),
                    title: Text(
                      'EPG / Program Guide',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: false,
                    children: [
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
                              autofocus: true,
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
                    ],
                  ),

                  const Divider(),

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
                      "Tap to save the debug log. Long-press to export raw "
                      "source dumps (diagnostic).",
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
                            // fix158: TV has no SAF — use local server
                            final isTV = await DeviceDetector.isTV();
                            if (!mounted) return;
                            if (isTV) {
                              await _exportEverythingViaServer(
                                  includeCredentials: false);
                            } else {
                              await SettingsIo.exportStringToFile(
                                // ignore: use_build_context_synchronously
                                context,
                                content: log,
                                suggestedName:
                                    'free4me_log-${SettingsIo.exportStamp(DateTime.now())}.txt',
                              );
                            }
                          }
                        : null,
                    // fix222: long-press exports the raw source dumps (diagnostic).
                    onLongPress: settings.debugLogging
                        ? () async {
                            await _exportSourceDumps();
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
                                content: Text('Log and source dumps cleared.'),
                              ),
                            );
                          }
                        : null,
                  ),

                  const Divider(),

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
                                autofocus: true,
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
                      // fix158: TV has no SAF — use local server
                      final isTV = await DeviceDetector.isTV();
                      if (!mounted) return;
                      if (isTV) {
                        await _exportEverythingViaServer(
                            includeCredentials: includeCredentials);
                      } else {
                        await SettingsIo.exportToFile(
                          // ignore: use_build_context_synchronously
                          context,
                          includeCredentials: includeCredentials,
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.download_for_offline),
                    title: const Text("Import settings from file"),
                    subtitle: const Text(
                      "Restore sources and settings from a backup",
                    ),
                    onTap: () async {
                      final imported =
                          await SettingsIo.importFromFile(context);
                      if (!context.mounted) return;
                      if (imported) {
                        await showSourcesRefreshDialog(context);
                      }
                      if (!context.mounted) return;
                      await initAsync(); // Reload UI after import
                    },
                  ),

                  const Divider(),

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
                  ListTile(
                    leading: const Icon(Icons.insights),
                    title: const Text('Analyze playback & suggest settings'),
                    subtitle: const Text(
                      'Reviews your recent playback history (buffering, '
                      'startup, reconnects) and suggests buffer/cache/timing '
                      'tweaks for your device and connection.',
                    ),
                    onTap: _runPlaybackAnalysis,
                  ),
                  ListTile(
                    leading: const Icon(Icons.wifi_tethering_off),
                    title: const Text("Clear stream validation"),
                    subtitle: const Text(
                      "Reset all stream scan results. Channels will "
                      "show as unvalidated until rescanned.",
                    ),
                    onTap: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text("Clear stream validation?"),
                          content: const Text(
                            "This resets the scan result for every channel. "
                            "Channels will appear unvalidated until you run "
                            "the stream scanner again.\n\n"
                            "Your favorites, watch history, and EPG data "
                            "are not affected.",
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text("Cancel"),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text("Clear"),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true && mounted) {
                        await Sql.clearAllStreamValidated();
                        StreamScanner.clearResults();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Stream validation cleared."),
                            ),
                          );
                        }
                      }
                    },
                  ),

                  const Divider(),

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
                    leading: const Icon(Icons.article_outlined),
                    title: const Text('Version and changelog'),
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
                            onPressed: () async {
                              await showSourcesRefreshDialog(context);
                              // Reload the sources list in case names or
                              // counts changed.
                              if (mounted) await reloadSources();
                            },
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
              settings: settings,
              contentTypeFilter: settings.contentTypeFilter,
              onContentTypeChanged: (_) {}, // no-op in Settings view
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
