// fix726 (mock §4.1) — OLED-black background toggle. A persisted Settings flag +
// an app-wide notifier the TV shell listens to, so turning it on swaps the neon
// tv_background.webp for pure #000000 live. TV only; phone unchanged.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/tv/theme/accent_scope.dart';

void main() {
  final settings = File('lib/models/settings.dart').readAsStringSync();
  final svc = File('lib/backend/settings_service.dart').readAsStringSync();
  final main = File('lib/main.dart').readAsStringSync();
  final shell = File('lib/tv/tv_shell.dart').readAsStringSync();
  final view = File('lib/settings_view.dart').readAsStringSync();

  test('appOledNotifier exists (default off)', () {
    expect(appOledNotifier.value, isFalse);
  });
  test('Settings persists oledBlack (default false)', () {
    expect(settings.contains('bool oledBlack;'), isTrue);
    expect(settings.contains('this.oledBlack = false'), isTrue);
  });
  test('settings_service round-trips oledBlack', () {
    expect(svc.contains('oledBlackProp'), isTrue);
    expect(svc.contains("settings.oledBlack = oledBk == 'true'"), isTrue);
    expect(svc.contains('settingsMap[oledBlackProp] = settings.oledBlack'),
        isTrue);
  });
  test('main restores oledBlack at startup', () {
    expect(main.contains('appOledNotifier.value = settings.oledBlack'), isTrue);
  });
  test('shell swaps bg → pure black on OLED, else the webp (live)', () {
    expect(shell.contains('valueListenable: appOledNotifier'), isTrue);
    expect(shell.contains('ColoredBox(color: Color(0xFF000000))'), isTrue);
    expect(shell.contains("AssetImage('assets/tv_background.webp')"), isTrue);
  });
  test('settings has a TV-gated OLED toggle that persists + swaps live', () {
    expect(view.contains('OLED-black background'), isTrue);
    expect(view.contains('appOledNotifier.value = v'), isTrue);
    expect(view.contains('settings.oledBlack = v'), isTrue);
  });
}
