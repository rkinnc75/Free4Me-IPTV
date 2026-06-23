// fix390: Search method auto-set on first run for low-RAM devices.
//
// On a device with less than 2300 MB total RAM (matching
// `ChannelSearchCache._minRamMbForCache`), the in-memory search cache is
// never built (see `ChannelSearchCache.cacheSkipped`). Before this fix, the
// default `Settings.searchMethod` was `inMemory`, so a user on an onn 4K
// Plus (1.9 GB) would see "in-memory search" in Settings while the actual
// search silently fell through to FTS. The setting lied.
//
// fix505: on first run (no persisted `searchMethod`), the low-RAM default is
// `SearchMethod.ftsTrigram` — the index-backed channels_fts path, fast on huge
// catalogues where the previous `likeSubstring` (fix390) full-scanned. A
// persisted value always wins — the auto-set is a first-run default only.
//
// These tests exercise the real `SettingsService.resolveSearchMethod`
// helper, which is the same code `_readFromDb` uses, with explicit `totalMb`
// values so they don't depend on the host's `DeviceMemory.totalMb`.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/models/settings.dart';

void main() {
  group('resolveSearchMethod (fix390 first-run auto-set)', () {
    test('first run + low RAM (1.9 GB onn 4K Plus) → ftsTrigram (fix505)', () {
      expect(
        SettingsService.resolveSearchMethod(null, totalMb: 1900),
        SearchMethod.ftsTrigram,
      );
    });

    test('first run + mid-low RAM (just under 2300 MB) → ftsTrigram (fix505)', () {
      expect(
        SettingsService.resolveSearchMethod(null, totalMb: 2299),
        SearchMethod.ftsTrigram,
      );
    });

    test('first run + exactly the 2300 MB threshold → inMemory (not auto)',
        () {
      // The threshold is `< lowRamThresholdMb`, so 2300 itself is NOT low
      // RAM — it gets the recommended in-memory default.
      expect(
        SettingsService.resolveSearchMethod(null, totalMb: 2300),
        SearchMethod.inMemory,
      );
    });

    test('first run + high RAM (4 GB phone) → inMemory (recommended default)',
        () {
      expect(
        SettingsService.resolveSearchMethod(null, totalMb: 4096),
        SearchMethod.inMemory,
      );
    });

    test('persisted ftsAnd on low-RAM device → ftsAnd (persisted wins)', () {
      // A user who explicitly chose FTS on a low-RAM device keeps that
      // choice across upgrades. The auto-set does NOT override an existing
      // user decision.
      expect(
        SettingsService.resolveSearchMethod(
          SearchMethod.ftsAnd.index.toString(),
          totalMb: 1900,
        ),
        SearchMethod.ftsAnd,
      );
    });

    test('persisted inMemory on low-RAM device → inMemory (persisted wins)',
        () {
      // A user who chose in-memory on a low-RAM device keeps the setting.
      // The runtime safety net (`ChannelSearchCache.cacheSkipped`) still
      // routes searches to FTS internally; the user-visible setting
      // matches the user's explicit choice.
      expect(
        SettingsService.resolveSearchMethod(
          SearchMethod.inMemory.index.toString(),
          totalMb: 1900,
        ),
        SearchMethod.inMemory,
      );
    });

    test('persisted likeSubstring on high-RAM device → likeSubstring', () {
      // The auto-set only fires on first run. A user who chose LIKE on a
      // high-RAM device keeps that choice.
      expect(
        SettingsService.resolveSearchMethod(
          SearchMethod.likeSubstring.index.toString(),
          totalMb: 4096,
        ),
        SearchMethod.likeSubstring,
      );
    });

    test('garbage persisted value → ftsTrigram (preserved pre-fix behavior)', () {
      // Pre-fix behavior: an unparseable stored string coerces to
      // index 0 (the first SearchMethod, ftsTrigram). The trailing
      // `?? SearchMethod.inMemory` only fires when the value is out of
      // range, NOT when it's unparseable. This test pins the existing
      // behavior so the fix doesn't accidentally change it.
      expect(
        SettingsService.resolveSearchMethod('not-a-number', totalMb: 4096),
        SearchMethod.ftsTrigram,
      );
    });

    test('out-of-range persisted value → inMemory (the `??` fallback fires)', () {
      // SearchMethod.values has 4 entries (indices 0–3); a stored "99"
      // is unparseable AND out of range, so `elementAtOrNull` returns
      // null and the `?? SearchMethod.inMemory` fallback fires.
      expect(
        SettingsService.resolveSearchMethod('99', totalMb: 4096),
        SearchMethod.inMemory,
      );
    });

    test('totalMb=0 (DeviceMemory not yet initialised) → inMemory', () {
      // When DeviceMemory.init() hasn't run yet, totalMb is 0, which is
      // not in `1..2299`, so the auto-set is skipped and the recommended
      // default applies. This is a safety guard for the call site before
      // init completes.
      expect(
        SettingsService.resolveSearchMethod(null, totalMb: 0),
        SearchMethod.inMemory,
      );
    });
  });
}
