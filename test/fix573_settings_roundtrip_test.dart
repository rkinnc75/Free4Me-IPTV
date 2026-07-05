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
