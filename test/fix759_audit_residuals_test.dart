// fix759: three residuals from the June-2026 code audit.
//
//   #3 — settings backup import left the slider-backed EPG fields unclamped, so
//        a hand-edited / older backup with e.g. epgForecastDays <= 0 crashed the
//        settings screen (search slider max=0, divisions=-1). All slider-backed
//        EPG fields are now clamped to their documented ranges on import.
//   #5 — credentials in a URL *authority* (`http://user:pass@host/...`) were in
//        neither s.username/password nor the query string, so only the host was
//        masked and the `user:pass@` prefix leaked. setSourceSecrets now also
//        registers the userInfo (and its user:pass split).
//   #6 — a brand-new source's URL is logged (Utils.processSource -> xtream/m3u)
//        before setSourceSecrets is rebuilt with it, so its host/creds leaked on
//        the very first add. addSourceSecrets registers a new source additively.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';

Source _src({
  required String name,
  SourceType type = SourceType.xtream,
  String? url,
  String? username,
  String? password,
  String? epgUrl,
}) =>
    Source(
      name: name,
      sourceType: type,
      url: url,
      username: username,
      password: password,
      epgUrl: epgUrl,
    );

void main() {
  final logger = AppLogger.instance;

  group('#5: URL userinfo authority (user:pass@host) is redacted', () {
    test('m3u URL with embedded user:pass (null user/pass fields)', () {
      final s = _src(
        name: 'U',
        type: SourceType.m3uUrl,
        url: 'http://joeuser:s3cretpw@host.example/playlist.m3u',
      );
      logger.setSourceSecrets([s]);
      final out = logger.scrubSecrets(
          'M3U: downloading source="U" '
          'url="http://joeuser:s3cretpw@host.example/playlist.m3u"');
      expect(out, isNot(contains('joeuser')));
      expect(out, isNot(contains('s3cretpw')));
      expect(out, isNot(contains('host.example'))); // host still masked
    });

    test('short userinfo (<3 chars) is not registered', () {
      final s = _src(
          name: 'Z', type: SourceType.m3uUrl, url: 'http://ab@host/x.m3u');
      logger.setSourceSecrets([s]);
      // 'ab' must NOT become a redaction literal.
      expect(logger.scrubSecrets('crab abacus'), equals('crab abacus'));
    });
  });

  group('#6: addSourceSecrets registers a new source without a full rebuild',
      () {
    test('a source added via addSourceSecrets is redacted immediately', () {
      final a = _src(name: 'A', url: 'http://a.host/');
      logger.setSourceSecrets([a]); // simulates the last full rebuild
      final b = _src(
        name: 'B',
        type: SourceType.m3uUrl,
        url: 'http://buser:bpass@b.host/list.m3u',
      );
      logger.addSourceSecrets(b);
      final out = logger.scrubSecrets(
          'processSource "B" url="http://buser:bpass@b.host/list.m3u"');
      expect(out, isNot(contains('buser')));
      expect(out, isNot(contains('bpass')));
      expect(out, isNot(contains('b.host')));
      // the previously-known source A stays masked (not wiped by the add)
      expect(logger.scrubSecrets('hit a.host here'),
          isNot(contains('a.host')));
    });

    test('re-adding a known source is idempotent (no unbounded growth)', () {
      final a = _src(name: 'A', url: 'http://a.host/');
      logger.setSourceSecrets([a]);
      // processSource re-runs on every refresh — repeated adds of the SAME
      // source must be a no-op, not grow the table.
      for (var i = 0; i < 5; i++) {
        logger.addSourceSecrets(a);
      }
      expect(logger.scrubSecrets('a.host'), isNot(contains('a.host')));
    });
  });

  group('#3: EPG import clamp (source check — _settingsFromMap is private)', () {
    final io = File('lib/backend/settings_io.dart').readAsStringSync();

    test('forecast is clamped to its slider range [3, 14]', () {
      expect(
          io.contains(
              "((m['epgForecastDays'] as int?) ?? 7).clamp(3, 14)"),
          isTrue);
    });

    test('search hours clamp against the already-clamped forecast window', () {
      expect(io.contains('final epgForecastDays ='), isTrue);
      expect(
          io.contains(
              "((m['epgSearchHours'] as int?) ?? 3).clamp(1, epgForecastDays * 24)"),
          isTrue);
    });

    test('the other slider-backed EPG fields are clamped too', () {
      expect(io.contains("((m['epgRefreshHours'] as int?) ?? 24).clamp(6, 168)"),
          isTrue);
      expect(io.contains("((m['epgRefreshHour'] as int?) ?? 3).clamp(0, 23)"),
          isTrue);
      expect(io.contains("((m['epgPastDays'] as int?) ?? 1).clamp(0, 3)"),
          isTrue);
    });
  });
}
