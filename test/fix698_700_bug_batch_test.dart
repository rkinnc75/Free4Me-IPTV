// Bug batch (owner-reported on v4.1.5, diagnosed from the private log + code):
//   fix698 — Recordings REC dot "never blinks": (a) too-subtle pulse, and
//            (b) the screen never live-refreshed so the recording state was
//            rarely rendered while open.
//   fix699 — slow first channel open: player open() bound the surface too late,
//            forcing a vo=null→gpu mediacodec restart. Gate open() on the
//            texture id.
//   fix700 — live stutter / watch-while-recording contention: opt-in live
//            pre-buffer (default OFF) that refills to a cushion instead of
//            thrashing at ~0s cache.
//
// These behaviours are UI/engine/settings-coupled and hard to host-unit-test, so
// this pins the decisions by source invariant (same approach as
// fix696/fix697 tests).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

void main() {
  final rec = File('lib/recordings_view.dart').readAsStringSync();
  final mpv = File('lib/player/mpv_engine.dart').readAsStringSync();
  final settings = File('lib/models/settings.dart').readAsStringSync();
  final io = File('lib/backend/settings_io.dart').readAsStringSync();
  final svc = File('lib/backend/settings_service.dart').readAsStringSync();
  final view = File('lib/settings_view.dart').readAsStringSync();

  group('fix698 — red dot blink + live refresh', () {
    test('blink is crisper: 450ms + deeper swing to 0.15', () {
      final dot = _slice(rec, 'class _BlinkingDotState', 'class _RecordingTile');
      expect(dot.contains('milliseconds: 450'), isTrue);
      expect(dot.contains('Tween<double>(begin: 1, end: 0.15)'), isTrue);
      expect(dot.contains('repeat(reverse: true)'), isTrue); // still oscillates
      // review fix: the curved animation is built ONCE (drive/chain), not per
      // build() — no CurvedAnimation status-listener leak on the 3s poll ticks.
      expect(dot.contains('_c.drive('), isTrue);
      expect(dot.contains('CurvedAnimation(parent: _c'), isFalse);
    });

    test('RecordingsView live-refresh poll while a row is transient', () {
      final st = _slice(rec, 'class _RecordingsViewState', 'void _showCompletionSnacks');
      expect(st.contains('Timer? _poll'), isTrue);
      // quiet reload avoids the full-screen spinner on each tick
      expect(st.contains('Future<void> _load({bool quiet = false})'), isTrue);
      expect(st.contains('if (!quiet) setState(() => _loading = true)'), isTrue);
      // poll gated on transient states; self-cancels when all terminal
      final poll = _slice(rec, 'void _syncPoll()', '(IconData, Color, String) _statusChip');
      expect(poll.contains('RecordingStatus.scheduled'), isTrue);
      expect(poll.contains('RecordingStatus.recording'), isTrue);
      expect(poll.contains('RecordingStatus.compressing'), isTrue);
      // review fix: far-future scheduled rows must NOT keep the poll running —
      // only imminent scheduled (start within the window) counts as transient.
      expect(poll.contains('r.startTime.isBefore(soon)'), isTrue);
      expect(poll.contains('Timer.periodic'), isTrue);
      expect(poll.contains('_poll?.cancel()'), isTrue);
      // cancelled in dispose (no setState-after-dispose)
      final disp = _slice(rec, 'void dispose()', 'Future<void> _load');
      expect(disp.contains('_poll?.cancel()'), isTrue);
    });
  });

  group('fix699 — open() texture-id gate', () {
    test('an extra un-locked wait for the texture before open(), !previewMode', () {
      // The locked concurrency wait stays; a SECOND bounded wait runs after the
      // lock is released (initDone completed) and only for the full-screen path.
      final open = _slice(mpv, 'final prevInit = _textureInitChain;',
          'await _player.open(');
      expect(open.contains('initDone.complete()'), isTrue);
      // second wait is after the finally, gated on !previewMode
      final after = _slice(open, 'initDone.complete()', '');
      expect(
          after.contains('if (!previewMode)') &&
              after.contains('_waitForTextureId(_controller'),
          isTrue,
          reason: 'un-locked full-screen texture wait must precede open()');
    });
  });

  group('fix700 — opt-in live pre-buffer', () {
    test('settings field defaults OFF (0) — live behaviour unchanged by default', () {
      expect(settings.contains('int livePrebufferSecs;'), isTrue);
      expect(settings.contains('this.livePrebufferSecs = 0'), isTrue);
      expect(settings.contains('s.livePrebufferSecs = 0'), isTrue); // reset
    });

    test('persisted in both settings_io and settings_service', () {
      expect(io.contains("'livePrebufferSecs': s.livePrebufferSecs"), isTrue);
      expect(io.contains("livePrebufferSecs: m['livePrebufferSecs'] as int? ?? 0"),
          isTrue);
      expect(svc.contains('livePrebufferSecsProp = "livePrebufferSecs"'), isTrue);
      expect(svc.contains('settings.livePrebufferSecs = int.parse(livePre)'),
          isTrue);
    });

    test('mpv live branch applies cache-pause only when >0 and not DVR', () {
      // Must be inside the LIVE branch, gated on the setting AND dvrBackMB<=0.
      expect(
          mpv.contains(
              'if (s.livePrebufferSecs > 0 && dvrBackMB <= 0) {'),
          isTrue);
      final block = _slice(mpv, 'if (s.livePrebufferSecs > 0 && dvrBackMB <= 0) {', '} else {');
      // review fix: force cache-pause on, else the low-latency profile's
      // cache-pause=no makes the pre-buffer a silent no-op.
      expect(block.contains("setProperty('cache-pause', 'yes')"), isTrue);
      expect(block.contains("setProperty('cache-pause-initial', 'yes')"), isTrue);
      expect(block.contains("setProperty('cache-pause-wait', s.livePrebufferSecs.toString())"),
          isTrue);
      // fix354's VOD pre-buffer must remain untouched (still present).
      expect(mpv.contains('if (s.vodPrebufferSecs > 0) {'), isTrue);
    });

    test('settings UI exposes a Live pre-buffer slider', () {
      expect(view.contains('"Live pre-buffer (seconds)"'), isTrue);
      expect(view.contains('settings.livePrebufferSecs = v.round()'), isTrue);
      expect(view.contains('_helpLivePrebufferSecs'), isTrue);
    });
  });
}
