// fix694: single-source refresh FTS finalization must use DROP+repopulate
// (rebuildFtsTableFromScratch), never the fts5 'rebuild' command path
// (reconcileFtsTriggers(true)). Measured on the onn 2026-07-08 baseline
// (1.16M-row catalog): 'rebuild' = 231s, DROP+repopulate = 41.6s — identical
// end state (fresh index + byte-identical triggers). Also: the fix620
// integrity-check pre-flight moved from Utils.refreshSource (paid on EVERY
// refresh, 10.9s) into the targeted branch of withSuspendedFtsTriggers (the
// only code it protects).
//
// Source-invariant guards (the behavior is inside DbFactory-coupled code, so
// mirror-testing the SQL is done by the existing fts_* suites; these pin the
// call-graph decisions that deliver the fix694 win).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  group('fix694 FTS finalization contract', () {
    test('withSuspendedFtsTriggers big-source path uses DROP+repopulate', () {
      final src = File('lib/backend/sql.dart').readAsStringSync();
      final start = src.indexOf('Future<void> withSuspendedFtsTriggers');
      expect(start, greaterThan(0));
      // Slice to the end of the method's finally chain (next static member).
      final end = src.indexOf('static const int _ftsTargetedMaxRows', start);
      final body = _stripComments(src.substring(start, end));
      expect(body.contains('rebuildFtsTableFromScratch('), isTrue,
          reason: 'the non-targeted finalization must DROP+repopulate');
      expect(body.contains('reconcileFtsTriggers(true)'), isFalse,
          reason: "the 231s fts5 'rebuild' path must not be reachable from the "
              'refresh finalization (fix694). reconcileFtsTriggers(true, '
              'skipRebuild: true) in the targeted branch is fine.');
    });

    test('refreshSource no longer runs the pre-flight integrity check', () {
      final src = File('lib/backend/utils.dart').readAsStringSync();
      final start = src.indexOf('Future<void> refreshSource');
      final end = src.indexOf('Future<void> processSource', start);
      final body = _stripComments(src.substring(start, end));
      expect(body.contains('ensureFtsHealthy'), isFalse,
          reason: 'fix620 pre-flight moved into the targeted branch of '
              'withSuspendedFtsTriggers (fix694) — it must not be paid on '
              'every refresh');
    });

    test('targeted branch carries its own integrity check', () {
      final src = File('lib/backend/sql.dart').readAsStringSync();
      final start = src.indexOf('Future<void> withSuspendedFtsTriggers');
      final end = src.indexOf('static const int _ftsTargetedMaxRows', start);
      final body = _stripComments(src.substring(start, end));
      expect(body.contains("VALUES('integrity-check')"), isTrue,
          reason: 'the corrupt-index hang protection (fix620) must still '
              'guard the targeted delete');
    });
  });
}
