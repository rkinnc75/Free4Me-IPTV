// fix756: the Scheduled Recording status journal must be drained from a
// RENAMED batch file, never from the live `sr_status.jsonl` that
// RecordingCaptureService can still append to. The old drain read the live
// file, awaited per-row DB updates, then truncated that same live file; a
// native status appended between read and truncate was erased unapplied and
// the row could stay stuck on scheduled/recording/compressing.
//
// Design pins:
// - live filename stays `sr_status.jsonl` (native writer unchanged).
// - drain renames/adopts `sr_status.jsonl.processing` BEFORE `readAsString`.
// - `_truncate`/live `writeAsString('')` is gone; the applied batch is deleted.
// - a pre-existing `.processing` file is drained first (crash recovery).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final journal =
      File('lib/backend/recording_status_journal.dart').readAsStringSync();

  test('live journal filename is unchanged for native compatibility', () {
    expect(journal.contains("static const String fileName = 'sr_status.jsonl';"),
        isTrue);
  });

  test('drain renames/adopts the processing batch before reading', () {
    final idx = journal.indexOf('static Future<List<RecordingCompletion>> drain()');
    expect(idx, greaterThan(0));
    final body = journal.substring(idx, idx + 2600);
    final idxProcessing = body.indexOf("File('\${f.path}.processing')");
    final idxRead = body.indexOf('readAsString()');
    expect(idxProcessing, greaterThan(0));
    expect(idxRead, greaterThan(idxProcessing));
    expect(body.contains('if (await processing.exists())'), isTrue);
    expect(body.contains('await f.rename(processing.path)'), isTrue);
  });

  test('applied batch is deleted; live truncate path is gone', () {
    expect(journal.contains('_deleteProcessed(f);'), isTrue);
    expect(journal.contains('await f.delete();'), isTrue);
    expect(journal.contains('_truncate('), isFalse,
        reason: 'fix756: no read/apply/truncate of the shared live journal');
    expect(journal.contains("writeAsString('', flush: true)"), isFalse);
  });
}
