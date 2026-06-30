import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'package:flutter/foundation.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/source.dart';

enum LogLevel { info, warning, error }

/// File-based debug logger.
///
/// Disabled by default. Enable via [AppLogger.enabled] (persisted through
/// [SettingsService]).  Log file lives at {appSupportDir}/app_log.txt.
/// Rotates automatically at [_maxBytes] to prevent unbounded growth.
class AppLogger {
  AppLogger._();
  static final AppLogger _instance = AppLogger._();

  static AppLogger get instance => _instance;

  static const int _maxBytes = 20 * 1024 * 1024; // 20 MB
  static const String _fileName = 'app_log.txt';

  bool _enabled = false;
  File? _file;
  IOSink? _sink;
  bool _initializing = false;

  /// fix374: credential redaction. When [logUserPass] is false (default), each
  /// source username/password substring in a log message is replaced with a
  /// labelled token (`<NAME_USER>`/`<NAME_PASS>`) so logs shared for troubleshooting
  /// never leak provider credentials. Set true only for the developer's own
  /// testing (driven by the "Log User/Pass" debug setting).
  bool logUserPass = false;

  /// (secret, token) pairs built from ALL sources regardless of enabled state,
  /// ordered longest-secret-first so a password that contains the username as a
  /// substring still redacts cleanly. Rebuilt by [setSourceSecrets].
  List<MapEntry<String, String>> _secrets = [];

  bool get enabled => _enabled;

  /// Enable or disable logging. When enabled, the log file is opened for
  /// appending. When disabled, the sink is flushed and closed.
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      await _ensureOpen();
      log('--- Logging enabled ---', level: LogLevel.info);
    } else {
      log('--- Logging disabled ---', level: LogLevel.info);
      await _close();
    }
  }

  /// Write a log entry. No-ops when logging is disabled.
  void log(String message, {LogLevel level = LogLevel.info}) {
    if (!_enabled && level != LogLevel.error) return;
    if (!logUserPass) message = _redactSecrets(message);
    final ts = DateTime.now().toLocal().toString().substring(0, 19);
    final prefix = switch (level) {
      LogLevel.info => 'INFO',
      LogLevel.warning => 'WARN',
      LogLevel.error => 'ERROR',
    };
    final line = '[$ts] [$prefix] $message\n';
    debugPrint(line.trimRight());
    // fix618: write via a synchronous atomic append (flush:true) instead of the
    // buffered IOSink + per-write flush. fix617 called `unawaited(_sink.flush())`
    // after every write; overlapping fl* on a single IOSink throws
    // "Bad state: StreamSink is bound to a stream" under rapid logging (a
    // refresh emits many lines fast), which corrupted the sink and broke
    // logging, the source refresh, AND settings import. writeAsStringSync with
    // flush:true reaches disk immediately (so a hang is still captured — the
    // fix617 goal) but has no shared in-flight stream state, so it cannot enter
    // that bad state. The IOSink is no longer used by log(); it is closed in
    // _close() and otherwise dormant. Best-effort: an I/O error here must never
    // throw out of the synchronous log() API.
    try {
      _file?.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {}
    // fix359: rotation was only evaluated in _ensureOpen() (enable/clear),
    // so a long logging SESSION grew unbounded past _maxBytes. Track bytes
    // written and trigger an async rotation when the cap is crossed. The
    // estimate uses the line length (UTF-16 code units ≈ bytes for ASCII
    // logs); exactness is not required, only that rotation fires mid-session.
    _bytesSinceOpen += line.length;
    if (_bytesSinceOpen > _maxBytes && !_rotating) {
      _rotating = true;
      // ignore: discarded_futures
      _rotate();
    }
  }

  /// fix359: in-session rotation. Closes the sink, renames the current file
  /// to `.old` (replacing any previous `.old`), and reopens a fresh file.
  bool _rotating = false;
  int _bytesSinceOpen = 0;

  Future<void> _rotate() async {
    try {
      await _close();
      final path = await logPath;
      final f = File(path);
      if (await f.exists()) {
        final old = File('$path.old');
        if (await old.exists()) await old.delete();
        await f.rename('$path.old');
      }
      _bytesSinceOpen = 0;
      if (_enabled) await _ensureOpen();
      log('--- Log rotated (size cap) ---', level: LogLevel.info);
    } catch (e) {
      debugPrint('AppLogger: rotation failed — $e');
    } finally {
      _rotating = false;
    }
  }

  void info(String message) => log(message, level: LogLevel.info);
  void warn(String message) => log(message, level: LogLevel.warning);
  void error(String message) => log(message, level: LogLevel.error);

  /// fix374/fix415: rebuild the redaction table from [sources]. Checks EVERY
  /// source regardless of enabled state. Empty/whitespace values are skipped (an
  /// empty secret would otherwise match everywhere). The source name has spaces
  /// stripped to form the token tag, e.g. "A 3000" -> `<A3000_USER>`,
  /// `<A3000_PASS>`, `<A3000_HOST>`.
  ///
  /// fix415: the source HOST is now redacted too — provider URLs in the log
  /// (`http://host:port/.../user/pass/...`) would otherwise leak the server even
  /// after credentials were stripped. The bare host (hostname or IP) from both
  /// `url` and `urlOrigin` is replaced with `<NAME_HOST>`. Entries are sorted
  /// longest-first so a host that contains another as a substring (e.g.
  /// `tv.example.com` vs `example.com`) still redacts cleanly.
  void setSourceSecrets(List<Source> sources) {
    final out = <MapEntry<String, String>>[];
    for (final s in sources) {
      final tag = s.name.replaceAll(' ', '');
      final u = s.username ?? '';
      final p = s.password ?? '';
      if (u.trim().isNotEmpty) out.add(MapEntry(u, '<${tag}_USER>'));
      if (p.trim().isNotEmpty) out.add(MapEntry(p, '<${tag}_PASS>'));
      for (final raw in [s.url, s.urlOrigin]) {
        final h = _hostOf(raw);
        if (h != null) out.add(MapEntry(h, '<${tag}_HOST>'));
      }
    }
    out.sort((a, b) => b.key.length.compareTo(a.key.length));
    _secrets = out;
  }

  /// fix415: extract the bare host (hostname or IP, no scheme/port/path) from a
  /// source URL so it can be redacted. A scheme is prepended when missing so a
  /// bare `host:port` still parses. Returns null for empty/unparseable input.
  String? _hostOf(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    var u = url.trim();
    if (!u.contains('://')) u = 'http://$u';
    try {
      final h = Uri.parse(u).host;
      return h.isEmpty ? null : h;
    } catch (_) {
      return null;
    }
  }

  /// fix374: replace every known credential literal in [s] with its token.
  /// String.replaceAll uses literal (non-regex) matching for a String pattern,
  /// so credential values containing regex metacharacters are handled safely.
  String _redactSecrets(String s) {
    if (_secrets.isEmpty) return s;
    for (final e in _secrets) {
      if (s.contains(e.key)) s = s.replaceAll(e.key, e.value);
    }
    return s;
  }

  /// fix415: public entry point so the issue-reporter can re-scrub the entire
  /// log text at transmit time (belt-and-suspenders), and so redaction is unit
  /// testable. Always strips host/username/password using the current table,
  /// independent of the [logUserPass] flag.
  String scrubSecrets(String text) => _redactSecrets(text);

  /// Returns the path of the log file (whether or not logging is enabled).
  Future<String> get logPath async {
    final dir = await Utils.appDir;
    return '$dir/$_fileName';
  }

  /// fix616: path of the sidecar marker that records which app version the log
  /// was last cleared for. Deliberately a PLAIN FILE next to the log — NOT a
  /// row in db.sqlite's settings table. The version-change log rotation used to
  /// read its marker from db.sqlite; when a sources refresh left db.sqlite
  /// wiped/empty, the marker read came back absent, so the rotation fired on a
  /// SAME-VERSION restart and destroyed the very log that would explain the bad
  /// refresh. A file in the app dir survives a db.sqlite wipe, so the log is
  /// preserved across exactly the failures we most need to diagnose.
  Future<String> get _clearedVersionMarkerPath async {
    final dir = await Utils.appDir;
    return '$dir/.log_cleared_version';
  }

  /// Read the version the log was last cleared for, or '' if the marker is
  /// missing/unreadable (treated as "never cleared for any version").
  Future<String> readClearedVersionMarker() async {
    try {
      final f = File(await _clearedVersionMarkerPath);
      if (!await f.exists()) return '';
      return (await f.readAsString()).trim();
    } catch (_) {
      return '';
    }
  }

  /// Record [version] as the version the log has been cleared for. Best-effort:
  /// a write failure must never break startup, it just means the next boot may
  /// re-clear once.
  Future<void> writeClearedVersionMarker(String version) async {
    try {
      final f = File(await _clearedVersionMarkerPath);
      await f.writeAsString(version);
    } catch (e) {
      log('writeClearedVersionMarker failed: $e', level: LogLevel.warning);
    }
  }

  /// Returns log file contents as a string. Returns empty string if the file
  /// doesn't exist yet.
  Future<String> readLog() async {
    final path = await logPath;
    final f = File(path);
    if (!await f.exists()) return '';
    return f.readAsString();
  }

  /// Delete the log file and reset the sink.
  ///
  /// fix617 (THIS BUILD ONLY — revert after the phone-hang investigation): do
  /// NOT delete the log file. Instead append a divider line recording where a
  /// real clear WOULD have started, so no prior session is ever lost while we
  /// chase the hang. The Xtream-dump sweep is also skipped so nothing in the
  /// app dir is removed. Restore the original delete behaviour once the hang is
  /// understood.
  Future<void> clearLog() async {
    if (_enabled) await _ensureOpen();
    int lineCount = 0;
    try {
      final f = File(await logPath);
      if (await f.exists()) {
        lineCount = (await f.readAsLines()).length;
      }
    } catch (_) {}
    log('=== LOG CLEAR REQUESTED — would delete from line $lineCount '
        '(fix617: delete suppressed for this build; log preserved) ===',
        level: LogLevel.info);
    await stampVersion('log clear requested (suppressed)'); // fix357
  }

  /// fix357: write the app version into the log. Called on every clear and
  /// before every export/save so a log file always identifies its version
  /// (the 2026-06-12 Shield log had no version line at all).
  Future<void> stampVersion(String context) async {
    try {
      final info = await PackageInfo.fromPlatform();
      log('Free4Me-IPTV ${info.version}+${info.buildNumber} — $context',
          level: LogLevel.info);
    } catch (e) {
      log('version stamp failed ($context): $e', level: LogLevel.warning);
    }
  }

  // fix266: delete every `xtream_dump_*.json` in the app dir. Best-effort —
// a failure on one file does not stop the rest, and a failure of the whole
// sweep does not block clearing the text log.
// fix617 (revert together with the original clearLog()): temporarily
// unreferenced because the suppressed-deletion build no longer sweeps these.
// ignore: unused_element
  Future<void> _clearXtreamDumps() async {
    try {
      final dir = await Utils.appDir;
      final d = Directory(dir);
      if (!await d.exists()) return;
      await for (final entry in d.list(followLinks: false)) {
        if (entry is File) {
          final name = entry.path.split('/').last;
          if (name.startsWith('xtream_dump_') && name.endsWith('.json')) {
            try {
              await entry.delete();
            } catch (_) {
              // ignore a single stubborn file; keep deleting the others
            }
          }
        }
      }
    } catch (_) {
      // ignore: clearing the dumps must never block clearing the log
    }
  }


  Future<void> _ensureOpen() async {
    _bytesSinceOpen = 0; // fix359
    // fix618: _file is the open sentinel now (the IOSink is no longer used by
    // log(); see the synchronous append there). Opening a long-lived
    // openWrite() sink AND doing writeAsStringSync on the same path is two write
    // handles to one file, so the sink is dropped entirely.
    if (_file != null || _initializing) return;
    _initializing = true;
    try {
      final path = await logPath;
      _file = File(path);
      // Rotate if too large
      if (await _file!.exists()) {
        final size = await _file!.length();
        if (size > _maxBytes) {
          final rotated = File('$path.old');
          if (await rotated.exists()) await rotated.delete();
          await _file!.rename('$path.old');
          _file = File(path);
        }
      }
      // Ensure the file exists so the first synchronous append has a target.
      if (!await _file!.exists()) {
        await _file!.create(recursive: true);
      }
    } catch (e) {
      debugPrint('AppLogger: failed to open log file: $e');
    } finally {
      _initializing = false;
    }
  }

  Future<void> _close() async {
    // fix618: the IOSink is no longer opened by _ensureOpen (log() appends
    // synchronously). Defensively flush/close any sink a prior build/path may
    // have left, then clear the open sentinel (_file).
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _file = null;
  }
}

/// Global shorthand so any file can call `AppLog.info(...)` without
/// carrying around the singleton reference.
// ignore: non_constant_identifier_names
final AppLog = AppLogger.instance;
