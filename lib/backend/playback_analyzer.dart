import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/backend/setting_bounds.dart';
import 'package:open_tv/models/settings.dart';

// ── Data model ────────────────────────────────────────────────────────────────

/// Per-session playback metrics extracted from the app's debug log.
class PlaybackMetrics {
  DateTime sessionStart; // fix162: settable for dedup key
  int streamsOpened = 0;

  // startup
  final List<int> timeToFirstFrameMs = [];
  final List<int> timeToStableMs = [];
  int startupVisibleRebuffers = 0;

  // steady-state
  int totalRebuffers = 0;
  int visibleRebuffers = 0;
  final List<int> rebufferDurationsMs = [];
  double sessionMinutes = 0;

  // reconnects
  int reconnectsWatchdog = 0;
  int reconnectsError = 0;
  int gaveUp = 0;

  PlaybackMetrics(this.sessionStart);

  double get rebuffersPerHour =>
      sessionMinutes > 0 ? totalRebuffers / (sessionMinutes / 60.0) : 0;

  int get medianFirstFrameMs => _median(timeToFirstFrameMs);
  int get medianStableMs => _median(timeToStableMs);
  int get medianRebufferMs => _median(rebufferDurationsMs);

  static int _median(List<int> list) {
    if (list.isEmpty) return 0;
    final sorted = List<int>.from(list)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : ((sorted[mid - 1] + sorted[mid]) ~/ 2);
  }
}

/// Weighted aggregate across multiple stored sessions.
class AggregatedMetrics {
  final int sessionCount;
  final double totalMinutes;
  final int totalStreams;
  final double rebuffersPerHour;
  final int medianFirstFrameMs;
  final int medianStableMs;
  final int medianRebufferMs;
  final double startupVisibleRebufferRate; // fraction of streams with startup visible rebuffer
  final double reconnectsWatchdogPerHour;

  const AggregatedMetrics({
    required this.sessionCount,
    required this.totalMinutes,
    required this.totalStreams,
    required this.rebuffersPerHour,
    required this.medianFirstFrameMs,
    required this.medianStableMs,
    required this.medianRebufferMs,
    required this.startupVisibleRebufferRate,
    required this.reconnectsWatchdogPerHour,
  });

  bool get hasSufficientData =>
      totalMinutes >= 10 && totalStreams >= 2; // fix162: lower bar
}

// ── Log parser ────────────────────────────────────────────────────────────────

class PlaybackAnalyzer {
  /// Parse the most-recent session from the log text.
  static PlaybackMetrics parseLatestSession(String logText) {
    final sessions = parseAllSessions(logText);
    return sessions.isNotEmpty
        ? sessions.last
        : PlaybackMetrics(DateTime.now());
  }

  /// Parse ALL sessions present in the log. A new session begins at each
  /// "App started" or "Logging enabled" banner.
  static List<PlaybackMetrics> parseAllSessions(String logText) {
    final lines = logText.split('\n');
    final sessions = <List<String>>[];
    var current = <String>[];

    for (final line in lines) {
      if (line.contains('--- Logging enabled ---') ||
          line.contains('App started')) {
        if (current.isNotEmpty) sessions.add(current);
        current = [line];
      } else {
        current.add(line);
      }
    }
    if (current.isNotEmpty) sessions.add(current);

    return sessions.map(_parseSession).toList();
  }

  static PlaybackMetrics _parseSession(List<String> lines) {
    DateTime? firstTs;
    DateTime? lastTs;
    DateTime? openTs;
    DateTime? bufTrueTs;
    bool? lastBuffering;
    int startupGraceMs = 1500; // conservative default; real value not in log
    final m = PlaybackMetrics(DateTime.now());

    for (final line in lines) {
      final ts = _parseTs(line);
      if (ts != null) {
        firstTs ??= ts;
        lastTs = ts;
      }

      // Stream open
      if (line.contains('MpvEngine: open() command sent') ||
          line.contains('open() command sent')) {
        m.streamsOpened++;
        openTs = ts;
        lastBuffering = null;
        bufTrueTs = null;
      }

      // First frame
      if (line.contains('startup watchdog cancelled')) {
        if (openTs != null && ts != null) {
          final diff = ts.difference(openTs).inMilliseconds;
          if (diff > 0 && diff < 60000) m.timeToFirstFrameMs.add(diff);
        }
      }

      // Stable
      if (line.contains('stream stable for')) {
        if (openTs != null && ts != null) {
          final diff = ts.difference(openTs).inMilliseconds;
          if (diff > 0 && diff < 120000) m.timeToStableMs.add(diff);
        }
      }

      // Buffering start
      if (line.contains('Player: buffering=true') ||
          line.contains('buffering=true')) {
        if (lastBuffering != true) {
          lastBuffering = true;
          bufTrueTs = ts;
          m.totalRebuffers++;
          // startup rebuffer: within grace + 3s of open
          if (openTs != null && ts != null) {
            final sinceOpen = ts.difference(openTs).inMilliseconds;
            if (sinceOpen < startupGraceMs + 3000) {
              m.startupVisibleRebuffers++;
            }
          }
        }
      }

      // Buffering end
      if (line.contains('Player: buffering=false') ||
          line.contains('buffering=false')) {
        if (lastBuffering == true && bufTrueTs != null && ts != null) {
          final dur = ts.difference(bufTrueTs).inMilliseconds;
          if (dur >= 0 && dur < 300000) m.rebufferDurationsMs.add(dur);
        }
        lastBuffering = false;
        bufTrueTs = null;
      }

      // Visible rebuffer (past grace)
      if (line.contains('overlay → "Buffering"') ||
          line.contains('"Buffering..."')) {
        m.visibleRebuffers++;
      }

      // Reconnects
      if (line.contains('onDisconnect') || line.contains('attempt')) {
        if (line.contains('watchdog') || line.contains('buffering watchdog')) {
          m.reconnectsWatchdog++;
        } else if (line.contains('player error') ||
            line.contains('ffurl') ||
            line.contains('reason="error"')) {
          m.reconnectsError++;
        }
      }

      // Gave up
      if (line.contains('max reconnects reached') ||
          line.contains('gave up')) {
        m.gaveUp++;
      }
    }

    if (firstTs != null && lastTs != null) {
      m.sessionStart = firstTs; // fix162: real session start for dedup
      m.sessionMinutes =
          lastTs.difference(firstTs).inSeconds / 60.0;
    }

    return m;
  }

  static DateTime? _parseTs(String line) {
    // Format: [YYYY-MM-DD HH:MM:SS] [LEVEL] ...
    final m = RegExp(r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]').firstMatch(line);
    if (m == null) return null;
    return DateTime.tryParse(m.group(1)!);
  }
}

// ── Recommendation engine ────────────────────────────────────────────────────

class SettingRecommendation {
  final String settingKey;
  final String label;
  final num currentValue;
  final num suggestedValue;
  final String rationale;
  final bool requiresRestart;

  const SettingRecommendation({
    required this.settingKey,
    required this.label,
    required this.currentValue,
    required this.suggestedValue,
    required this.rationale,
    required this.requiresRestart,
  });
}

class Recommender {
  /// Returns [] if insufficient data. Never recommends past DeviceMemory caps.
  static List<SettingRecommendation> recommend(
      AggregatedMetrics agg, Settings s) {
    if (!agg.hasSufficientData) return [];

    final recs = <SettingRecommendation>[];

    // Rule A — frequent steady-state rebuffers → bigger cache + buffer
    if (agg.rebuffersPerHour >= 4) {
      final newCache = (s.liveCacheSecs + 15)
          .clamp(SettingBounds.liveCacheMin, SettingBounds.liveCacheMax);
      if (newCache > s.liveCacheSecs) {
        recs.add(SettingRecommendation(
          settingKey: 'liveCacheSecs',
          label: 'Live cache (seconds)',
          currentValue: s.liveCacheSecs,
          suggestedValue: newCache,
          rationale: 'About ${agg.rebuffersPerHour.toStringAsFixed(1)} rebuffers/'
              'hour across ${agg.totalMinutes.round()} min watched. A longer '
              'read-ahead reduces mid-stream rebuffering.',
          requiresRestart: false,
        ));
      }
      final newBuf = (s.bufferSizeMB + 64)
          .clamp(SettingBounds.bufferSizeMin, SettingBounds.bufferSizeMax);
      if (newBuf > s.bufferSizeMB) {
        recs.add(SettingRecommendation(
          settingKey: 'bufferSizeMB',
          label: 'Buffer size (MB)',
          currentValue: s.bufferSizeMB,
          suggestedValue: newBuf,
          rationale: 'More demuxer read-ahead so playback does not outrun the '
              'buffer. Capped at your device limit '
              '(${DeviceMemory.maxBufferSizeMb} MB).',
          requiresRestart: true,
        ));
      }
    }

    // Rule B — visible rebuffer right after start → widen startup grace
    if (agg.startupVisibleRebufferRate >= 0.4 &&
        s.startupGraceMs < 2000) {
      final newGrace = (s.startupGraceMs + 700).clamp(
          SettingBounds.startupGraceMin, SettingBounds.startupGraceMax);
      recs.add(SettingRecommendation(
        settingKey: 'startupGraceMs',
        label: 'Startup grace (ms)',
        currentValue: s.startupGraceMs,
        suggestedValue: newGrace,
        rationale: 'Streams often show a brief "Buffering" right after starting '
            'while the cache fills. A longer grace hides that initial settle.',
        requiresRestart: false,
      ));
    }

    // Rule C — watchdog firing with short rebuffers → watchdog too aggressive
    if (agg.reconnectsWatchdogPerHour >= 2 &&
        agg.medianRebufferMs < 8000 &&
        s.bufferingWatchdogSecs < 20) {
      final newWd = (s.bufferingWatchdogSecs + 5).clamp(
          SettingBounds.bufferingWatchdogMin,
          SettingBounds.bufferingWatchdogMax);
      recs.add(SettingRecommendation(
        settingKey: 'bufferingWatchdogSecs',
        label: 'Buffering watchdog (s)',
        currentValue: s.bufferingWatchdogSecs,
        suggestedValue: newWd,
        rationale: 'The watchdog is triggering reconnects on brief stalls that '
            'recover on their own. A longer watchdog avoids unnecessary '
            'reconnects.',
        requiresRestart: false,
      ));
    }

    // Rule D — slow first frame → longer open timeout
    if (agg.medianFirstFrameMs >= 6000 && s.openTimeoutSecs < 20) {
      final newTo = (s.openTimeoutSecs + 4).clamp(
          SettingBounds.openTimeoutMin, SettingBounds.openTimeoutMax);
      recs.add(SettingRecommendation(
        settingKey: 'openTimeoutSecs',
        label: 'Open timeout (s)',
        currentValue: s.openTimeoutSecs,
        suggestedValue: newTo,
        rationale: 'Streams take a median '
            '${(agg.medianFirstFrameMs / 1000).toStringAsFixed(1)}s to start. '
            'A longer open timeout prevents giving up on slow-starting streams.',
        requiresRestart: false,
      ));
    }

    return recs;
  }
}
