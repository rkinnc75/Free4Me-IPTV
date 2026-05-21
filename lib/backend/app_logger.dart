import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_tv/backend/utils.dart';

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
    final ts = DateTime.now().toLocal().toString().substring(0, 19);
    final prefix = switch (level) {
      LogLevel.info => 'INFO',
      LogLevel.warning => 'WARN',
      LogLevel.error => 'ERROR',
    };
    final line = '[$ts] [$prefix] $message\n';
    debugPrint(line.trimRight());
    _sink?.write(line);
  }

  void info(String message) => log(message, level: LogLevel.info);
  void warn(String message) => log(message, level: LogLevel.warning);
  void error(String message) => log(message, level: LogLevel.error);

  /// Returns the path of the log file (whether or not logging is enabled).
  Future<String> get logPath async {
    final dir = await Utils.appDir;
    return '$dir/$_fileName';
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
  Future<void> clearLog() async {
    await _close();
    final path = await logPath;
    final f = File(path);
    if (await f.exists()) await f.delete();
    if (_enabled) await _ensureOpen();
    log('--- Log cleared ---', level: LogLevel.info);
  }

  // ── internals ────────────────────────────────────────────────────────────

  Future<void> _ensureOpen() async {
    if (_sink != null || _initializing) return;
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
      _sink = _file!.openWrite(mode: FileMode.append);
    } catch (e) {
      debugPrint('AppLogger: failed to open log file: $e');
    } finally {
      _initializing = false;
    }
  }

  Future<void> _close() async {
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
