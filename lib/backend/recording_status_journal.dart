import 'dart:convert';
import 'dart:io';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/recording.dart';

/// fix681: single-writer bridge for Scheduled Recording status.
///
/// The native capture service (RecordingCaptureService) runs in a foreground
/// service that outlives the UI isolate and used to write the `recordings` row
/// directly via Android's framework SQLiteDatabase. But the app's DB is
/// sqlite_async in WAL mode; the framework handle opened the same file on a
/// separate connection and its updates matched 0 rows (WAL visibility), so
/// status never reached the row the UI reads — recordings stayed stuck on
/// "recording" even after a clean capture (observed: updateStatus
/// rowsAffected=0 for every recording).
///
/// Fix: native no longer touches the DB. It appends one JSON line per status
/// change to `sr_status.jsonl` in the app files dir. Dart — the SINGLE writer —
/// drains that journal here, applying each event through Sql.updateRecordingStatus
/// (sqlite_async), then truncates the file. Append-only file I/O is isolate- and
/// crash-agnostic; no live Dart engine is needed while capture runs.
///
/// Each line: {"id":Int,"status":String,"output_path":String?,"error":String?}
class RecordingStatusJournal {
  RecordingStatusJournal._();

  static const String fileName = 'sr_status.jsonl';

  static Future<File> _file() async => File('${await Utils.appDir}/$fileName');

  /// Apply any pending native status events to the DB, then clear the journal.
  /// Safe to call repeatedly; a no-op when the file is missing or empty.
  static Future<void> drain() async {
    File f;
    try {
      f = await _file();
      if (!await f.exists()) return;
    } catch (_) {
      return;
    }

    String contents;
    try {
      contents = await f.readAsString();
    } catch (e) {
      AppLog.warn('RecordingStatusJournal: read failed — $e');
      return;
    }
    if (contents.trim().isEmpty) {
      await _truncate(f);
      return;
    }

    for (final raw in const LineSplitter().convert(contents)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        final id = (m['id'] as num?)?.toInt();
        final statusStr = m['status'] as String?;
        if (id == null || statusStr == null) continue;
        final status = _parseStatus(statusStr);
        if (status == null) continue;
        await Sql.updateRecordingStatus(
          id,
          status,
          outputPath: m['output_path'] as String?,
          error: m['error'] as String?,
        );
      } catch (e) {
        // Skip a malformed line but keep applying the rest.
        AppLog.warn('RecordingStatusJournal: bad line skipped — $e');
      }
    }

    await _truncate(f);
  }

  static Future<void> _truncate(File f) async {
    try {
      await f.writeAsString('', flush: true);
    } catch (e) {
      AppLog.warn('RecordingStatusJournal: truncate failed — $e');
    }
  }

  static RecordingStatus? _parseStatus(String s) {
    for (final v in RecordingStatus.values) {
      if (v.name == s) return v;
    }
    return null;
  }
}
