// fix712 — serialize the multi-source EPG refresh (maxConcurrent=1). fix709
// serialized only the channel-MATCH phase, but on-device verification proved the
// DOWNLOAD/PARSE phase also races under concurrent multi-source refresh: a
// starved temp-XML fetch (0 programs) + exhausted SQLITE_BUSY retries on the
// epg_refresh_log / insert writes ("database is locked, code 5"). Refreshing
// sources ONE AT A TIME matches the proven-good single-source path and removes
// the whole class of cross-source contention (temp files, DB writes, match).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/backend/epg_service.dart').readAsStringSync();

  test('refreshAllSources runs sources one at a time', () {
    expect(src.contains('const maxConcurrent = 1;'), isTrue);
    expect(src.contains('const maxConcurrent = 2;'), isFalse,
        reason: 'the old parallel default must be gone');
  });

  test('the chunked loop still exists (serial with chunk size 1)', () {
    // structure preserved; only the concurrency width changed
    expect(src.contains('for (var i = 0; i < eligible.length; i += maxConcurrent)'),
        isTrue);
    expect(src.contains('await Future.wait(chunk.map((s) async {'), isTrue);
  });

  test('fix709 match gate is kept (belt-and-suspenders under serial)', () {
    expect(src.contains('_serializeMatch(() => matchChannels('), isTrue);
  });

  test('the disproven parallel-download rationale is corrected', () {
    // the old comment claimed HTTP fetches "don't fight"; fix712 documents the
    // on-device disproof
    expect(src.contains('on-device verification'), isTrue);
    expect(src.contains("HTTP fetches don't fight each other and the"), isFalse,
        reason: 'the old (wrong) claim should be gone from the live comment');
  });
}
