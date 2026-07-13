import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/tv/theme/accent_scope.dart'; // fix701 (TV GUI redesign)
import 'package:open_tv/tv/theme/f4_tokens.dart'; // fix701 (TV GUI redesign)
import 'package:open_tv/backend/playback_analyzer.dart';
import 'package:open_tv/backend/channel_search_cache.dart';
import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/backend/epg_service.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/recording_scheduler.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/update_checker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:workmanager/workmanager.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/models/app_navigator.dart';
import 'package:open_tv/models/custom_shortcut.dart';
import 'package:open_tv/player/mpv_engine.dart'; // finding 100/101: DVR sweep
import 'package:open_tv/player/overlay_player_widget.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/backend/render_cap.dart';
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

  // fix719 (TV GUI redesign, Phase 5): restore the persisted TV accent into the
  // live notifier before the first frame so focus rings paint the chosen color
  // from the start (default 'white'). Inert on phone (accent unused there).
  appAccentNotifier.value = accentColorFromId(settings.accentName);
  // fix726 (mock §4.1): restore the OLED-black background choice pre-first-frame.
  appOledNotifier.value = settings.oledBlack;

  // fix667: initialise the DVR alarm scheduler (Android only; no-op else).
  // After settings so a first-run box has its config; safe if it fails.
  unawaited(RecordingScheduler.init());

  // finding 100/101: sweep orphaned per-engine DVR cache dirs left by a
  // crash/power-cut mid-DVR. Safe at cold start — no engine in this process has
  // created a live subdir yet. Unawaited, off the render path.
  unawaited(MpvEngine.sweepOrphanedDvrDirs());

  // fix212: one-time boot reconcile of FTS triggers to the active search method.
  // The DB migration creates the triggers on every install, but they are only
  // needed for FTS search methods; drop them otherwise so refresh inserts stay
  // fast. Unawaited — not on the critical render path.
  unawaited(
    Sql.reconcileFtsTriggers(
      settings.searchMethod == SearchMethod.ftsAnd ||
          settings.searchMethod == SearchMethod.ftsPhrase,
    ),
  );

  // unawaited — startup continues immediately; the cache is ready by the time
  // the user first types in the search box.
  // fix608 (#1): collect the heavy startup DB warm-ups so the foreground
  // stale-EPG refresh (fix600) can be deferred until they finish — see below.
  final warmups = <Future<void>>[];
  if (settings.searchMethod == SearchMethod.inMemory) {
    warmups.add(
      ChannelSearchCache.ensureBuilt().then((_) {
        AppLog.info('main: ChannelSearchCache warm-up complete');
      }),
    );
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
    ' (ftsTriggers=${settings.searchMethod == SearchMethod.ftsAnd || settings.searchMethod == SearchMethod.ftsPhrase})',
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
    warmups.add(
      Sql.warmBrowseCache(settings)
          .then((ms) {
            AppLog.info('main: browse cache warm-up complete (${ms}ms)');
          })
          .catchError((e) {
            AppLog.warn('main: browse warm-up failed — $e');
          }),
    );
    // fix542: run the deferred one-time fix537 index maintenance (drop unused +
    // rebuild cat_enabled-free browse indexes + VACUUM) HERE, off the cold-start
    // critical path (unawaited, after first frame), so it can never block
    // startup / black-screen the app on a large catalog. Gated to run once.
    // finding 58: chain the deferred channels_fts backfill + ANALYZE (moved out
    // of migrations 35/38, the two heaviest cold-start full-scans) AFTER the
    // index maintenance so ANALYZE reflects the final index shapes. Both are
    // off the critical path; runPendingIndexMaintenance swallows its own errors
    // so the .then always runs.
    warmups.add(
      Sql.runPendingIndexMaintenance().then(
        (_) => Sql.runPendingFtsAndAnalyze(),
      ),
    );
    // fix546: purge legacy divider rows once, also off the cold-start path.
    unawaited(Sql.runPendingDividerCleanup());
    // fix628: self-heal channels indexes lost to an interrupted/killed refresh
    // (drop-without-recreate). Deferred/unawaited — a full rebuild is minutes of
    // merge-sort on a 1.2M-row catalog and must never block the splash; cheap
    // no-op when all indexes are present.
    unawaited(Sql.ensureBrowseIndexesPresent());
  }
  // finding 38: cold-start poll of the cross-isolate EPG-completion marker, so a
  // background refresh that finished while the app was killed is picked up now
  // (bumps the main-isolate epgVersion once; guide reloads on first build). The
  // DB is already open here (Sql.hasSources above). Unawaited — off the render
  // path. Also polled on resume in _RootPageState.didChangeAppLifecycleState.
  unawaited(pollEpgCompletion());
  unawaited(EpgService.scheduleBackgroundRefresh());
  // fix600: the background EPG task is unreliable on TV boxes (Amlogic/onn kill
  // background work) so the forecast can lapse → empty guide grid + empty "On
  // now". Foreground-refresh on launch IF the EPG is stale (no programme airing
  // now). Non-blocking; the guide reloads via EpgService.epgVersion on finish.
  // fix608 (#1): DEFER it until the startup DB warm-ups (cache build + browse
  // warm + index maintenance) finish — on a huge catalog those saturate SQLite
  // for 1–3 min (the Shield startup freeze), and firing a 100k-programme EPG
  // download into that pile made it worse. Each warm-up swallows its own error
  // so Future.wait always settles; whenComplete runs the refresh either way.
  Future.wait(warmups.map((f) => f.catchError((_) {})))
      // fix609: safety cap so a hung/very-long warm-up can't trap the startup
      // splash forever — lift it after 4 min regardless. Normal launches lift
      // far sooner (when the warm-ups actually finish).
      .timeout(const Duration(minutes: 4), onTimeout: () => <void>[])
      .whenComplete(() {
        appWarmupDone.value = true; // fix609: lift the "Preparing…" splash
        unawaited(EpgService.refreshIfStale());
      });
  // fix506: mirror the render-cap setting to the native SharedPref so the
  // 1080p cap decision is correct on the NEXT launch.
  unawaited(RenderCap.setEnabled(settings.cap1080pOnLowRam));
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
/// fix609: false until the heavy startup DB warm-ups (search-cache rebuild +
/// browse warm + index maintenance) finish. While false, the home shows a
/// "Preparing…" splash over the real UI so a huge catalog (272k+ channels, e.g.
/// on a Shield) shows branding instead of a frozen/blank screen during the
/// 1–3 min SQL warm-up. Set true in main() when Future.wait(warmups) settles
/// (or the 4-min safety cap fires). Skips straight to true effect when there's
/// nothing to warm (no sources / fast device → brief or no splash).
final ValueNotifier<bool> appWarmupDone = ValueNotifier<bool>(false);

// finding 38: main-isolate memory of the last EPG-completion timestamp we have
// already reflected into the guide. epg_last_completed_utc is written by the
// background (Workmanager) isolate via Sql.setAppMeta when refreshSource finishes;
// this static lives in the MAIN isolate only. 0 = nothing seen yet this process.
int _lastSeenEpgCompletedUtc = 0;

/// finding 38: bridge the per-isolate epgVersion gap. Reads the cross-isolate
/// completion marker (app_meta 'epg_last_completed_utc'); if it advanced past
/// what this isolate last saw, bumps the MAIN-isolate EpgService.epgVersion so
/// TvGuideView reloads. Called on app resume and once at cold-start after the DB
/// is open. Safe even if the premise is false: no marker or an unchanged marker
/// is a no-op; a bad/parse-failing value is swallowed.
Future<void> pollEpgCompletion() async {
  try {
    final raw = await Sql.getAppMeta('epg_last_completed_utc');
    if (raw == null) return;
    final ts = int.tryParse(raw.trim());
    if (ts == null) return;
    if (ts > _lastSeenEpgCompletedUtc) {
      _lastSeenEpgCompletedUtc = ts;
      EpgService.epgVersion.value++; // notify main-isolate guide listener
    }
  } catch (e) {
    AppLog.warn('pollEpgCompletion: skipped — $e');
  }
}

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
    } else if (state == AppLifecycleState.resumed) {
      // finding 38: the Workmanager background isolate bumps EpgService.epgVersion
      // when a refresh finishes, but Dart statics are per-isolate so that bump
      // never reaches this (main) isolate's TvGuideView listener. The background
      // isolate persists a completion timestamp in app_meta; on resume we compare
      // it to what we last saw and bump the MAIN-isolate epgVersion so the guide
      // reloads. Best-effort; unawaited so it never blocks the resume.
      unawaited(pollEpgCompletion());
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
    final Widget home;
    if (widget.settings.forceTVMode ||
        widget.isTV ||
        (!widget.hasTouchScreen && (Platform.isAndroid || Platform.isIOS))) {
      home = TvHome(settings: widget.settings);
    } else {
      home = Home(
        firstLaunch: true,
        refresh: widget.settings.refreshOnStart,
        home: HomeManager(
          filters: Filters(viewType: widget.settings.defaultView),
        ),
      );
    }
    // fix609: overlay the startup splash until the DB warm-ups finish, so a huge
    // catalog shows "Preparing…" instead of a frozen/blank UI. Fades out (and is
    // removed) when appWarmupDone flips. The home builds underneath meanwhile.
    return ValueListenableBuilder<bool>(
      valueListenable: appWarmupDone,
      builder: (context, done, _) => Stack(
        fit: StackFit.expand,
        children: [
          home,
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: done
                  ? const SizedBox.shrink(key: ValueKey('warm-done'))
                  : const _StartupSplash(key: ValueKey('warm-splash')),
            ),
          ),
        ],
      ),
    );
  }
}

/// fix609: full-screen startup splash shown over the home while the DB warms up.
/// Same background as the TV shell (assets/tv_background.webp) with an 85% scrim
/// so the message reads clearly.
class _StartupSplash extends StatelessWidget {
  const _StartupSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: AssetImage('assets/tv_background.webp'),
          fit: BoxFit.cover,
        ),
        ColoredBox(color: Color(0xD9000000)), // 85% scrim
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(height: 28),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Preparing for the best Free4Me experience…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
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
    // fix719 (TV GUI redesign, Phase 5): rebuild MaterialApp when the accent
    // changes so the button-theme focus rings (which read appAccentNotifier at
    // resolve time) re-resolve to the new color immediately. AccentScope-based
    // widgets (rails/tiles/etc.) already update via the InheritedNotifier; this
    // covers the theme-level rings. The rebuild only fires on the rare accent
    // pick (in Settings — no player active), so it never stutters the Texture.
    return ValueListenableBuilder<Color>(
      valueListenable: appAccentNotifier,
      builder: (context, _, _) => MaterialApp(
        title: 'Free4Me',
        navigatorKey: navigatorKey,
      navigatorObservers: [playerRouteObserver], // fix98
      builder: (context, child) {
        // fix701 (TV GUI redesign, Phase 0): install the live accent high in the
        // tree, above all route content, so TvFocusable reads it at draw time.
        // Inert for the phone path (phone widgets never read AccentScope).
        return AccentScope(
          notifier: appAccentNotifier,
          child: Stack(
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
          ),
        );
      },
      theme: ThemeData(
        brightness: Brightness.dark,
        // fix728 (TV GUI redesign, mock §2): Inter as the 10-foot type face on
        // TV only. Bundled variable font (assets/fonts/Inter.ttf, OFL 1.1); its
        // wght axis maps to TextStyle.fontWeight automatically. Phone/touch UI
        // keeps the platform default (null) so it stays byte-identical.
        fontFamily: hasTouchScreen ? null : 'Inter',
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
                // fix707 (TV GUI redesign): accent focus ring (default white)
                // instead of flat yellow — completes the accent-ring language
                // across TV chrome (buttons / dialogs / gear). Non-const: reads
                // appAccentNotifier at theme-build time. Accent is white today
                // (no picker UI yet); a future accent-preset unit adds live
                // reactivity by rebuilding the theme when the notifier changes.
                return BorderSide(
                  color: appAccentNotifier.value,
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
                return BorderSide(color: appAccentNotifier.value, width: 3); // fix707: accent, was yellow
              }
              return null;
            }),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && !hasTouchScreen) {
                return BorderSide(color: appAccentNotifier.value, width: 3); // fix707: accent, was yellow
              }
              return null;
            }),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused) && !hasTouchScreen) {
                return BorderSide(color: appAccentNotifier.value, width: 3); // fix707: accent, was yellow
              }
              return null;
            }),
          ),
        ),
        // fix720 (TV GUI redesign, Phase 5): tokenize the modal bottom sheets
        // (e.g. the channel context menu, fix586) to the redesign glass look —
        // dark glass fill + rounded top corners — so they match the migrated
        // dialogs/menus instead of the flat Material sheet. TV only: null on the
        // phone/touch path keeps the Material default (byte-identical). Values
        // mirror F4Tokens (glassFill 0xCC0B0F19, radius.modal 20) as literals
        // since ThemeData is built without an F4.of(context) here.
        bottomSheetTheme: hasTouchScreen
            ? null
            : const BottomSheetThemeData(
                backgroundColor: Color(0xF00B0F19),
                modalBackgroundColor: Color(0xF00B0F19),
                surfaceTintColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(20)),
                ),
              ),
        // fix721 (TV GUI redesign, Phase 5): match the AlertDialog/SelectDialog
        // surfaces to the same redesign glass as the bottom sheets (fix720) so
        // confirm/select/"Re-match Complete" dialogs read as migrated too. Same
        // TV-gate (null on phone → Material default, byte-identical) + same F4
        // glass literals (0xF00B0F19, radius.modal 20; all corners since a
        // dialog floats).
        dialogTheme: hasTouchScreen
            ? null
            : const DialogThemeData(
                backgroundColor: Color(0xF00B0F19),
                surfaceTintColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(20)),
                ),
              ),
        useMaterial3: true,
        // fix701 (TV GUI redesign, Phase 0): attach the static TV token tree so
        // TV widgets can read it via F4.of(context). Inert for the phone path —
        // phone widgets never read the extension, so the touch UI is unchanged.
        extensions: const <ThemeExtension<dynamic>>[F4Tokens()],
      ),
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      home: _RootPage(
        skipSetup: skipSetup,
        settings: settings,
        hasTouchScreen: hasTouchScreen,
        isTV: isTV,
      ),
      ), // fix719: close MaterialApp
    ); // fix719: close ValueListenableBuilder
  }
}
