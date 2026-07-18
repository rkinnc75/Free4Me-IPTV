// fix757: two follow-ups from the fix756 adversarial review of the
// scheduled-recording status journal.
//
// Finding 2 — no drain re-entrancy guard. drain() is main-isolate only (sole
// caller recordings_view._load: initState + a 3s Timer.periodic that does not
// skip ticks + stop/cancel/delete). Overlapping drains could double-adopt or
// rename-clobber the `.processing` batch. Fix: a single-flight guard so a
// concurrent second drain is a no-op.
//
// Finding 1 — re-applying a stale ADOPTED batch could revert a remuxed row.
// After remux, a row is done+`.mp4` and its `.ts` is deleted. If the applied
// batch's `.processing` survives (a delete failure) and is re-drained, the old
// done+`.ts` line was re-applied — COALESCE overwrote the live `.mp4` URI with
// the dead `.ts`, then remux re-triggered and _revertDone pinned the dead file.
// Fix: an adopted re-drain skips a done line that would DOWNGRADE an already-
// done row to a different output path.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final journal =
      File('lib/backend/recording_status_journal.dart').readAsStringSync();

  test('finding 2: drain() is single-flight (guard + delegate to _drainOnce)',
      () {
    expect(journal.contains('static bool _draining = false;'), isTrue);
    final idx =
        journal.indexOf('static Future<List<RecordingCompletion>> drain()');
    expect(idx, greaterThan(0));
    final wrapper = journal.substring(idx, idx + 320);
    expect(wrapper.contains('if (_draining) return const [];'), isTrue);
    expect(wrapper.contains('_draining = true;'), isTrue);
    expect(wrapper.contains('return await _drainOnce();'), isTrue);
    expect(wrapper.contains('_draining = false;'), isTrue); // finally
    // the real work moved to _drainOnce (still renames-before-read etc.)
    expect(journal.contains('static Future<List<RecordingCompletion>> _drainOnce()'),
        isTrue);
  });

  test('finding 1: an adopted batch skips a done line that would downgrade a '
      'remuxed row', () {
    // batch adoption is flagged
    expect(journal.contains('adopted = true;'), isTrue);
    // the guard: only for an adopted re-drain, only for a done line, and only
    // when the current row is already done with a DIFFERENT non-null path
    expect(
        journal.contains(
            'if (adopted &&\n            status == RecordingStatus.done &&'),
        isTrue);
    expect(journal.contains('final current = await Sql.getRecordingById(id);'),
        isTrue);
    expect(journal.contains('current.outputPath != outputPath'), isTrue);
    // the guard skips the line (does not re-apply / re-trigger remux)
    final idxGuard = journal.indexOf('if (adopted &&');
    final body = journal.substring(idxGuard, idxGuard + 500);
    expect(body.contains('continue;'), isTrue);
  });
}
