import 'dart:convert';
import 'dart:io';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/recording_remux.dart';
import 'package:open_tv/backend/settings_service.dart';
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
/// (sqlite_async), then deletes the RENAMED processing file. Append-only file I/O
/// is isolate- and crash-agnostic; no live Dart engine is needed while capture runs.
///
/// Each line: {"id":Int,"status":String,"output_path":String?,"error":String?}
///
/// fix756: drain a renamed `sr_status.jsonl.processing` batch, never the live
/// journal the native service may still be appending to. See section 1/2 of
/// runbooks/fix756.md for the read/apply/truncate race this removes.

/// fix697: a terminal recording transition surfaced by [RecordingStatusJournal.drain]
/// (done or failed), used to show an in-app completion SnackBar.
class RecordingCompletion {
  const RecordingCompletion(this.id, this.status);
  final int id;
  final RecordingStatus status;
}

class RecordingStatusJournal {
  RecordingStatusJournal._();

  static const String fileName = 'sr_status.jsonl';

  static Future<File> _file() async => File('${await Utils.appDir}/$fileName');

  /// Apply any pending native status events to the DB, then clear the journal.
  /// Safe to call repeatedly; a no-op when the file is missing or empty.
  ///
  /// fix697: returns the terminal (done/failed) transitions applied in THIS pass
  /// so a foregrounded Recordings screen can show an in-app SnackBar twin of the
  /// native completion notification (item 2). Last status per id wins.
  static Future<List<RecordingCompletion>> drain() async {
    File f;
    try {
      f = await _file();
    } catch (_) {
      return const [];
    }

    // fix756: NEVER read/apply/truncate the live journal in place. The native
    // service can append another status line after our read but before the old
    // truncate, and that appended line was erased unapplied. Rename the live
    // file to a side batch first; native keeps appending to a newly-created
    // live file. If a previous run crashed after rename but before delete,
    // adopt that `.processing` batch and finish it before touching live state.
    final processing = File('${f.path}.processing');
    try {
      if (await processing.exists()) {
        f = processing; // crash recovery: complete the prior renamed batch.
      } else {
        if (!await f.exists()) return const [];
        await f.rename(processing.path);
        f = processing;
      }
    } catch (e) {
      // A racing drain may have won the rename, or the OS refused it. Either
      // way there is no safe live file to truncate — leave both files alone.
      AppLog.warn('RecordingStatusJournal: rename/adopt failed — $e');
      return const [];
    }

    String contents;
    try {
      contents = await f.readAsString();
    } catch (e) {
      AppLog.warn('RecordingStatusJournal: read failed — $e');
      return const [];
    }
    if (contents.trim().isEmpty) {
      await _deleteProcessed(f);
      return const [];
    }

    // fix685: ids whose capture requested remux (native wrote "remux":true on a
    // done .ts). Collected here and handed to the Dart FFI remuxer AFTER the DB
    // is up to date, so a done .ts is visible in the row before remux replaces it.
    final remuxIds = <int>[];
    // fix697: terminal transitions surfaced this pass (last status per id wins).
    final completions = <int, RecordingStatus>{};

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
        if (status == RecordingStatus.done && m['remux'] == true) {
          remuxIds.add(id);
        }
        if (status == RecordingStatus.done || status == RecordingStatus.failed) {
          completions[id] = status;
        }
      } catch (e) {
        // Skip a malformed line but keep applying the rest.
        AppLog.warn('RecordingStatusJournal: bad line skipped — $e');
      }
    }

    await _deleteProcessed(f);

    // fix685: run any pending re-muxes (stream-copy .ts -> mp4/mkv via FFI).
    // Best-effort: RecordingRemux is fully fail-open (a failure keeps the .ts).
    if (remuxIds.isNotEmpty) {
      try {
        final debug = SettingsService.cached?.debugLogging ?? false;
        await RecordingRemux.process(remuxIds, debugLogging: debug);
      } catch (e) {
        AppLog.warn('RecordingStatusJournal: remux pass failed — $e');
      }
    }

    return completions.entries
        .map((e) => RecordingCompletion(e.key, e.value))
        .toList();
  }

  static Future<void> _deleteProcessed(File f) async {
    try {
      // fix756: delete only the renamed batch we just applied. A failure leaves
      // `sr_status.jsonl.processing` for the next drain to re-apply (duplicate
      // last-write-wins status updates) instead of erasing unseen native lines.
      await f.delete();
    } catch (e) {
      AppLog.warn('RecordingStatusJournal: processed-journal delete failed — $e');
    }
  }

  static RecordingStatus? _parseStatus(String s) {
    for (final v in RecordingStatus.values) {
      if (v.name == s) return v;
    }
    return null;
  }
}
