// fix717 — route "Re-match all" (settings) through the SAME match gate the
// refresh path uses (fix709's _serializeMatch), so a user-triggered Re-match
// can't collide on the db.sqlite writer + WAL TRUNCATE with a concurrent
// scheduled / background / source refresh (the SQLITE_BUSY-→silently-unmatched
// bug). The gate is one static field, so all gated callers serialize together.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final epg = File('lib/backend/epg_service.dart').readAsStringSync();
  final settings = File('lib/settings_view.dart').readAsStringSync();

  group('fix717 gated re-match', () {
    test('EpgService exposes a public gated wrapper', () {
      expect(epg.contains('static Future<void> matchChannelsSerialized('),
          isTrue);
      // the wrapper is the thing that goes through the gate
      expect(epg.contains('_serializeMatch(() => matchChannels('), isTrue);
    });

    test('settings Re-match uses the gated wrapper, not raw matchChannels', () {
      expect(settings.contains('EpgService.matchChannelsSerialized('), isTrue);
      expect(settings.contains('EpgService.matchChannels('), isFalse);
    });

    test('refreshSource also routes through the wrapper (single gate source)',
        () {
      // no path re-implements the gate inline anymore; refreshSource calls the
      // public wrapper too.
      expect(epg.contains('await matchChannelsSerialized('), isTrue);
    });

    test('matchChannels is only ever called from inside the wrapper', () {
      // "matchChannels(" never appears in "matchChannelsSerialized(" (the "("
      // follows "Serialized"), so this counts only the raw name. Exactly two:
      // the definition header, and the single call inside the wrapper.
      final callSites = RegExp(r'matchChannels\(').allMatches(epg).length;
      expect(callSites, 2);
    });
  });
}
