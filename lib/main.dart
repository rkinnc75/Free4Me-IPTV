import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/playback_analyzer.dart';
import 'package:open_tv/backend/channel_search_cache.dart';
import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/backend/epg_service.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/update_checker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:workmanager/workmanager.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/models/app_navigator.dart';
import 'package:open_tv/models/custom_shortcut.dart';
import 'package:open_tv/player/overlay_player_widget.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/setup.dart';
import 'package:open_tv/tv_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Workmanager().initialize(callbackDispatcher);

  // Cold-start order matters for log visibility: AppLog gates every call
  // by a "debug logging" boolean that lives inside Settings, so we need
  // settings BEFORE we can enable logging. Subsystems initialised before
  // AppLog is enabled would otherwise silently drop their log lines.
  //
  //   1. Read settings (silently — AppLog still off).
  //   2. Enable AppLog from the value we just read.
  //   3. Initialise DeviceMemory — its log line now lands.
  //   4. SettingsService.reload() so RAM-aware first-run defaults
  //      computed via DeviceMemory replace the placeholders read in step 1.
  //
  // After step 4, every subsystem's startup log is visible and settings
  // reflect the device's true RAM.
  final earlySettings = await SettingsService.getSettings();
  await AppLog.setEnabled(earlySettings.debugLogging);
  AppLog.logUserPass = earlySettings.logUserPass;
  AppLog.setSourceSecrets(await Sql.getSources());
  await DeviceMemory.init();
  final settings = await SettingsService.reload();

  // fix212: one-time boot reconcile of FTS triggers to the active search method.
  // The DB migration creates the triggers on every install, but they are only
  // needed for FTS search methods; drop them otherwise so refresh inserts stay
  // fast. Unawaited — not on the critical render path.
  unawaited(Sql.reconcileFtsTriggers(
    settings.searchMethod == SearchMethod.ftsAnd ||
        settings.searchMethod == SearchMethod.ftsTrigram,
  ));

  // unawaited — startup continues immediately; the cache is ready by the time
  // the user first types in the search box.
  if (settings.searchMethod == SearchMethod.inMemory) {
    unawaited(ChannelSearchCache.ensureBuilt().then((_) {
      AppLog.info('main: ChannelSearchCache warm-up complete');
    }));
  }

  // Parallelize the remaining cold-start awaits.
  final results = await Future.wait([
    Sql.hasSources(),
    Utils.hasTouchScreen(),
    DeviceDetector.isTV(),
  ]);
  final hasSources = results[0];
  final hasTouchScreen = results[1];
  final isTV = results[2];
  final packageInfo = await PackageInfo.fromPlatform();
  AppLog.info(
    'App started — version=${packageInfo.version}'
    ' build=${packageInfo.buildNumber}'
    ' searchMethod=${settings.searchMethod.name}' // fix361: which search
    ' (ftsTriggers=${settings.searchMethod == SearchMethod.ftsAnd ||
        settings.searchMethod == SearchMethod.ftsTrigram})',
  );
  // fix314: log SoC/board + Tegra detection so multi-view decode routing is
  // verifiable on real hardware (Shield colour-corruption investigation).
  unawaited(() async {
    final board = await DeviceDetector.boardInfo();
    final tegra = await DeviceDetector.isTegra();
    AppLog.info('fix314 device: $board | isTegra=$tegra');
  }());
  // fix373: warm the SQLite page cache for the browse path BEFORE first paint.
  // The first browse query on a cold DB (esp. multi-source) faults its index +
  // data pages from disk; doing a representative browse in the background here
  // pulls those pages into cache so the user's first Home.load is fast. Off the
  // render path (unawaited); skipped when there are no sources yet.
  if (hasSources) {
    unawaited(Sql.warmBrowseCache(settings).then((ms) {
      AppLog.info('main: browse cache warm-up complete (${ms}ms)');
    }).catchError((e) {
      AppLog.warn('main: browse warm-up failed — $e');
    }));
  }
  unawaited(EpgService.scheduleBackgroundRefresh());
  runApp(
    MyApp(
      skipSetup: hasSources,
      settings: settings,
      hasTouchScreen: hasTouchScreen,
      isTV: isTV,
    ),
  );
}

/// Thin StatefulWidget whose only job is to fire the update check once the
/// widget tree has a valid BuildContext (required by showDialog in UpdateChecker).
class _RootPage extends StatefulWidget {
  final bool skipSetup;
  final Settings settings;
  final bool hasTouchScreen;
  final bool isTV;

  const _RootPage({
    required this.skipSetup,
    required this.settings,
    required this.hasTouchScreen,
    required this.isTV,
  });

  @override
  State<_RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<_RootPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // fix154
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdateChecker.checkOnLaunch(context);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // fix154
    super.dispose();
  }

  // fix154: capture playback metrics into rolling history on app pause.
  // Best-effort; only runs when debug logging is on.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _capturePlaybackMetrics();
    }
  }

  static Future<void> _capturePlaybackMetrics() async {
    try {
      if (!AppLog.enabled) return;
      final text = await AppLog.readLog();
      final m = PlaybackAnalyzer.parseLatestSession(text);
      if (m.streamsOpened == 0) return;
      await Sql.insertPlaybackMetrics(m);
    } catch (e) {
      AppLog.warn('capturePlaybackMetrics: skipped — $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.skipSetup) return const Setup();
    if (widget.settings.forceTVMode ||
        widget.isTV ||
        (!widget.hasTouchScreen &&
            (Platform.isAndroid || Platform.isIOS))) {
      return TvHome();
    }
    return Home(
      firstLaunch: true,
      refresh: widget.settings.refreshOnStart,
      home: HomeManager(
        filters: Filters(viewType: widget.settings.defaultView),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  final bool skipSetup;
  final Settings settings;
  final bool hasTouchScreen;
  final bool isTV;
  static final GlobalKey<NavigatorState> navigatorKey = appNavigatorKey;

  const MyApp({
    super.key,
    required this.skipSetup,
    required this.settings,
    required this.hasTouchScreen,
    required this.isTV,
  });

  bool get _isEditingText {
    final focus = FocusManager.instance.primaryFocus;
    return focus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Free4Me-IPTV',
      navigatorKey: navigatorKey,
      navigatorObservers: [playerRouteObserver], // fix98
      builder: (context, child) {
        return Stack(
          children: [
            CallbackShortcuts(
              bindings: {
                CustomShortcut(
                  const SingleActivator(LogicalKeyboardKey.escape),
                ): () {
                  if (_isEditingText) return;
                  navigatorKey.currentState?.maybePop();
                },
                CustomShortcut(
                  const SingleActivator(LogicalKeyboardKey.backspace),
                ): () {
                  if (_isEditingText) return;
                  navigatorKey.currentState?.maybePop();
                },
              },
              child: child ?? const SizedBox.shrink(),
            ),
            // Floating mini-player overlay — always on top of all routes
            const OverlayPlayerWidget(),
          ],
        );
      },
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          surface: Colors.black,
          brightness: Brightness.dark,
          surfaceContainer: Color.fromARGB(255, 29, 36, 41),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && !hasTouchScreen) {
                return const BorderSide(
                  color: Colors.yellow, // yellow border
                  width: 4,
                );
              }
              return BorderSide.none;
            }),
          ),
        ),
        // fix164/168: TV/remote focus must be visible on the dark M3 surface.
        // ThemeData.focusColor is the top-level fallback that ListTile,
        // InkWell/InkResponse, IconButton, Switch, Radio etc. read when
        // their own focusColor is null. (fix168: ListTileThemeData has NO
        // focusColor param — ThemeData.focusColor is the correct lever.)
        // Gated on !hasTouchScreen — touch UI unchanged.
        focusColor: hasTouchScreen
            ? null
            : Colors.lightBlueAccent.withValues(alpha: 0.40),
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && !hasTouchScreen) {
                return const BorderSide(color: Colors.yellow, width: 3);
              }
              return null;
            }),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && !hasTouchScreen) {
                return const BorderSide(color: Colors.yellow, width: 3);
              }
              return null;
            }),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && !hasTouchScreen) {
                return const BorderSide(color: Colors.yellow, width: 3);
              }
              return null;
            }),
          ),
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      home: _RootPage(
        skipSetup: skipSetup,
        settings: settings,
        hasTouchScreen: hasTouchScreen,
        isTV: isTV,
      ),
    );
  }
}
