import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel_preserve.dart';
import 'package:open_tv/models/dev_mpv_options.dart' show
    VideoSyncMode, TscaleMode, FrameDropMode,
    HwdecImageFormat, AudioSpdifMode;
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/multi_view_decode.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/zoom_mode.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const int _schemaVersion = 4; // fix355: + groups (category state) + positions

class SettingsIo {
  /// fix166: local snapshot stamp `yyyymmdd-HHMMSS` for export filenames.
  static String exportStamp(DateTime now) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${p2(now.month)}${p2(now.day)}'
        '-${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
  }

  /// fix322: `<deviceTag>-<stamp>` (or just `<stamp>` when no tag) so exports
  /// from different devices don't collide / are self-identifying. e.g.
  /// `shield-20260609-131737`.
  static Future<String> stampWithDevice([DateTime? now]) async {
    final stamp = exportStamp(now ?? DateTime.now());
    final tag = await DeviceDetector.deviceTag();
    return tag.isEmpty ? stamp : '$tag-$stamp';
  }

  /// fix654: gzip in-memory payloads (settings backups, log/settings text
  /// items in the diagnostic bundle) via dart:io's native ZLibEncoder — real
  /// zlib, not the bundled pure-Dart `archive` package. That package's
  /// XZEncoder never actually compresses (it only wraps data in a valid but
  /// UNCOMPRESSED .xz container — dead end for "smallest/fastest"), and its
  /// Deflate OOM'd on a 532MB file that dart:io streams without issue. Level
  /// 9 = max compression; native zlib is fast enough that the CPU cost is
  /// negligible next to the disk/network time it saves.
  static List<int> gzipBytes(List<int> data, {int level = 9}) =>
      ZLibEncoder(gzip: true, level: level).convert(data);

  /// fix654: stream-gzip a (possibly huge) file straight to [destPath] —
  /// never holds the source in memory, so a multi-hundred-MB db.sqlite can't
  /// OOM the 2GB TV box the way archive's Deflate did on the source dump.
  static Future<File> gzipFileStream(File src, String destPath,
      {int level = 9}) async {
    final dest = File(destPath);
    final sink = dest.openWrite();
    try {
      await sink.addStream(
          src.openRead().transform(ZLibEncoder(gzip: true, level: level)));
    } finally {
      await sink.close();
    }
    return dest;
  }

  /// fix654: auto-detect a gzip member (magic bytes `1f 8b`) and decompress;
  /// returns [bytes] unchanged otherwise so pre-fix654 plain exports still
  /// import.
  static List<int> maybeGunzip(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      return ZLibDecoder(gzip: true).convert(bytes);
    }
    return bytes;
  }

  /// fix572: given the basenames in a directory, return which ones are STALE
  /// export artifacts to purge. Pure (no IO) so it is unit-testable. An export
  /// artifact is a `free4me-export-*` bundle dir/zip or a `free4me-backup-*.json`
  /// file (the two timestamped families written to the temp dir). [keepExportDir]
  /// / [keepBackupFile] are the exact basenames the current export session is
  /// about to (re)create and must be preserved; pass null to treat all of that
  /// family as stale (the QR flow keeps its bundle dir but sweeps every orphaned
  /// backup json, and the save-to-file flow does the reverse). Unrelated temp
  /// files are never returned.
  static List<String> staleExportArtifactNames(
    Iterable<String> names, {
    String? keepExportDir,
    String? keepBackupFile,
  }) {
    final stale = <String>[];
    for (final name in names) {
      final isExport = name.startsWith('free4me-export-');
      final isBackup = name.startsWith('free4me-backup-') &&
          (name.endsWith('.json') || name.endsWith('.json.gz')); // fix654
      if (!isExport && !isBackup) continue; // unrelated — leave it alone
      if (isExport && name == keepExportDir) continue;
      if (isBackup && name == keepBackupFile) continue;
      stale.add(name);
    }
    return stale;
  }

  /// fix572: delete leftover export artifacts from PRIOR export sessions so the
  /// temp dir doesn't grow without bound. A QR/LAN bundle dir (`_buildExportBundle`)
  /// can hold multi-hundred-MB DB snapshots and was never cleaned up after the
  /// download server stopped. Called at the start of each export session, this
  /// keeps only what the current session is creating. Fail-soft: a listing or
  /// delete error is logged but never aborts the export. Returns the count
  /// removed.
  static Future<int> purgeStaleExportArtifacts({
    String? keepExportDir,
    String? keepBackupFile,
  }) async {
    final tmp = await getTemporaryDirectory();
    final List<FileSystemEntity> entries;
    try {
      entries = tmp.listSync(followLinks: false);
    } catch (e) {
      AppLog.warn('export: could not list temp dir to purge artifacts — $e');
      return 0;
    }
    final byName = {
      for (final e in entries) e.path.split(Platform.pathSeparator).last: e
    };
    final stale = staleExportArtifactNames(
      byName.keys,
      keepExportDir: keepExportDir,
      keepBackupFile: keepBackupFile,
    );
    var removed = 0;
    for (final name in stale) {
      final entity = byName[name];
      if (entity == null) continue;
      try {
        await entity.delete(recursive: true);
        removed++;
      } catch (e) {
        AppLog.warn('export: failed to purge stale artifact $name — $e');
      }
    }
    if (removed > 0) {
      AppLog.info('export: purged $removed stale export artifact(s) from temp '
          '(kept exportDir=${keepExportDir ?? "-"} '
          'backup=${keepBackupFile ?? "-"})');
    }
    return removed;
  }

  /// Channel-attribute restores staged by importFromFile, keyed by
  /// source name. Consumed by applyPendingPreserves once channel
  /// rows are populated by the first source refresh.
  ///
  /// In-memory only — if the app is killed before refresh runs, the
  /// entries are lost (the backup file itself is still on disk so
  /// the user can re-import). Persisting to SQLite is possible but
  /// adds schema-migration work; not worth it for a rare edge case.
  static final Map<String, List<ChannelPreserve>> _pendingPreserves = {};

  /// fix355: staged category state / resume positions, applied with the
  /// preserves once a refresh populates groups+channels for the source.
  static final Map<String, List<Map<String, dynamic>>> _pendingGroups = {};
  static final Map<String, List<Map<String, dynamic>>> _pendingPositions = {};

  static void _stageGroupsAndPositions(
      String sourceName, Map<String, dynamic> map) {
    final groupsRaw = map['groups'] as List<dynamic>?;
    if (groupsRaw != null && groupsRaw.isNotEmpty) {
      _pendingGroups[sourceName] =
          groupsRaw.map((g) => (g as Map).cast<String, dynamic>()).toList();
    }
    final posRaw = map['positions'] as List<dynamic>?;
    if (posRaw != null && posRaw.isNotEmpty) {
      _pendingPositions[sourceName] =
          posRaw.map((p) => (p as Map).cast<String, dynamic>()).toList();
    }
    if (groupsRaw != null || posRaw != null) {
      AppLog.info(
        'SettingsIo: staged for "$sourceName"'
        ' groups=${groupsRaw?.length ?? 0} positions=${posRaw?.length ?? 0}',
      );
    }
  }

  /// fix355: stage category state and resume positions from a backup map.

  /// Export all sources + settings to a JSON file chosen by the user.
  /// [includeCredentials] controls whether Xtream username/password are written.
  // fix158: extracted so TV export can build the payload without FilePicker.
  static Future<String> buildBackupPayload({
    bool includeCredentials = false,
  }) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final settings = await SettingsService.getSettings();
    final sources = await Sql.getSources();

    final sourcesPayload = <Map<String, dynamic>>[];
    for (final s in sources) {
      final base = _sourceToMap(s, includeCredentials);
      if (s.id != null) {
        // finding 93: use the backup-scoped preserve query so mass
        // auto-matched (epg_channel_id) / auto-validated (stream_validated)
        // rows that carry no user-authored data (favorite/last_watched/
        // epg_manual_override) don't balloon the backup JSON. Those are
        // re-derived on the next refresh/EPG pass. The shared
        // getChannelsPreserve stays untouched for the source-refresh path.
        final preserve = await Sql.getChannelsPreserveForBackup(s.id!);
        if (preserve.isNotEmpty) {
          base['preserve'] = preserve
              .map((p) => {
                    'name': p.name,
                    if (p.favorite != null) 'favorite': p.favorite,
                    if (p.lastWatched != null) 'lastWatched': p.lastWatched,
                    if (p.epgChannelId != null) 'epgChannelId': p.epgChannelId,
                    if (p.epgManualOverride != null)
                      'epgManualOverride': p.epgManualOverride,
                  })
              .toList();
        }
        // fix355: curated category state + VOD resume positions.
        final curatedGroups = await Sql.getGroupsCurated(s.id!);
        if (curatedGroups.isNotEmpty) base['groups'] = curatedGroups;
        final positions = await Sql.getMoviePositionsForExport(s.id!);
        if (positions.isNotEmpty) base['positions'] = positions;
      }
      sourcesPayload.add(base);
    }

    return jsonEncode({
      'schemaVersion': _schemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': packageInfo.version,
      'settings': _settingsToMap(settings),
      'sources': sourcesPayload,
    });
  }

  static Future<void> exportToFile(
    BuildContext context, {
    bool includeCredentials = false,
  }) async {
    final settings = await SettingsService.getSettings();
    final sources = await Sql.getSources();

    AppLog.info(
      'SettingsIo.export: schema=$_schemaVersion'
      ' sources=${sources.length}'
      ' multiViewLayout=${settings.multiViewLayout.name}'
      ' multiViewCells1x2="${settings.multiViewCells1x2}"'
      ' multiViewCells2x2="${settings.multiViewCells2x2}"'
      ' multiViewAutoRestoreChannels=${settings.multiViewAutoRestoreChannels}',
    );

    // finding 96: reuse buildBackupPayload (its body was a line-for-line
    // duplicate of the loop that used to live here) so the P0/#92 credential
    // scrub and #95 use24HourTime fixes live in exactly ONE place and cover
    // this save-to-file path automatically. The diagnostic log above still
    // uses the settings/sources fetched here.
    final payload =
        await buildBackupPayload(includeCredentials: includeCredentials);

    final stamp = await stampWithDevice(); // fix166/fix322
    // fix654: gzip the backup at level 9 — settings-only backups are small,
    // but a sources-with-credentials backup can carry hundreds of channel
    // URLs and this shrinks it for free.
    final backupName = 'free4me-backup-$stamp.json.gz';
    // fix572: sweep prior export artifacts (orphaned QR bundle dirs + leftover
    // backup jsons) before writing this one; keep the file we're about to save.
    await purgeStaleExportArtifacts(keepBackupFile: backupName);
    final dir = await getTemporaryDirectory();
    final tmpFile = File('${dir.path}/$backupName');
    await tmpFile.writeAsBytes(gzipBytes(utf8.encode(payload)));

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Free4Me-IPTV backup',
      fileName: backupName,
      bytes: tmpFile.readAsBytesSync(),
    );

    await tmpFile.delete().catchError((_) => tmpFile);

    if (result != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup exported successfully')),
      );
    }
  }

  /// Import settings and sources from a user-selected JSON file.
  /// Returns `true` if the payload was successfully applied; `false`
  /// on user cancel, parse failure, or version mismatch. Callers are
  /// expected to fire `Utils.refreshAllSources()` themselves when the
  /// return value is true — kept here as a separate call so this
  /// module doesn't have to import `utils.dart` (which would create
  /// an import cycle, since utils.dart imports this module for
  /// `applyPendingPreserves`).
  /// fix317: import ONLY the sources from a backup payload, merging them into
  /// the existing source list (by name) and skipping all other settings —
  /// device-specific values (buffering, decode, multi-view, etc.) should not be
  /// carried across devices. Returns the number of sources imported, or -1 on
  /// a parse/schema error. Channel preserves (favorites/history/EPG ids) are
  /// staged for re-application after the next refresh, exactly like a full
  /// import. The caller is responsible for triggering the source refresh.
  static Future<int> importSourcesOnly(List<int> jsonBytes) async {
    final Map<String, dynamic> payload;
    try {
      // fix654: transparently accept a gzipped payload (new exports).
      payload = jsonDecode(utf8.decode(maybeGunzip(jsonBytes)))
          as Map<String, dynamic>;
    } catch (e) {
      AppLog.warn('SettingsIo.importSourcesOnly: parse failed — $e');
      return -1;
    }
    final version = payload['schemaVersion'] as int? ?? 0;
    if (version > _schemaVersion) {
      AppLog.warn(
        'SettingsIo.importSourcesOnly: backup schema v$version newer than '
        'app schema v$_schemaVersion — refusing',
      );
      return -1;
    }
    final rawSources = payload['sources'] as List<dynamic>?;
    if (rawSources == null || rawSources.isEmpty) {
      AppLog.warn('SettingsIo.importSourcesOnly: no sources in payload');
      return 0;
    }
    var count = 0;
    for (final raw in rawSources) {
      // finding 97: skip-and-log a malformed source entry instead of throwing
      // after a partial import (bare casts previously aborted the whole loop
      // and stranded the imported-so-far count). -1 stays reserved for the
      // payload-level parse/schema failure handled above.
      try {
        if (raw is! Map) {
          AppLog.warn(
              'SettingsIo.importSourcesOnly: skipping non-map source entry');
          continue;
        }
        final map = raw.cast<String, dynamic>();
        final name = map['name'];
        if (name is! String || name.isEmpty) {
          AppLog.warn('SettingsIo.importSourcesOnly: skipping source with '
              'missing/invalid name');
          continue;
        }
        final typeIdx = map['sourceType'] as int? ?? 0;
        final sourceType =
            SourceType.values.elementAtOrNull(typeIdx) ?? SourceType.m3u;
        final source = Source(
          name: name,
          url: map['url'] as String?,
          username: map['username'] as String?,
          password: map['password'] as String?,
          sourceType: sourceType,
          enabled: map['enabled'] as bool? ?? true,
          epgUrl: map['epgUrl'] as String?,
          // fix358: carry source-level settings through QR/LAN import.
          maxConnections: map['maxConnections'] as int?,
          color: map['color'] as int?,
          sortMode: map['sortMode'] as String?,
        );
        // getOrCreateSourceByName merges by name — existing sources are reused,
        // new ones created. Other settings are intentionally NOT touched.
        await Sql.commitWrite([Sql.getOrCreateSourceByName(source)]);
        count++;
        AppLog.info(
          'SettingsIo.importSourcesOnly: source "${source.name}"'
          ' type=${source.sourceType.name} enabled=${source.enabled}',
        );
        final preserveRaw = map['preserve'] as List<dynamic>?;
        if (preserveRaw != null && preserveRaw.isNotEmpty) {
          _pendingPreserves[source.name] = preserveRaw
              .map((p) {
                final m = p as Map<String, dynamic>;
                return ChannelPreserve(
                  name: m['name'] as String,
                  favorite: m['favorite'] as int?,
                  lastWatched: m['lastWatched'] as int?,
                  epgChannelId: m['epgChannelId'] as String?,
                  epgManualOverride: m['epgManualOverride'] as String?,
                );
              })
              .toList();
        }
        _stageGroupsAndPositions(source.name, map); // fix355
      } catch (e) {
        AppLog.warn(
            'SettingsIo.importSourcesOnly: skipping malformed source entry — $e');
      }
    }
    AppLog.info('SettingsIo.importSourcesOnly: imported $count source(s)');
    return count;
  }

  static Future<bool> importFromFile(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'gz'], // fix654: exports are now gzipped
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return false;

    final raw = utf8.decode(maybeGunzip(result.files.single.bytes!));
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid backup file — could not parse JSON'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }

    final version = payload['schemaVersion'] as int? ?? 0;
    if (version > _schemaVersion) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Backup was created by a newer version of the app '
              '(schema v$version). Please update the app first.',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }

    // Show confirmation before applying.
    if (context.mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Import backup?'),
          content: Text(
            'Exported: ${payload['exportedAt'] ?? 'unknown'}\n'
            'App version: ${payload['appVersion'] ?? 'unknown'}\n\n'
            'This will update your settings and add or update the sources in '
            'this backup. Existing sources not in the backup are kept. ',  // fix359: dialog matched merge semantics (was "replace all sources")
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (confirmed != true) return false;
    }

    try {
      if (payload['settings'] != null) {
        final rawSettings = payload['settings'] as Map<String, dynamic>;
        final settings = _settingsFromMap(rawSettings);

        // what _settingsFromMap produced. If a v2 backup is imported,
        // the multi-view fields are absent from rawSettings and the
        // resulting settings hold constructor defaults. That's expected
        // and not a bug — the old backup simply doesn't carry that data.
        AppLog.info(
          'SettingsIo.import: schemaVersion=${payload['schemaVersion']}'
          ' appVersion=${payload['appVersion']}'
          ' payload-has-multiViewLayout=${rawSettings.containsKey('multiViewLayout')}'
          ' payload-multiViewLayout=${rawSettings['multiViewLayout']}'
          ' parsed-multiViewLayout=${settings.multiViewLayout.name}'
          ' parsed-cells1x2="${settings.multiViewCells1x2}"'
          ' parsed-cells2x2="${settings.multiViewCells2x2}"'
          ' parsed-autoRestore=${settings.multiViewAutoRestoreChannels}',
        );

        await SettingsService.updateSettings(settings);
        // the import session is captured. Without this, a fresh
        // install that imports a backup with debugLogging=true
        // produces an empty log file for the entire first session.
        await AppLog.setEnabled(settings.debugLogging);
        AppLog.logUserPass = settings.logUserPass;
      }

      if (payload['sources'] != null) {
        final rawSources = payload['sources'] as List<dynamic>;
        for (final raw in rawSources) {
          final map = raw as Map<String, dynamic>;
          final source = Source(
            name: map['name'] as String,
            url: map['url'] as String?,
            username: map['username'] as String?,
            password: map['password'] as String?,
            sourceType: SourceType.values[map['sourceType'] as int? ?? 0],
            enabled: map['enabled'] as bool? ?? true,
            epgUrl: map['epgUrl'] as String?,
            // finding 94: carry source-level settings through full import too
            // (export writes them; only importFromFile was dropping them).
            maxConnections: map['maxConnections'] as int?,
            color: map['color'] as int?,
            sortMode: map['sortMode'] as String?,
          );
          await Sql.commitWrite([Sql.getOrCreateSourceByName(source)]);

          AppLog.info(
            'SettingsIo.import: source "${source.name}"'
            ' enabled=${source.enabled}'
            ' type=${source.sourceType.name}'
          );

          // Stage favorites / last-watched for re-application after the
          // first refresh populates channels for this source. Keyed by
          // source name because IDs differ between export and import
          // databases; names are the only stable identifier across the
          // boundary.
          final preserveRaw = map['preserve'] as List<dynamic>?;
          if (preserveRaw != null && preserveRaw.isNotEmpty) {
            final preserveList = preserveRaw
                .map((p) {
                  final m = p as Map<String, dynamic>;
                  return ChannelPreserve(
                    name: m['name'] as String,
                    favorite: m['favorite'] as int?,
                    lastWatched: m['lastWatched'] as int?,
                    epgChannelId: m['epgChannelId'] as String?,
                    epgManualOverride: m['epgManualOverride'] as String?,
                  );
                })
                .toList();
            _pendingPreserves[source.name] = preserveList;
            AppLog.info(
              'SettingsIo.import: staged preserves for "${source.name}"'
              ' total=${preserveList.length}'
              ' epg=${preserveList.where((p) => p.epgChannelId != null).length}'
              ' favorites=${preserveList.where((p) => p.favorite == 1).length}',
            );
          }
          _stageGroupsAndPositions(source.name, map); // fix355
        }
      }

      // feedback (the new showSourcesRefreshDialog supersedes the
      // old "Refreshing in the background…" snackbar — the dialog
      // is what the user actually sees during refresh).
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }
  }

  /// Apply any pending channel-attribute restores for [sourceName]
  /// that were staged by a recent importFromFile call. Safe to call
  /// repeatedly; the entry is consumed and cleared on first
  /// successful match. No-op if nothing is pending.
  ///
  /// Called from Utils.refreshSource after channels are populated.
  static Future<void> applyPendingPreserves(String sourceName) async {
    final preserve = _pendingPreserves.remove(sourceName);
    // fix355: drain staged category state and resume positions in the same
    // pass; any of the three being present is reason to proceed.
    final groups = _pendingGroups.remove(sourceName);
    final positions = _pendingPositions.remove(sourceName);
    if ((preserve == null || preserve.isEmpty) &&
        (groups == null || groups.isEmpty) &&
        (positions == null || positions.isEmpty)) {
      AppLog.info(
        'SettingsIo.applyPendingPreserves: nothing staged'
        ' for "$sourceName" — skipping',
      );
      return;
    }

    final sources = await Sql.getSources();
    Source? source;
    for (final s in sources) {
      if (s.name == sourceName) {
        source = s;
        break;
      }
    }
    if (source == null || source.id == null) {
      AppLog.warn(
        'SettingsIo.applyPendingPreserves: source "$sourceName" not found'
        ' in DB — dropping ${preserve?.length ?? 0} staged preserves'
        ' (+${groups?.length ?? 0} groups, ${positions?.length ?? 0} positions)',
      );
      return;
    }

    if (preserve != null && preserve.isNotEmpty) {
      AppLog.info(
        'SettingsIo.applyPendingPreserves: applying ${preserve.length}'
        ' preserves to "$sourceName" (sourceId=${source.id})'
        ' epg=${preserve.where((p) => p.epgChannelId != null).length}'
        ' favorites=${preserve.where((p) => p.favorite == 1).length}',
      );
      await Sql.commitWrite(
        [Sql.restorePreserve(preserve)],
        memory: {'sourceId': source.id!.toString()},
      );
    }
    // fix355: apply staged category state and resume positions.
    var gApplied = 0;
    for (final g in groups ?? const <Map<String, dynamic>>[]) {
      final name = g['name'] as String?;
      if (name == null) continue;
      await Sql.applyGroupState(
        source.id!,
        name,
        (g['favorite'] as int?) ?? 0,
        (g['enabled'] as int?) ?? 1,
      );
      gApplied++;
    }
    var pApplied = 0;
    for (final p in positions ?? const <Map<String, dynamic>>[]) {
      final url = p['url'] as String?;
      final pos = p['position'] as int?;
      if (url == null || pos == null) continue;
      await Sql.applyMoviePosition(source.id!, url, pos);
      pApplied++;
    }
    if (gApplied > 0 || pApplied > 0) {
      AppLog.info(
        'SettingsIo.applyPendingPreserves: "$sourceName"'
        ' groups=$gApplied positions=$pApplied applied',
      );
    }
    await Sql.checkpointAndTruncateWal();
    AppLog.info(
      'SettingsIo.applyPendingPreserves: done for "$sourceName"',
    );
  }

  static Map<String, dynamic> _settingsToMap(Settings s) => {
        'defaultView': s.defaultView.index,
        'multiViewStabilityBufferSecs':
            s.multiViewStabilityBufferSecs, // fix355: was missing from backup
        'refreshOnStart': s.refreshOnStart,
        'showLivestreams': s.showLivestreams,
        'showMovies': s.showMovies,
        'showSeries': s.showSeries,
        'forceTVMode': s.forceTVMode,
        'hwDecode': s.hwDecode,
        'forceHwDecode': s.forceHwDecode,
        'cap1080pOnLowRam': s.cap1080pOnLowRam,
        'tvHeroLivePreview': s.tvHeroLivePreview,
        'preWarmOnFocus': s.preWarmOnFocus,
        'tvHomeRowEnabled': s.tvHomeRowEnabled, // fix665
        'tvHomeRowCount': s.tvHomeRowCount, // fix665
        'recordPadBeforeMin': s.recordPadBeforeMin, // fix667
        'recordPadAfterMin': s.recordPadAfterMin, // fix667
        'remuxRecordings': s.remuxRecordings, // fix671
        'backgroundProcessing': s.backgroundProcessing, // fix318
        'liveCacheSecs': s.liveCacheSecs,
        'liveDemuxerMaxMB': s.liveDemuxerMaxMB,
        'vodCacheSecs': s.vodCacheSecs,
        'vodPrebufferSecs': s.vodPrebufferSecs, // fix354
        'livePrebufferSecs': s.livePrebufferSecs, // fix700
        'dvrEnabled': s.dvrEnabled, // fix357
        'audioDownmixStereo': s.audioDownmixStereo, // fix361
        'dvrMinutes': s.dvrMinutes, // fix357
        'vodDemuxerMaxMB': s.vodDemuxerMaxMB,
        'openTimeoutSecs': s.openTimeoutSecs,
        'bufferingWatchdogSecs': s.bufferingWatchdogSecs,
        'stableThresholdSecs': s.stableThresholdSecs,
        // EPG & debug (schema v2)
        'debugLogging': s.debugLogging,
        'logUserPass': s.logUserPass,
        'epgAutoRefresh': s.epgAutoRefresh,
        'epgRefreshHours': s.epgRefreshHours,
        'epgRefreshHour': s.epgRefreshHour,
        'epgPastDays': s.epgPastDays,
        'epgForecastDays': s.epgForecastDays,
        'epgSearchHours': s.epgSearchHours,
        // Schema v3 additions:
        'startupGraceMs': s.startupGraceMs,
        'miniDemuxerMaxMB': s.miniDemuxerMaxMB,
        'bufferSizeMB': s.bufferSizeMB,
        'streamCompletedDelayMs': s.streamCompletedDelayMs,
        'maxReconnectAttempts': s.maxReconnectAttempts,
        'streamScanMaxCount': s.streamScanMaxCount,
        'streamScanTimeoutSecs': s.streamScanTimeoutSecs,
        'multiViewLayout': s.multiViewLayout.toJson(),
        'multiViewCells1x2': s.multiViewCells1x2,
        'multiViewCells2x2': s.multiViewCells2x2,
        'multiViewAutoRestoreChannels': s.multiViewAutoRestoreChannels,
        'contentTypeFilter': s.contentTypeFilter.index,
        'searchMethod': s.searchMethod.index,
        'safeMode': s.safeMode,
        'confirmToExit': s.confirmToExit, // fix587 (#23)

        // fix394: Developer / libmpv advanced tunables (schema v4).
        'devDemuxerReadaheadSecs': s.devDemuxerReadaheadSecs,
        'devNetworkTimeoutSecs': s.devNetworkTimeoutSecs,
        'devImportFetchTimeoutSecs': s.devImportFetchTimeoutSecs,
        'devTlsVerify': s.devTlsVerify,
        'devVideoSync': s.devVideoSync.toJson(),
        'devVideoSyncMaxVideoChange': s.devVideoSyncMaxVideoChange,
        'devTscale': s.devTscale.toJson(),
        'devFramedrop': s.devFramedrop.toJson(),
        'devInterpolation': s.devInterpolation,
        'devDeband': s.devDeband,
        'devCapFpsLowRam': s.devCapFpsLowRam,
        'devHwdecImageFormat': s.devHwdecImageFormat.toJson(),
        'devAudioBufferSecs': s.devAudioBufferSecs,
        'devAudioSpdif': s.devAudioSpdif.toJson(),

        // fix573: three settings were persisted normally but DROPPED from the
        // backup payload, so a backup/restore silently reset them to defaults.
        'multiViewDecode': s.multiViewDecode.toJson(),
        'devControlsHideSecs': s.devControlsHideSecs,
        'devSkipBackOnResumeSecs': s.devSkipBackOnResumeSecs, // fix652
        'use24HourTime': s.use24HourTime, // finding 95: was dropped from backup
        'playerZoomMode': s.playerZoomMode.name,
      };

  static Settings _settingsFromMap(Map<String, dynamic> m) {
    // Construct with v2 fields first, then overlay v3 additions.
    // Missing v3 fields silently fall back to constructor defaults,
    // which matches user expectation when restoring a v2 backup.
    final s = Settings(
      defaultView: ViewType.values[m['defaultView'] as int? ?? 0],
      multiViewStabilityBufferSecs:
          m['multiViewStabilityBufferSecs'] as int? ?? 0, // fix355
      refreshOnStart: m['refreshOnStart'] as bool? ?? false,
      showLivestreams: m['showLivestreams'] as bool? ?? true,
      showMovies: m['showMovies'] as bool? ?? true,
      showSeries: m['showSeries'] as bool? ?? true,
      forceTVMode: m['forceTVMode'] as bool? ?? false,
      hwDecode: m['hwDecode'] as bool? ?? true,
      forceHwDecode: m['forceHwDecode'] as bool? ?? false,
      cap1080pOnLowRam: m['cap1080pOnLowRam'] as bool? ?? true,
      tvHeroLivePreview: m['tvHeroLivePreview'] as bool? ?? false,
      preWarmOnFocus: m['preWarmOnFocus'] as bool? ?? true,
      tvHomeRowEnabled: m['tvHomeRowEnabled'] as bool? ?? false, // fix665
      tvHomeRowCount:
          ((m['tvHomeRowCount'] as int?) ?? 10).clamp(1, 20), // fix665
      recordPadBeforeMin:
          ((m['recordPadBeforeMin'] as int?) ?? 1).clamp(0, 15), // fix667
      recordPadAfterMin:
          ((m['recordPadAfterMin'] as int?) ?? 1).clamp(0, 240), // fix667
      remuxRecordings: m['remuxRecordings'] as bool? ?? false, // fix671
      backgroundProcessing: m['backgroundProcessing'] as bool? ?? false,
      liveCacheSecs: m['liveCacheSecs'] as int? ?? 20,
      liveDemuxerMaxMB: m['liveDemuxerMaxMB'] as int? ?? 150,
      vodCacheSecs: m['vodCacheSecs'] as int? ?? 60,
      vodPrebufferSecs: m['vodPrebufferSecs'] as int? ?? 15,
      livePrebufferSecs: m['livePrebufferSecs'] as int? ?? 0, // fix700
      dvrEnabled: m['dvrEnabled'] as bool? ?? false,
      audioDownmixStereo: m['audioDownmixStereo'] as bool? ?? true,
      dvrMinutes: m['dvrMinutes'] as int? ?? 5,
      vodDemuxerMaxMB: m['vodDemuxerMaxMB'] as int? ?? 256,
      openTimeoutSecs: m['openTimeoutSecs'] as int? ?? 15,
      bufferingWatchdogSecs: m['bufferingWatchdogSecs'] as int? ?? 12,
      stableThresholdSecs: m['stableThresholdSecs'] as int? ?? 30,
      debugLogging: m['debugLogging'] as bool? ?? false,
      logUserPass: m['logUserPass'] as bool? ?? false,
      epgAutoRefresh: m['epgAutoRefresh'] as bool? ?? true,
      epgRefreshHours: m['epgRefreshHours'] as int? ?? 24,
      epgRefreshHour: m['epgRefreshHour'] as int? ?? 3,
      epgPastDays: m['epgPastDays'] as int? ?? 1,
      epgForecastDays: m['epgForecastDays'] as int? ?? 7,
      epgSearchHours: m['epgSearchHours'] as int? ?? 3,
    );

    if (m['startupGraceMs'] is int) s.startupGraceMs = m['startupGraceMs'];
    if (m['miniDemuxerMaxMB'] is int) s.miniDemuxerMaxMB = m['miniDemuxerMaxMB'];
    if (m['bufferSizeMB'] is int) s.bufferSizeMB = m['bufferSizeMB'];
    if (m['streamCompletedDelayMs'] is int) {
      s.streamCompletedDelayMs = m['streamCompletedDelayMs'];
    }
    if (m['maxReconnectAttempts'] is int) {
      s.maxReconnectAttempts = m['maxReconnectAttempts'];
    }
    if (m['streamScanMaxCount'] is int) {
      s.streamScanMaxCount = m['streamScanMaxCount'];
    }
    if (m['streamScanTimeoutSecs'] is int) {
      s.streamScanTimeoutSecs = m['streamScanTimeoutSecs'];
    }
    if (m['multiViewLayout'] is String) {
      s.multiViewLayout = MultiViewLayout.fromJson(m['multiViewLayout']);
    }
    if (m['multiViewCells1x2'] is String) {
      s.multiViewCells1x2 = m['multiViewCells1x2'];
    }
    if (m['multiViewCells2x2'] is String) {
      s.multiViewCells2x2 = m['multiViewCells2x2'];
    }
    if (m['multiViewAutoRestoreChannels'] is bool) {
      s.multiViewAutoRestoreChannels = m['multiViewAutoRestoreChannels'];
    }
    if (m['contentTypeFilter'] is int) {
      final idx = m['contentTypeFilter'] as int;
      final parsed = ContentTypeFilter.values.elementAtOrNull(idx)
          ?? ContentTypeFilter.all;
      // Validate against enabled content types.
      final available = s.availableContentFilters();
      s.contentTypeFilter =
          available.contains(parsed) ? parsed : ContentTypeFilter.all;
    }
    if (m['searchMethod'] is int) {
      s.searchMethod = SearchMethod.values
              .elementAtOrNull(m['searchMethod'] as int) ??
          SearchMethod.inMemory;
    }
    if (m['safeMode'] is bool) s.safeMode = m['safeMode'];
    if (m['confirmToExit'] is bool) s.confirmToExit = m['confirmToExit']; // fix587

    // fix394: Developer / libmpv advanced tunables. Each guard is `is num`
    // / `is bool` / `is String` — when the field is missing (older backup,
    // schema v3) the constructor default stays in place.
    if (m['devDemuxerReadaheadSecs'] is num) {
      s.devDemuxerReadaheadSecs =
          (m['devDemuxerReadaheadSecs'] as num).toDouble();
    }
    if (m['devNetworkTimeoutSecs'] is num) {
      s.devNetworkTimeoutSecs =
          (m['devNetworkTimeoutSecs'] as num).toInt();
    }
    if (m['devImportFetchTimeoutSecs'] is num) {
      s.devImportFetchTimeoutSecs =
          (m['devImportFetchTimeoutSecs'] as num).toInt();
    }
    if (m['devTlsVerify'] is bool) s.devTlsVerify = m['devTlsVerify'];
    if (m['devVideoSync'] is String) {
      s.devVideoSync = VideoSyncMode.fromJson(m['devVideoSync'] as String);
    }
    if (m['devVideoSyncMaxVideoChange'] is num) {
      s.devVideoSyncMaxVideoChange =
          (m['devVideoSyncMaxVideoChange'] as num).toDouble();
    }
    if (m['devTscale'] is String) {
      s.devTscale = TscaleMode.fromJson(m['devTscale'] as String);
    }
    if (m['devFramedrop'] is String) {
      s.devFramedrop = FrameDropMode.fromJson(m['devFramedrop'] as String);
    }
    if (m['devInterpolation'] is bool) {
      s.devInterpolation = m['devInterpolation'];
    }
    if (m['devCapFpsLowRam'] is bool) {
      s.devCapFpsLowRam = m['devCapFpsLowRam'];
    }
    if (m['devDeband'] is bool) s.devDeband = m['devDeband'];
    if (m['devHwdecImageFormat'] is String) {
      s.devHwdecImageFormat =
          HwdecImageFormat.fromJson(m['devHwdecImageFormat'] as String);
    }
    if (m['devAudioBufferSecs'] is num) {
      s.devAudioBufferSecs = (m['devAudioBufferSecs'] as num).toDouble();
    }
    if (m['devAudioSpdif'] is String) {
      s.devAudioSpdif = AudioSpdifMode.fromJson(m['devAudioSpdif'] as String);
    }
    // fix573: restore the three formerly-dropped fields.
    if (m['multiViewDecode'] is String) {
      s.multiViewDecode =
          MultiViewDecode.fromJson(m['multiViewDecode'] as String);
    }
    if (m['devControlsHideSecs'] is int) {
      s.devControlsHideSecs = m['devControlsHideSecs'] as int;
    }
    if (m['devSkipBackOnResumeSecs'] is int) {
      s.devSkipBackOnResumeSecs = m['devSkipBackOnResumeSecs'] as int; // fix652
    }
    // finding 95: use24HourTime was persisted/reset-preserved but never
    // survived a backup round-trip.
    if (m['use24HourTime'] is bool) s.use24HourTime = m['use24HourTime'] as bool;
    if (m['playerZoomMode'] is String) {
      s.playerZoomMode = ZoomMode.values.firstWhere(
        (e) => e.name == m['playerZoomMode'],
        orElse: () => ZoomMode.fit,
      );
    }

    return s;
  }

  /// fix573: round-trip a [Settings] through the backup map (serialize →
  /// restore) for regression tests. The #11/#573 bug was fields silently
  /// dropped from the payload; this seam lets a test assert each field survives
  /// without needing the DB / file-picker / platform channels.
  @visibleForTesting
  static Settings roundTripForTest(Settings s) =>
      _settingsFromMap(_settingsToMap(s));

  /// Save an arbitrary text string to a user-chosen file location.
  ///
  /// On Android/iOS, `file_picker.saveFile(bytes: ...)` writes the file via
  /// the Storage Access Framework directly and returns a SAF document URI
  /// (e.g. `/document/primary:foo.txt`) which is NOT a real filesystem path.
  /// On desktop, file_picker just returns the chosen path and we must write
  /// the bytes ourselves.
  static Future<void> exportStringToFile(
    BuildContext context, {
    required String content,
    required String suggestedName,
  }) async {
    try {
      final bytes = utf8.encode(content);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: ['txt', 'log', 'json'],
        bytes: Uint8List.fromList(bytes),
      );
      if (path == null) return;

      final isMobile =
          !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      // On desktop file_picker only returns the path — we have to write.
      // On mobile file_picker has already persisted the bytes via SAF.
      if (!isMobile) {
        await File(path).writeAsBytes(bytes);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to $suggestedName')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  /// finding 92: strip credential-bearing query params (username/password/
  /// token/auth/user/pass) from an m3uUrl-style playlist/EPG URL for
  /// credential-free exports. m3uUrl sources store no username/password
  /// fields — the creds live only inside the URL query string, so the
  /// includeCredentials:false path (save-to-file "No (safer)" AND the
  /// issue-report payload) leaked them until now. Non-URL/unparseable input
  /// is returned unchanged.
  static String? _scrubUrlCredentials(String? url) {
    if (url == null || url.trim().isEmpty) return url;
    Uri u;
    try {
      u = Uri.parse(url.trim());
    } catch (_) {
      return url;
    }
    if (u.queryParameters.isEmpty) return url;
    const secretKeys = {'username', 'password', 'token', 'auth', 'pass', 'user'};
    final scrubbed = <String, String>{};
    var changed = false;
    u.queryParameters.forEach((k, v) {
      if (secretKeys.contains(k.toLowerCase())) {
        scrubbed[k] = 'REDACTED';
        changed = true;
      } else {
        scrubbed[k] = v;
      }
    });
    if (!changed) return url;
    return u.replace(queryParameters: scrubbed).toString();
  }

  static Map<String, dynamic> _sourceToMap(
    Source s,
    bool includeCredentials,
  ) =>
      {
        'name': s.name,
        'url': includeCredentials ? s.url : _scrubUrlCredentials(s.url),
        'sourceType': s.sourceType.index,
        'username': includeCredentials ? s.username : null,
        'password': includeCredentials ? s.password : null,
        'enabled': s.enabled,
        'epgUrl':
            includeCredentials ? s.epgUrl : _scrubUrlCredentials(s.epgUrl),
        // fix358: source-level settings were dropped on export, so QR/LAN
        // sources-import lost EPG URL was already carried; these were not.
        'maxConnections': s.maxConnections,
        'color': s.color,
        'sortMode': s.sortMode,
      };
}
