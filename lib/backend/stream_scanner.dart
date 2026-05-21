import 'package:http/http.dart' as http;
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/channel.dart';

/// Lightweight stream probe service.
///
/// Attempts an HTTP GET on each channel URL with a short timeout,
/// reads only the response status, and immediately closes the body.
/// Results are stored in a static map so they survive navigation;
/// call [clearResults] before re-scanning or on source refresh.
class StreamScanner {
  StreamScanner._();

  /// Channel ID → true (accessible) / false (failed / timed-out).
  /// Static so results persist across widget rebuilds and navigation.
  static final Map<int, bool> results = {};

  static void clearResults() => results.clear();

  /// Probe up to [maxChannels] channels from [channels], calling
  /// [onProgress] after each probe. Returns early if [isCancelled]
  /// returns true.
  static Future<void> scan({
    required List<Channel> channels,
    required void Function(int done, int total) onProgress,
    required bool Function() isCancelled,
    Duration timeout = const Duration(seconds: 10),
    int maxChannels = 20,
  }) async {
    final toScan = channels
        .where((c) => c.url?.isNotEmpty == true && c.id != null)
        .take(maxChannels)
        .toList();

    for (int i = 0; i < toScan.length; i++) {
      if (isCancelled()) break;
      final ch = toScan[i];
      final ok = await _probe(ch.url!, timeout);
      results[ch.id!] = ok;
      AppLog.info('StreamScanner: "${ch.name}" → ${ok ? "OK" : "FAIL"}');
      onProgress(i + 1, toScan.length);
    }
  }

  static Future<bool> _probe(String url, Duration timeout) async {
    final client = http.Client();
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) return false;
      final request = http.Request('GET', uri);
      final response = await client.send(request).timeout(timeout);
      // Immediately cancel the body stream — we only care about the status.
      await response.stream.listen(null).cancel();
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}
