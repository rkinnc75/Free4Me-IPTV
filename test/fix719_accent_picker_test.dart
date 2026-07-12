// fix719 (Phase 5 — settings) — the TV accent picker. Settings offers a curated
// palette (White + Sky Blue + Amber + Magenta + Green); the choice persists as
// `accentName` and drives appAccentNotifier so every TV focus ring recolors live
// (MaterialApp rebuilds via a ValueListenableBuilder so the theme rings
// re-resolve too). Picker is TV-only; phone settings stay byte-identical.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/tv/theme/accent_scope.dart';

void main() {
  final accent = File('lib/tv/theme/accent_scope.dart').readAsStringSync();
  final settings = File('lib/models/settings.dart').readAsStringSync();
  final svc = File('lib/backend/settings_service.dart').readAsStringSync();
  final main = File('lib/main.dart').readAsStringSync();
  final view = File('lib/settings_view.dart').readAsStringSync();

  group('fix719 accent picker', () {
    test('curated palette = the owner-chosen 5 (White + 4)', () {
      expect(kAccentPresets.length, 5);
      expect(kAccentPresets.first.id, 'white');
      expect(kAccentPresets.map((p) => p.label).toList(),
          ['White', 'Sky Blue', 'Amber', 'Magenta', 'Green']);
    });

    test('accentColorFromId resolves + defaults to White on unknown', () {
      expect(accentColorFromId('green'),
          kAccentPresets.firstWhere((p) => p.id == 'green').color);
      expect(accentColorFromId('bogus'), kAccentPresets.first.color); // White
      expect(accentColorFromId(null), kAccentPresets.first.color);
    });

    test('Settings model persists accentName (default white)', () {
      expect(settings.contains('String accentName;'), isTrue);
      expect(settings.contains("this.accentName = 'white'"), isTrue);
    });

    test('settings_service round-trips accentName (read + write)', () {
      expect(svc.contains('accentNameProp'), isTrue);
      expect(svc.contains('settings.accentName = accentNm'), isTrue);
      expect(svc.contains('settingsMap[accentNameProp] = settings.accentName'),
          isTrue);
    });

    test('main.dart restores the accent at startup + rebuilds theme on change',
        () {
      expect(
          main.contains(
              'appAccentNotifier.value = accentColorFromId(settings.accentName)'),
          isTrue);
      // the theme must re-resolve live → MaterialApp wrapped in a listenable
      expect(main.contains('ValueListenableBuilder<Color>'), isTrue);
      expect(main.contains('valueListenable: appAccentNotifier'), isTrue);
    });

    test('picker is TV-only, persists + updates the notifier live', () {
      expect(view.contains('if (widget.tvRailPane) _accentColorTile()'), isTrue);
      expect(view.contains('appAccentNotifier.value = p.color'), isTrue);
      expect(view.contains('settings.accentName = p.id'), isTrue);
      expect(view.contains('updateSettings()'), isTrue);
    });
  });
}
