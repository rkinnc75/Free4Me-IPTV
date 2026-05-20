import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/engine_type.dart';
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
      '"All" shows everything — livestreams, movies, and series together. '
      '"Livestreams" jumps straight to live TV. "Movies" or "Series" opens '
      'that section directly. Choose whichever you use most so you never '
      'have to navigate after launch.',
);

const _helpForceTvMode = (
  title: 'Force TV Mode',
  body:
      'Overrides automatic device detection and always shows the TV-optimized '
      'layout — larger tiles, D-pad navigation, no on-screen keyboard shortcuts. '
      'Turn ON if the app incorrectly starts in phone/tablet mode on your Android '
      'TV box. Turn OFF to use the touch-friendly layout on any device. '
      'Default: OFF.',
);

const _helpLowLatency = (
  title: 'Low Latency (Live TV)',
  body:
      'Tells the player to prefer the lowest-quality HLS variant instead of the '
      'highest. Turn ON to reduce the delay between broadcast and playback — '
      'useful for live sports where score spoilers matter. Turn OFF for the best '
      'picture quality. Has no effect on non-HLS streams (MPEG-TS, RTMP, etc.). '
      'Default: OFF.',
);

const _helpRefreshOnStart = (
  title: 'Refresh Sources on Start',
  body:
      'Automatically re-downloads all your M3U playlists and Xtream channel '
      'lists every time the app launches. Turn ON if your provider changes '
      'channel URLs frequently and you want the freshest list without tapping '
      'Refresh manually. Turn OFF to start faster — you can still refresh at '
      'any time from the Sources section. Default: OFF.',
);

const _helpShowLivestreams = (
  title: 'Show Livestreams',
  body:
      'Controls whether live TV channels appear anywhere in the app — in the '
      'channel grid, search results, and the "All" view. Turn OFF to hide live '
      'TV entirely if your source only contains movies and series. Hiding a '
      'type does not delete channels; they reappear if you turn the setting '
      'back on. Default: ON.',
);

const _helpShowMovies = (
  title: 'Show Movies',
  body:
      'Controls whether on-demand movies appear in the channel grid, search '
      'results, and "All" view. Turn OFF to hide the movie library if you only '
      'use the app for live TV. Default: ON.',
);

const _helpShowSeries = (
  title: 'Show Series',
  body:
      'Controls whether TV series and episodes appear in the channel grid, '
      'search results, and "All" view. Turn OFF to hide series content if you '
      'do not use that section. Default: ON.',
);

const _helpHwDecode = (
  title: 'Hardware Decoding',
  body:
      'Uses your device\'s dedicated video-decoder chip (MediaCodec) instead '
      'of the CPU. Turn ON (recommended for Android TV) — reduces heat and CPU '
      'load and allows 4K/HEVC streams to play smoothly on most boxes. Turn OFF '
      'only if you see video corruption, a green screen, or playback failures; '
      'some older or budget chipsets have buggy hardware decoders. Default: ON.',
);

const _helpPreWarm = (
  title: 'Pre-warm Streams on Focus',
  body:
      'Resolves redirect URLs in the background the moment you highlight a '
      'channel tile with the D-pad, so playback starts noticeably faster when '
      'you press OK/Enter. Turn ON for snappier channel switching. Turn OFF if '
      'you are on a metered connection or notice unwanted network activity while '
      'browsing. Default: ON.',
);

const _helpLiveCacheSecs = (
  title: 'Livestream Cache (seconds)',
  body:
      'How many seconds of live TV the player keeps in its read-ahead memory '
      'buffer. Increasing reduces rebuffering on unstable connections and adds '
      'a small rewind window. Decreasing lowers RAM use — useful on 1–2 GB '
      'Android TV boxes. Too high a value on a slow stream can cause audio/video '
      'sync drift. Default: 20 s. Slider range: 5–60 s.',
);

const _helpLiveDemuxerMB = (
  title: 'Livestream Demuxer Buffer (MB)',
  body:
      'Maximum RAM the stream-splitter (demuxer) may use while playing live TV. '
      'Increasing prevents dropped frames on high-bitrate 4K or HEVC streams by '
      'giving the decoder a larger in-memory cushion. Decreasing frees RAM — '
      'reduce this first if the app is killed by the system on a low-memory box. '
      'Default: 150 MB. Slider range: 32–512 MB.',
);

const _helpVodCacheSecs = (
  title: 'VOD/Movie Cache (seconds)',
  body:
      'How many seconds ahead the player reads from a movie or on-demand stream '
      'into memory. Increasing reduces pauses during seek (fast-forward/rewind) '
      'and smooths playback on slow connections. Decreasing lowers RAM use. Has '
      'no effect on live TV streams. Default: 60 s. Slider range: 10–180 s.',
);

const _helpVodDemuxerMB = (
  title: 'VOD/Movie Demuxer Buffer (MB)',
  body:
      'Maximum RAM the demuxer may use while playing a movie or series episode. '
      'Increasing improves seek performance and reduces pauses on high-bitrate '
      'VOD (Blu-ray remuxes, 4K). Decreasing frees memory. Has no effect on '
      'live TV streams. Default: 256 MB. Slider range: 64–1024 MB.',
);

const _helpOpenTimeout = (
  title: 'Stream Open Timeout (seconds)',
  body:
      'How long the player waits for a stream to begin playing before giving up '
      'and showing an error. Increasing gives slow or geographically distant '
      'servers more time to respond — helpful on congested networks or with '
      'international streams. Decreasing makes failures surface faster so the '
      'app can retry or show an error sooner. Default: 15 s. Slider range: 5–60 s.',
);

const _helpWatchdog = (
  title: 'Buffering Watchdog (seconds)',
  body:
      'If a live stream stalls in a buffering/loading state for longer than this '
      'value, the player automatically disconnects and reconnects. Increasing '
      'gives the server more time to recover on its own — better on intermittent '
      'connections where a brief stall self-resolves. Decreasing forces a '
      'reconnect sooner, which helps with streams that silently freeze without '
      'ever recovering. Default: 12 s. Slider range: 5–60 s.',
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
          pageBuilder: (_, __, ___) => Home(
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Source ${!source.enabled ? "enabled" : "disabled"}"),
        duration: const Duration(milliseconds: 500),
      ),
    );
  }

  Widget getSource(Source source) {
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 5,
      ),
      elevation: 5,
      child: ListTile(
        leading: Icon(source.enabled ? Icons.tv : Icons.tv_off),
        horizontalTitleGap: 25,
        onLongPress: () => toggleSource(source),
        contentPadding: const EdgeInsets.only(left: 20),
        title: Text(source.name),
        subtitle: Text(source.sourceType.label),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          if (sources.isEmpty) {
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
    setState(() {
      sources;
    });
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
      final isXtream = source.sourceType.index == 0;
      if (!hasManualUrl && !isXtream) continue;

      final url = hasManualUrl ? source.epgUrl : null;
      matchDone = 0;
      matchTotal = 0;
      status = 'Preparing "${source.name}"…';
      _updateRefreshDialog(status);

      int sourceInserted = 0;
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
          results.add('✓ ${source.name}: $sourceInserted programs');
        }
      } catch (e) {
        sourceError = e.toString();
        results.add('✗ ${source.name}: $sourceError');
      }
    }
  
    if (dialogOpen && mounted) Navigator.of(ctx, rootNavigator: true).pop();

    if (!mounted) return;
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

  // Mutable state for the refresh progress dialog
  void Function(void Function())? _refreshSetState;
  String _refreshStatus = '';

  void _updateRefreshDialog(String status, [int count = 0]) {
    _refreshStatus = status;
    _refreshSetState?.call(() {});
  }

  Future<void> updateSettings() async {
    await Error.tryAsyncNoLoading(
      () async => await SettingsService.updateSettings(settings),
      context,
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
                    max: 512,
                    divisions: 60,
                    help: _helpLiveDemuxerMB,
                    onChanged: (v) {
                      setState(() => settings.liveDemuxerMaxMB = v.round());
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
                          'How long a stream must play without interruption '
                          'before the reconnect retry counter is reset. '
                          'A lower value resets the counter sooner after a '
                          'blip; a higher value requires more sustained '
                          'stability. Default: 30 s. Range: 5–60 s.',
                    ),
                    onChanged: (v) {
                      setState(
                        () => settings.stableThresholdSecs = v.round(),
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
                          'in the background at the scheduled hour. Turn OFF to '
                          'only refresh manually. Default: ON.',
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
                          'How often the app checks for updated program data. '
                          'Increasing reduces data usage. Decreasing keeps the '
                          'guide more current. Default: 24 h. Range: 6–168 h (7 days).',
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
                          'The hour of the day (local time, 24-hour clock) when '
                          'the background refresh runs. Default: 3 (03:00). '
                          'Choose a time when the device is likely plugged in '
                          'and connected to Wi-Fi.',
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
                          'How many days of past program data to retain. '
                          'Increasing lets you see what aired recently. '
                          'Set to 0 to keep only current and future programs. '
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
                          'How many days ahead of program data to download. '
                          'Increasing gives more advance schedule visibility '
                          'but uses more storage and download time. '
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
                            (s.epgUrl == null || s.epgUrl!.isEmpty) &&
                            s.sourceType.index != 0, // 0 = xtream
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
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Log file is empty.'),
                                ),
                              );
                              return;
                            }
                            await SettingsIo.exportStringToFile(
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
