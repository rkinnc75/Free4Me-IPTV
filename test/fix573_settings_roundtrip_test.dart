// fix573: three settings (multiViewDecode, devControlsHideSecs, playerZoomMode)
// were persisted normally but DROPPED from the backup payload — so a
// backup/restore silently reset them to defaults (backlog #11). This pins all
// three through the serialize→restore round-trip so the next dropped field is
// caught.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/settings_io.dart';
import 'package:open_tv/models/multi_view_decode.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/zoom_mode.dart';

void main() {
  test('fix573: backup round-trip preserves the formerly-dropped fields', () {
    // Set each field to a NON-default value so a dropped field (which would
    // fall back to its default on restore) is detectable.
    final s = Settings.defaults()
      ..multiViewDecode = MultiViewDecode.software // default is auto
      ..devControlsHideSecs = 7 // default is 3
      ..playerZoomMode = ZoomMode.crop; // default is fit

    final r = SettingsIo.roundTripForTest(s);

    expect(r.multiViewDecode, MultiViewDecode.software);
    expect(r.devControlsHideSecs, 7);
    expect(r.playerZoomMode, ZoomMode.crop);
  });

  test('fix667: record pad settings survive backup round-trip', () {
    final s = Settings.defaults()
      ..recordPadBeforeMin = 5 // default 1
      ..recordPadAfterMin = 90; // default 1

    final r = SettingsIo.roundTripForTest(s);

    expect(r.recordPadBeforeMin, 5);
    expect(r.recordPadAfterMin, 90);
  });

  test('fix665: TV home-row settings survive backup round-trip', () {
    final s = Settings.defaults()
      ..tvHomeRowEnabled = true // default false
      ..tvHomeRowCount = 15; // default 10

    final r = SettingsIo.roundTripForTest(s);

    expect(r.tvHomeRowEnabled, isTrue);
    expect(r.tvHomeRowCount, 15);
  });

  test('fix573: the other non-default values also survive (no aliasing)', () {
    final s = Settings.defaults()
      ..multiViewDecode = MultiViewDecode.hardwareCopy
      ..playerZoomMode = ZoomMode.stretch
      ..devControlsHideSecs = 0;

    final r = SettingsIo.roundTripForTest(s);

    expect(r.multiViewDecode, MultiViewDecode.hardwareCopy);
    expect(r.playerZoomMode, ZoomMode.stretch);
    expect(r.devControlsHideSecs, 0);
  });

  test('finding 95: use24HourTime survives the backup round-trip', () {
    // Default is false; set true so a dropped field is detectable.
    final s = Settings.defaults()..use24HourTime = true;
    final r = SettingsIo.roundTripForTest(s);
    expect(r.use24HourTime, isTrue);
  });
}
