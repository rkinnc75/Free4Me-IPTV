// fix697: two SR-UX gaps closed —
//   Item 2: a native completion notification when a recording finishes/fails
//   (the app may be backgrounded/killed, so a Flutter SnackBar can't cover it),
//   plus an in-app SnackBar twin when the Recordings screen is open.
//   Item 1 (orphan): a still-recording row now carries its content:// URI (so
//   "remove file" is offered), and the native service deletes the partial itself
//   on a delete-on-cancel stop — no cross-isolate open-fd race.
//
// The behaviour is native (Kotlin) + filesystem/DB-coupled and RecordingCapture
// no-ops off Android (Platform.isAndroid == false under flutter test), so this
// pins the decisions that make it correct by asserting the source structure —
// the same approach as fix696_deferred_index_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

void main() {
  final svc = File(
    'android/app/src/main/kotlin/me/free4me/iptv/RecordingCaptureService.kt',
  ).readAsStringSync();
  final main = File(
    'android/app/src/main/kotlin/me/free4me/iptv/MainActivity.kt',
  ).readAsStringSync();
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final capture = File('lib/backend/recording_capture.dart').readAsStringSync();
  final journal =
      File('lib/backend/recording_status_journal.dart').readAsStringSync();
  final view = File('lib/recordings_view.dart').readAsStringSync();

  group('fix697 item 2 — native completion notification', () {
    test('a SEPARATE done channel + id range (survives stopForeground)', () {
      expect(svc.contains('DONE_CHANNEL_ID = "free4me_recording_done"'), isTrue);
      expect(svc.contains('DONE_NOTI_ID_BASE = 1_000_000'), isTrue);
      // Must differ from the ongoing-capture channel/id that stopForeground clears.
      expect(svc.contains('CHANNEL_ID = "free4me_recording"'), isTrue);
      expect(svc.contains('NOTI_ID_BASE = 47000'), isTrue);
      expect(svc.contains('DONE_CHANNEL_ID') && svc.contains('CHANNEL_ID'),
          isTrue);
    });

    test('postCompletion notifies with the done id and default importance', () {
      final fn = _slice(svc, 'private fun postCompletion', '\n    private fun stopSelfIfIdle');
      expect(fn, isNotEmpty);
      expect(fn.contains('mgr.notify(DONE_NOTI_ID_BASE + id'), isTrue);
      expect(fn.contains('IMPORTANCE_DEFAULT'), isTrue);
      expect(fn.contains('setAutoCancel(true)'), isTrue);
      expect(fn.contains('"Recording complete"'), isTrue);
      expect(fn.contains('"Recording failed"'), isTrue);
    });

    test('posted on done + both failed branches, gated on !userCancelled', () {
      final rc = _slice(svc, 'private fun runCapture', '// ── MediaStore');
      // success branch
      expect(rc.contains('postCompletion(id, name, true, null)'), isTrue);
      // failed branches (too-little-data + catch)
      expect(
          RegExp('postCompletion\\(id, name, false').allMatches(rc).length >= 2,
          isTrue);
      // Never fires for a user-initiated stop.
      expect(rc.contains('if (!userCancelled) postCompletion'), isTrue);
    });

    test('POST_NOTIFICATIONS declared + requested once on API 33+', () {
      expect(manifest.contains('android.permission.POST_NOTIFICATIONS'), isTrue);
      final perm = _slice(main, 'private fun maybeRequestNotificationPermission',
          '\n    override fun');
      expect(perm.contains('POST_NOTIFICATIONS'), isTrue);
      expect(perm.contains('VERSION_CODES.TIRAMISU'), isTrue);
      expect(perm.contains('requestPermissions'), isTrue);
      // Must be wired into the EXISTING single onCreate — a second onCreate
      // override is a hard Kotlin compile error (regression guard).
      expect('override fun onCreate(savedInstanceState: Bundle?)'
          .allMatches(main).length, 1,
          reason: 'exactly one onCreate override or the module will not compile');
      expect(main.contains('maybeRequestNotificationPermission() // fix697'),
          isTrue);
    });
  });

  group('fix697 item 1 — orphan fix', () {
    test('URI is persisted at status=recording (create precedes status)', () {
      final rc = _slice(svc, 'private fun runCapture', '// ── MediaStore');
      final createAt = rc.indexOf('mediaUri = createMediaStoreEntry(name)');
      final statusAt = rc.indexOf('updateStatus(id, "recording", mediaUri.toString(), null)');
      expect(createAt, greaterThanOrEqualTo(0));
      expect(statusAt, greaterThan(createAt),
          reason: 'the entry must be created before status=recording is journaled with its URI');
      // The old null-path write must be gone.
      expect(rc.contains('updateStatus(id, "recording", null, null)'), isFalse);
    });

    test('deleteOnCancel path deletes the partial after the stream closes', () {
      expect(svc.contains('deleteOnCancel = ConcurrentHashMap<Int, Boolean>()'),
          isTrue);
      expect(svc.contains('EXTRA_DELETE_FILE'), isTrue);
      final rc = _slice(svc, 'private fun runCapture', '// ── MediaStore');
      // The delete happens AFTER the copy-loop use{} block (finalize/exit region),
      // and it skips finalize + notification.
      expect(
          rc.contains('userCancelled && deleteOnCancel[id] == true') &&
              rc.contains('contentResolver.delete(mediaUri, null, null)'),
          isTrue);
      // Cleaned up in finally.
      expect(rc.contains('deleteOnCancel.remove(id)'), isTrue);
    });

    test('stop() carries deleteFile + uri through native + MethodChannel', () {
      expect(
          svc.contains(
              'fun stop(context: Context, id: Int, deleteFile: Boolean = false, uri: String? = null)'),
          isTrue);
      // ACTION_STOP honours the flag.
      expect(svc.contains('getBooleanExtra(EXTRA_DELETE_FILE, false)'), isTrue);
      // MainActivity threads deleteFile + uri from the channel args.
      final sc = _slice(main, '"stopCapture" ->', '"getFreeBytes"');
      expect(sc.contains('call.argument<Boolean>("deleteFile")'), isTrue);
      expect(sc.contains('call.argument<String>("uri")'), isTrue);
      expect(
          sc.contains(
              'RecordingCaptureService.stop(applicationContext, id, deleteFile, uri)'),
          isTrue);
    });

    test('Dart stop() sends deleteFile+uri; _delete routes running-remove via stop', () {
      // recording_capture.stop signature + payload.
      expect(
          capture.contains(
              'static Future<void> stop(int id, {bool deleteFile = false, String? uri})'),
          isTrue);
      expect(
          capture.contains(
              "invokeMethod(\n          'stopCapture', {'id': id, 'deleteFile': deleteFile, 'uri': uri})"),
          isTrue);
      // _delete: a running row removes via stop(deleteFile:, uri:), NOT
      // remuxDeleteTs (that would race the still-open output fd); finalized rows
      // still use remuxDeleteTs in the else-branch.
      final del = _slice(view, 'Future<void> _delete', 'Future<void> _showDetails');
      expect(del.contains("deleteFile: choice == 'remove', uri: r.outputPath"),
          isTrue);
      final removeAt = del.indexOf("choice == 'remove' && hasFile");
      final elseAt = del.indexOf('} else if');
      expect(elseAt, greaterThanOrEqualTo(0),
          reason: 'remuxDeleteTs must be the else-branch (not-recording rows only)');
      expect(removeAt, greaterThan(elseAt));
    });

    test('no-live-capture stop deletes the file directly (stale/killed row)', () {
      expect(svc.contains('EXTRA_URI = "output_uri"'), isTrue);
      final stopBranch = _slice(svc, 'ACTION_STOP ->', 'ACTION_START ->');
      // When no live thread will honor deleteOnCancel, delete the passed URI now.
      expect(stopBranch.contains('!active.containsKey(id)'), isTrue);
      expect(stopBranch.contains('contentResolver.delete(Uri.parse(uri), null, null)'),
          isTrue);
    });

    test('HTTP-error failure notifies + deletes the pending entry (item 2 gap)', () {
      final rc = _slice(svc, 'private fun runCapture', '// ── MediaStore');
      final http = _slice(rc, 'if (conn.responseCode !in 200..299)', 'val deadline');
      expect(http.contains('contentResolver.delete(mediaUri, null, null)'), isTrue);
      expect(http.contains('postCompletion(id, name, false, "HTTP'), isTrue);
    });

    test('deleteOnCancel reset per capture at ACTION_START', () {
      expect(svc.contains('deleteOnCancel[id] = false'), isTrue);
    });

    test('done-notification id range is far from the FGS range', () {
      expect(svc.contains('DONE_NOTI_ID_BASE = 1_000_000'), isTrue);
    });
  });

  group('fix697 re-review fixes (v2)', () {
    final sql = File('lib/backend/sql.dart').readAsStringSync();

    test('updateRecordingStatus: empty-string outputPath CLEARS to NULL', () {
      final fn = _slice(sql, 'static Future<void> updateRecordingStatus',
          'static Future<void> deleteRecording');
      expect(fn.contains("final clearPath = outputPath == ''"), isTrue);
      expect(fn.contains("clearPath ? 'NULL' : 'COALESCE(?, output_path)'"),
          isTrue);
    });

    test('HTTP-failure journals "" so the deleted URI does not linger', () {
      final rc = _slice(svc, 'private fun runCapture', '// ── MediaStore');
      final http = _slice(rc, 'if (conn.responseCode !in 200..299)', 'val deadline');
      // clears output_path (not null, which COALESCE would preserve)
      expect(http.contains('updateStatus(id, "failed", "", "HTTP'), isTrue);
    });

    test('finally honors a late delete-on-cancel (deadline/delete TOCTOU)', () {
      final rc = _slice(svc, 'private fun runCapture', '// ── MediaStore');
      final fin = _slice(rc, '} finally {', 'stopSelfIfIdle()');
      expect(
          fin.contains('mediaUri != null && deleteOnCancel[id] == true') &&
              fin.contains('contentResolver.delete(mediaUri, null, null)'),
          isTrue);
    });

    test('Stop button suppresses the in-app completion snack', () {
      expect(view.contains('final Set<int> _userEndedIds'), isTrue);
      final stop = _slice(view, 'Future<void> _stop(Recording r)', 'Future<void> _cancel');
      expect(stop.contains('_userEndedIds.add(r.id!)'), isTrue);
      final snk = _slice(view, 'void _showCompletionSnacks',
          '(IconData, Color, String) _statusChip');
      expect(snk.contains('_userEndedIds.remove(e.id)'), isTrue);
    });
  });

  group('fix697 item 2 — in-app SnackBar twin', () {
    test('drain returns terminal completions', () {
      expect(journal.contains('class RecordingCompletion'), isTrue);
      expect(journal.contains('Future<List<RecordingCompletion>> drain()'), isTrue);
      final fn = _slice(journal, 'Future<List<RecordingCompletion>> drain()', '  static Future<void> _truncate');
      expect(
          fn.contains('status == RecordingStatus.done || status == RecordingStatus.failed'),
          isTrue);
      expect(fn.contains('RecordingCompletion(e.key, e.value)'), isTrue);
    });

    test('_load shows completion snacks only after the first (opening) drain', () {
      expect(view.contains('bool _firstLoad = true'), isTrue);
      final ld = _slice(view, 'Future<void> _load()', 'void _showCompletionSnacks');
      expect(ld.contains('await RecordingStatusJournal.drain()'), isTrue);
      expect(ld.contains('if (!wasFirst && completions.isNotEmpty)'), isTrue);
      final snk = _slice(view, 'void _showCompletionSnacks', '(IconData, Color, String) _statusChip');
      expect(snk.contains('Recording complete'), isTrue);
      expect(snk.contains('Recording failed'), isTrue);
      expect(snk.contains('showSnackBar'), isTrue);
      // A stopped/deleted row is dropped from _recordings — don't announce it
      // (mirrors the native notification's user-stop suppression).
      expect(snk.contains('if (row == null) continue'), isTrue);
    });
  });
}
