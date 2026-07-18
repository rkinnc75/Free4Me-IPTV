// fix755: first-install (and the add-source wizard) always landed in PHONE
// mode until the next app launch, even on a TV. Root cause: the "TV shell vs
// phone shell" decision was DUPLICATED — main.dart applied
// (forceTVMode || isTV || no-touch) at startup, but setup.dart's
// navigateToHome() hardcoded the phone Home(), so every setup-completion path
// (first install, and re-adding a source) navigated to phone mode; only the
// NEXT cold start re-evaluated detection and switched to TV.
//
// Fix: extract the decision into one shared helper DeviceDetector.useTvShell so
// the two sites can't diverge again, and make navigateToHome() apply it (build
// TvHome when appropriate) using the startup-warmed isTV/hasTouchScreen caches.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final dd = File('lib/models/device_detector.dart').readAsStringSync();
  final main = File('lib/main.dart').readAsStringSync();
  final setup = File('lib/setup.dart').readAsStringSync();

  test('DeviceDetector.useTvShell is the single decision helper', () {
    expect(
        dd.contains('static bool useTvShell({'), isTrue);
    // the exact decision (forceTVMode OR isTV OR no-touch on a mobile platform)
    expect(
        dd.contains(
            '(!hasTouchScreen && (Platform.isAndroid || Platform.isIOS))'),
        isTrue);
    expect(dd.contains('forceTVMode ||'), isTrue);
  });

  test('main.dart startup uses the shared helper (no inline duplicate)', () {
    expect(main.contains('DeviceDetector.useTvShell('), isTrue);
    // the old inline triple-condition is gone from main
    expect(
        main.contains(
            '(!widget.hasTouchScreen && (Platform.isAndroid || Platform.isIOS))'),
        isFalse);
  });

  test('setup navigateToHome applies the decision and can build TvHome', () {
    // no longer unconditionally the phone Home
    final idx = setup.indexOf('void navigateToHome() {');
    expect(idx, greaterThan(0));
    final body = setup.substring(idx, idx + 1300);
    expect(body.contains('DeviceDetector.useTvShell('), isTrue);
    expect(body.contains('TvHome(settings: settings)'), isTrue);
    // still falls back to the phone Home when not a TV
    expect(body.contains('Home('), isTrue);
    // resolves the (startup-cached) detection inputs
    expect(body.contains('await DeviceDetector.isTV()'), isTrue);
    expect(body.contains('await Utils.hasTouchScreen()'), isTrue);
  });
}
