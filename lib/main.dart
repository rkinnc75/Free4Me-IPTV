import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:open_tv/backend/app_logger.dart';
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
  // DeviceMemory must run before SettingsService.getSettings() so that
  // first-run defaults (based on detected RAM) are available when settings
  // are read and written for the first time.
  await DeviceMemory.init();
  // Parallelize all cold-start awaits — settings loaded once and cached.
  final results = await Future.wait([
    Sql.hasSources(),
    SettingsService.getSettings(),
    Utils.hasTouchScreen(),
    DeviceDetector.isTV(),
  ]);
  final hasSources = results[0] as bool;
  final settings = results[1] as Settings;
  final hasTouchScreen = results[2] as bool;
  final isTV = results[3] as bool;
  await AppLog.setEnabled(settings.debugLogging);
  final packageInfo = await PackageInfo.fromPlatform();
  AppLog.info(
    'App started — version=${packageInfo.version}'
    ' build=${packageInfo.buildNumber}',
  );
  // Ensure WorkManager registration matches the persisted epgAutoRefresh pref.
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

class _RootPageState extends State<_RootPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdateChecker.checkOnLaunch(context);
    });
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
