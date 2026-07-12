// fix709 — serialize the EPG channel-MATCH phase across concurrently-refreshing
// sources. refreshAllSources runs sources maxConcurrent=2; two matchChannels at
// once collide on the db.sqlite writer + TRUNCATE checkpoint → SQLITE_BUSY →
// retries exhaust → matchChannels throws → per-source catch swallows it → that
// source's channels are left silently UNMATCHED (guide empty). Fix: an in-isolate
// chained-Future gate serializes the match; downloads stay parallel.
//
// The gate is a private static (`EpgService._serializeMatch`), so this file (a)
// asserts the wiring is present in the source, and (b) proves the gate's LOGIC
// (an identical local replica) actually serializes — no overlap, order kept, and
// a throwing body does not wedge the lock.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('wiring (source)', () {
    final src = File('lib/backend/epg_service.dart').readAsStringSync();

    test('the match gate + serializer exist', () {
      expect(src.contains('static Future<void> _matchGate'), isTrue);
      expect(
          src.contains(
              'static Future<void> _serializeMatch(Future<void> Function() body)'),
          isTrue);
    });

    test('refreshSource routes matchChannels through the gate', () {
      // the match call is wrapped, not called bare
      expect(src.contains('_serializeMatch(() => matchChannels('), isTrue);
      // and the gate never errors out (finally completes it)
      final gate = src.substring(src.indexOf('static Future<void> _serializeMatch'));
      expect(gate.contains('} finally {') && gate.contains('done.complete();'),
          isTrue);
    });
  });

  group('gate logic (behavioural replica of _serializeMatch)', () {
    // identical logic to EpgService._serializeMatch
    Future<void> gate = Future<void>.value();
    Future<void> serialize(Future<void> Function() body) async {
      final prev = gate;
      final done = Completer<void>();
      gate = done.future;
      await prev;
      try {
        await body();
      } finally {
        done.complete();
      }
    }

    setUp(() => gate = Future<void>.value());

    test('concurrent bodies never overlap (serialized)', () async {
      var active = 0;
      var maxActive = 0;
      final order = <int>[];
      Future<void> job(int id) => serialize(() async {
            active++;
            maxActive = maxActive > active ? maxActive : active;
            order.add(id);
            await Future<void>.delayed(const Duration(milliseconds: 5));
            active--;
          });
      // fire all three "at once"
      await Future.wait([job(1), job(2), job(3)]);
      expect(maxActive, 1, reason: 'only one match runs at a time');
      expect(order, [1, 2, 3], reason: 'FIFO order preserved');
    });

    test('a throwing body does not wedge the gate', () async {
      final ran = <int>[];
      final failing = serialize(() async {
        ran.add(1);
        throw StateError('boom');
      });
      await expectLater(failing, throwsA(isA<StateError>()));
      // the next match must still proceed (lock released in finally)
      await serialize(() async {
        ran.add(2);
      });
      expect(ran, [1, 2]);
    });
  });
}
