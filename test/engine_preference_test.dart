// fix325: lock in the EnginePreference contract (fix315/fix316).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/models/engine_preference.dart';
import 'package:open_tv/models/engine_type.dart';

void main() {
  group('EnginePreference', () {
    test('primary engine per preference', () {
      expect(EnginePreference.libmpvExo.primary, EngineType.libmpv);
      expect(EnginePreference.libmpvOnly.primary, EngineType.libmpv);
      expect(EnginePreference.exoLibmpv.primary, EngineType.exoplayer);
      expect(EnginePreference.exoOnly.primary, EngineType.exoplayer);
    });

    test('fallback engine per preference', () {
      expect(EnginePreference.libmpvExo.fallback, EngineType.exoplayer);
      expect(EnginePreference.exoLibmpv.fallback, EngineType.libmpv);
      // Single-engine prefs report their own engine as "fallback".
      expect(EnginePreference.libmpvOnly.fallback, EngineType.libmpv);
      expect(EnginePreference.exoOnly.fallback, EngineType.exoplayer);
    });

    test('hasFallback only for two-engine preferences', () {
      expect(EnginePreference.libmpvExo.hasFallback, isTrue);
      expect(EnginePreference.exoLibmpv.hasFallback, isTrue);
      expect(EnginePreference.libmpvOnly.hasFallback, isFalse);
      expect(EnginePreference.exoOnly.hasFallback, isFalse);
    });

    test('fromJson: legacy "auto" and unknowns map to default libmpvExo', () {
      expect(EnginePreference.fromJson('auto'), EnginePreference.libmpvExo);
      expect(EnginePreference.fromJson(null), EnginePreference.libmpvExo);
      expect(EnginePreference.fromJson('garbage'), EnginePreference.libmpvExo);
      expect(EnginePreference.fromJson('exoLibmpv'), EnginePreference.exoLibmpv);
      expect(EnginePreference.fromJson('libmpvOnly'), EnginePreference.libmpvOnly);
      expect(EnginePreference.fromJson('exoOnly'), EnginePreference.exoOnly);
    });

    test('toJson/fromJson round-trip', () {
      for (final p in EnginePreference.values) {
        expect(EnginePreference.fromJson(p.toJson()), p);
      }
    });
  });
}
