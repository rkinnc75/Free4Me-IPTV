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

  /// fix759: the sources last passed to [setSourceSecrets], retained so
  /// [addSourceSecrets] can rebuild the table with one brand-new source
  /// appended before it has been persisted / re-fetched.
  List<Source> _knownSources = [];

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
    // fix759: retain the list so addSourceSecrets can rebuild the table with a
    // brand-new source appended (see addSourceSecrets).
    _knownSources = List<Source>.of(sources);
    final out = <MapEntry<String, String>>[];
    for (final s in sources) {
      final tag = s.name.replaceAll(' ', '');
      final u = s.username ?? '';
      final p = s.password ?? '';
      // finding 45: also register the percent-encoded forms so a URL-encoded
      // credential in a logged URL still redacts. encodeComponent covers
      // space->%20 / @->%40 / +->%2B; encodeQueryComponent covers space->+.
      if (u.trim().isNotEmpty) {
        out.add(MapEntry(u, '<${tag}_USER>'));
        final eu = Uri.encodeComponent(u);
        if (eu != u) out.add(MapEntry(eu, '<${tag}_USER>'));
        final qu = Uri.encodeQueryComponent(u);
        if (qu != u && qu != eu) out.add(MapEntry(qu, '<${tag}_USER>'));
      }
      if (p.trim().isNotEmpty) {
        out.add(MapEntry(p, '<${tag}_PASS>'));
        final ep = Uri.encodeComponent(p);
        if (ep != p) out.add(MapEntry(ep, '<${tag}_PASS>'));
        final qp = Uri.encodeQueryComponent(p);
        if (qp != p && qp != ep) out.add(MapEntry(qp, '<${tag}_PASS>'));
      }
      for (final raw in [s.url, s.urlOrigin]) {
        final h = _hostOf(raw);
        if (h != null) out.add(MapEntry(h, '<${tag}_HOST>'));
      }
      // fix: the manual EPG-URL override (source.epgUrl) can point at a
      // DIFFERENT host than the streaming url/urlOrigin — e.g. a source whose
      // guide is served from another provider's XMLTV endpoint. That host was
      // never in the redaction table, so it either leaked in cleartext or, when
      // its string matched a DIFFERENT source's streaming host, got mislabelled
      // under that other source's tag (a Dino EPG line showing as <Trex_HOST>).
      // Redact it under this source's own EPG tag. (Xtream's auto-fallback EPG
      // URL is built from the source's own url host, already covered above.)
      final epgHost = _hostOf(s.epgUrl);
      if (epgHost != null) out.add(MapEntry(epgHost, '<${tag}_EPG_HOST>'));
      // findings 82/40: credentials embedded in the URL query string
      // (m3uUrl `?username=U&password=P`, or an EPG URL with `?token=...`) are
      // NOT stored in s.username/s.password, so pull them from every URL and
      // redact each value.
      for (final raw in [s.url, s.urlOrigin, s.epgUrl]) {
        for (final v in _credsFromUrl(raw)) {
          out.add(MapEntry(v, '<${tag}_CRED>'));
        }
      }
      // finding 40: an opaque path token in the EPG URL
      // (`/epg/ABCDEF123456.xml.gz`) is a bearer secret too — redact long path
      // segments (cosmetic over-redaction of a legit 12+ char segment is fine).
      final epgUri = _tryParseUri(s.epgUrl);
      if (epgUri != null) {
        for (final seg in epgUri.pathSegments) {
          if (seg.length >= 12) out.add(MapEntry(seg, '<${tag}_EPG_TOK>'));
        }
      }
      // fix759 (Jun-audit finding 5): credentials in the URL *authority*
      // (`http://user:pass@host/...`) live in neither s.username/password nor
      // the query string, so the rules above masked only the host and left the
      // `user:pass@` prefix in cleartext (e.g. a raw m3u URL logged in
      // m3u.dart). Register the userInfo and its user:pass split from every
      // source URL; <3-char values are skipped, matching the query-cred rule.
      for (final raw in [s.url, s.urlOrigin, s.epgUrl]) {
        final ui = _tryParseUri(raw)?.userInfo ?? '';
        if (ui.isEmpty) continue;
        if (ui.length >= 3) out.add(MapEntry(ui, '<${tag}_CRED>'));
        final colon = ui.indexOf(':');
        if (colon > 0) {
          final uiUser = ui.substring(0, colon);
          final uiPass = ui.substring(colon + 1);
          if (uiUser.length >= 3) out.add(MapEntry(uiUser, '<${tag}_USER>'));
          if (uiPass.length >= 3) out.add(MapEntry(uiPass, '<${tag}_PASS>'));
        }
      }
    }
    out.sort((a, b) => b.key.length.compareTo(a.key.length));
    _secrets = out;
  }

  /// fix759 (Jun-audit finding 6): register a brand-new source's secrets
  /// WITHOUT waiting for the next full rebuild. [setSourceSecrets] runs only at
  /// startup (main.dart) and after Sql.getSources(); neither fires between
  /// constructing a new source and the first fetch that logs its URL
  /// (Utils.processSource -> xtream/m3u), so the new host/credentials would
  /// otherwise leak in cleartext on the very first add. Calling this at the top
  /// of processSource rebuilds the table from the known sources plus [source].
  /// Only a source whose name is not already covered triggers a rebuild —
  /// processSource re-runs on every refresh of an EXISTING source, and an
  /// unconditional append would grow the table without bound. Source names are
  /// unique (setup.dart enforces it), so name is a safe identity key here; an
  /// already-known source is a no-op because setSourceSecrets already holds it.
  void addSourceSecrets(Source source) {
    if (_knownSources.any((s) => s.name == source.name)) return;
    setSourceSecrets([..._knownSources, source]);
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

  /// findings 40/82: parse a URL for redaction, prepending a scheme when
  /// missing (so a bare `host:port` still parses). Returns null when
  /// empty/unparseable.
  Uri? _tryParseUri(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    var u = url.trim();
    if (!u.contains('://')) u = 'http://$u';
    return Uri.tryParse(u);
  }

  /// findings 40/82: credential values carried in a URL query string
  /// (`?username=U&password=P&token=T`). These are NOT in s.username/password
  /// for m3uUrl / token-EPG sources, so they must be pulled from the URL and
  /// redacted. Values shorter than 3 chars are skipped (redacting "1"/"on"
  /// everywhere would mangle the log for no security gain).
  static const _credQueryKeys = {
    'username', 'user', 'password', 'pass', 'token', 'auth',
  };
  Iterable<String> _credsFromUrl(String? url) {
    final uri = _tryParseUri(url);
    if (uri == null) return const [];
    final out = <String>[];
    uri.queryParameters.forEach((k, v) {
      if (_credQueryKeys.contains(k.toLowerCase()) && v.trim().length >= 3) {
        out.add(v);
      }
    });
    return out;
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
  /// fix642: restored the real clear (fix617's delete-suppression is reverted
  /// now that the phone-hang investigation is settled). Deletes the log file,
  /// sweeps the Xtream dumps, and re-stamps the version. Written against fix618
  /// semantics: `_file` is the open sentinel and `log()` appends synchronously,
  /// so we drop the handle via `_close()`, delete, then reopen with
  /// `_ensureOpen()` if logging is currently enabled.
  Future<void> clearLog() async {
    // Drop the open handle so the delete targets a closed file.
    await _close();
    try {
      final f = File(await logPath);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // ignore: a delete failure must never throw out of clearLog
    }
    // fix266: also remove the raw Xtream dump files from the app dir.
    await _clearXtreamDumps();
    // Reopen a fresh (empty) file if logging is on, then stamp the version so
    // the new log identifies its build (fix357).
    if (_enabled) await _ensureOpen();
    await stampVersion('log + metrics cleared'); // fix357
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
