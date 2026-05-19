import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/programme.dart';
import 'package:open_tv/models/source.dart';

/// Builds the catchup / time-shift URL for a given programme on a given
/// channel + source.
///
/// Returns `null` when:
///   - the channel doesn't support catchup ([Channel.supportsCatchup] false)
///   - the programme started in the future or before the catchup window
///   - the catchup metadata is malformed
///
/// Supported [Channel.catchupType] values:
///   - **`xc`** (Xtream) — builds the standard Xtream timeshift URL
///   - **`append`** — appends [Channel.catchupSource] (a query suffix) to the
///     live URL with placeholders substituted
///   - **`shift`** — appends `?utc=…&lutc=…` query params to the live URL
///   - **`default`** / **`flussonic`** / explicit URL — treats
///     [Channel.catchupSource] as a full URL template
///
/// Recognized placeholders (M3U conventions):
///   `{Y}` `{m}` `{d}` `{H}` `{M}` `{S}` — UTC start time components
///   `{utc}` — Unix epoch of start (seconds)
///   `{lutc}` — Unix epoch "now" (live UTC, seconds)
///   `{duration}` — programme duration in seconds
///   `${start}` `${end}` `${timestamp}` — Kodi-style aliases
class CatchupUrl {
  CatchupUrl._();

  /// Returns the catchup URL for [programme] on [channel] / [source],
  /// or null if catchup is unavailable for that programme.
  static String? build({
    required Channel channel,
    required Programme programme,
    required Source source,
  }) {
    if (!channel.supportsCatchup) return null;
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Don't offer catchup for future programmes
    if (programme.startUtc > nowEpoch) return null;

    // Honor catchup-days window when known
    final days = channel.catchupDays;
    if (days != null && days > 0) {
      final windowStart = nowEpoch - days * 86400;
      if (programme.startUtc < windowStart) return null;
    }

    final type = channel.catchupType!.toLowerCase();

    switch (type) {
      case 'xc':
        return _buildXtream(channel, programme, source);
      case 'append':
        return _appendToLive(channel, programme, nowEpoch);
      case 'shift':
        return _shiftQuery(channel, programme, nowEpoch);
      case 'default':
      case 'flussonic':
      case 'fs':
        return _substitute(channel.catchupSource, programme, nowEpoch);
      default:
        // Treat any other value as "default" — most providers use a template
        return _substitute(channel.catchupSource, programme, nowEpoch);
    }
  }

  // ── Xtream Codes timeshift ────────────────────────────────────────────────
  // http://{host}:{port}/streaming/timeshift.php?username={u}&password={p}
  //   &stream={id}&start=YYYY-MM-DD:HH-MM&duration={duration_minutes}
  static String? _buildXtream(
    Channel channel,
    Programme programme,
    Source source,
  ) {
    final origin = _xtreamOrigin(source);
    if (origin == null) return null;
    if (source.username == null || source.password == null) return null;
    final streamId = channel.streamId;
    if (streamId == null || streamId <= 0) return null;

    final start = DateTime.fromMillisecondsSinceEpoch(
      programme.startUtc * 1000,
      isUtc: true,
    );
    final startStr =
        '${_pad(start.year, 4)}-${_pad(start.month)}-${_pad(start.day)}:'
        '${_pad(start.hour)}-${_pad(start.minute)}';
    final durationMins = (programme.duration.inSeconds / 60).ceil();

    return '$origin/streaming/timeshift.php'
        '?username=${Uri.encodeComponent(source.username!)}'
        '&password=${Uri.encodeComponent(source.password!)}'
        '&stream=$streamId'
        '&start=$startStr'
        '&duration=$durationMins';
  }

  static String? _xtreamOrigin(Source source) {
    if (source.urlOrigin?.isNotEmpty == true) return source.urlOrigin;
    final url = source.url;
    if (url == null) return null;
    try {
      final parsed = Uri.parse(url);
      if (parsed.scheme == 'http' || parsed.scheme == 'https') {
        return parsed.origin;
      }
    } catch (_) {}
    return null;
  }

  // ── catchup="append" ──────────────────────────────────────────────────────
  // catchup-source contains a query suffix; append to live URL with
  // placeholders resolved against start time.
  static String? _appendToLive(
    Channel channel,
    Programme programme,
    int nowEpoch,
  ) {
    final base = channel.url;
    if (base == null) return null;
    final suffix = _substitute(channel.catchupSource, programme, nowEpoch);
    if (suffix == null) return null;
    final sep = base.contains('?') ? '&' : '?';
    return '$base$sep${suffix.startsWith('?') || suffix.startsWith('&') ? suffix.substring(1) : suffix}';
  }

  // ── catchup="shift" ───────────────────────────────────────────────────────
  // Append ?utc={start}&lutc={now} to the live URL.
  static String _shiftQuery(
    Channel channel,
    Programme programme,
    int nowEpoch,
  ) {
    final base = channel.url ?? '';
    final sep = base.contains('?') ? '&' : '?';
    return '$base${sep}utc=${programme.startUtc}&lutc=$nowEpoch';
  }

  // ── Placeholder substitution ──────────────────────────────────────────────
  static String? _substitute(
    String? template,
    Programme programme,
    int nowEpoch,
  ) {
    if (template == null || template.isEmpty) return null;
    final start = DateTime.fromMillisecondsSinceEpoch(
      programme.startUtc * 1000,
      isUtc: true,
    );
    final duration = programme.duration.inSeconds;

    String out = template;
    final replacements = <String, String>{
      // M3U/IPTV standard placeholders
      '{Y}': _pad(start.year, 4),
      '{m}': _pad(start.month),
      '{d}': _pad(start.day),
      '{H}': _pad(start.hour),
      '{M}': _pad(start.minute),
      '{S}': _pad(start.second),
      '{utc}': programme.startUtc.toString(),
      '{lutc}': nowEpoch.toString(),
      '{duration}': duration.toString(),
      // Kodi-style aliases (also seen as ${start} ${end} ${timestamp})
      r'${start}': programme.startUtc.toString(),
      r'${end}': programme.stopUtc.toString(),
      r'${timestamp}': nowEpoch.toString(),
      r'${duration}': duration.toString(),
    };
    replacements.forEach((k, v) {
      out = out.replaceAll(k, v);
    });
    return out;
  }

  static String _pad(int n, [int width = 2]) =>
      n.toString().padLeft(width, '0');
}
