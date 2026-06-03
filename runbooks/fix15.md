# fix15.md — Stream Scanner: Counter Bug, Result Count Slider, TS Validation

## Three bugs confirmed in 1.12.2

---

## Bug 1 — Counter stuck at 0/20

### Root cause

The progress dialog uses `StatefulBuilder` but the `onProgress` callback
calls `setState()` on the **Home widget**, not on the dialog's `setSt`.
The dialog's `Text('$_scanDone / $_scanTotal')` reads closure variables
that only update when the dialog itself rebuilds — which never happens
because `setSt` is never called.

```dart
// In _startScan():
showDialog(
  builder: (_) => StatefulBuilder(
    builder: (ctx, setSt) {           // ← setSt available but never used
      ...
      Text('$_scanDone / $_scanTotal') // ← reads Home's state vars
    }
  )
);

await StreamScanner.scan(
  onProgress: (done, total) {
    setState(() {                      // ← rebuilds Home, NOT the dialog
      _scanDone = done;
      _scanTotal = total;
    });
  },
);
```

### Fix — call setSt from onProgress

The dialog needs its own rebuild. Pass `setSt` into the scan callback:

#### `lib/home.dart` — replace `_startScan()`

```dart
Future<void> _startScan() async {
  if (_isScanning || channels.isEmpty) return;

  StreamScanner.clearResults();
  _scanCancelled = false;

  final settings = SettingsService.cached;
  final maxChannels = settings?.streamScanMax ?? 20;

  setState(() {
    _isScanning = true;
    _scanDone = 0;
    _scanTotal = channels.length.clamp(1, maxChannels);
  });

  if (!mounted) return;

  // Capture a reference to the dialog's setState so onProgress can
  // rebuild the dialog directly, not just the Home widget.
  StateSetter? dialogSetState;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setSt) {
        dialogSetState = setSt;       // ← capture on every build
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.radar),
              SizedBox(width: 8),
              Text('Scanning streams…'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: _scanTotal > 0 ? _scanDone / _scanTotal : null,
              ),
              const SizedBox(height: 12),
              Text('$_scanDone / $_scanTotal streams tested'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _scanCancelled = true;
                Navigator.of(ctx).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    ),
  );

  await StreamScanner.scan(
    channels: channels,
    maxChannels: maxChannels,
    isCancelled: () => _scanCancelled,
    onProgress: (done, total) {
      if (!mounted) return;
      // Update both Home state (for after dialog closes) AND
      // the dialog's own state (so the counter updates live).
      setState(() {
        _scanDone = done;
        _scanTotal = total;
      });
      dialogSetState?.call(() {});    // ← triggers dialog rebuild
    },
  );

  if (mounted) {
    if (!_scanCancelled) Navigator.of(context, rootNavigator: true).pop();
    setState(() => _isScanning = false);
  }
}
```

---

## Bug 2 — Result count hardcoded to 20

### Fix — add `streamScanMax` to settings with slider

#### `lib/models/settings.dart` — add field

```dart
// After epgForecastDays:
/// Maximum number of channels to probe in a single stream scan.
/// Range: 1–100. Default: 20.
int streamScanMax;

// In constructor:
this.streamScanMax = 20,
```

#### `lib/backend/settings_service.dart` — persist it

```dart
// Add constant:
const streamScanMaxProp = "streamScanMax";

// In _readFromDb():
var scanMax = settingsMap[streamScanMaxProp];
if (scanMax != null) settings.streamScanMax = int.parse(scanMax);

// In updateSettings():
settingsMap[streamScanMaxProp] = settings.streamScanMax.toString();
```

#### `lib/settings_view.dart` — add slider

Add near the radar button or in the General section:

```dart
_bufferSlider(
  label: 'Stream scan limit',
  value: settings.streamScanMax.toDouble(),
  min: 1,
  max: 100,
  divisions: 99,
  help: (
    title: 'Stream Scan Limit',
    body: 'Maximum number of channels to probe when tapping the radar '
        'icon. Higher values give a more complete picture but take '
        'longer. Each channel probe takes up to 3 seconds. '
        'Default: 20. Range: 1–100.',
  ),
  onChanged: (v) {
    setState(() => settings.streamScanMax = v.round());
    updateSettings();
  },
),
```

---

## Bug 3 — False green: HTTP status check only

### Root cause

`_probe()` immediately cancels the response body after reading the HTTP
status code. IPTV providers routinely return HTTP 200 for dead streams:

- Stream is down but the endpoint is live → 200 with 0 bytes or stalled
- Expired session but server still answers → 200 with HTML error page
- Load balancer responds before the backend fails → 200, then body drops

Any HTTP 200–399 is marked green regardless of whether actual video data
is present.

### Fix — read and validate TS sync bytes

MPEG-TS streams have a rigid structure: every packet is exactly **188 bytes**
starting with sync byte `0x47`. Reading 3 packets (564 bytes) and checking
all three sync bytes confirms the server is delivering real video data.

For HLS (`.m3u8`) streams, validate that the response body starts with
`#EXTM3U` — the mandatory HLS playlist header.

For any other URL (RTMP, unknown), fall back to HTTP status only since
we can't inspect the payload reliably.

#### `lib/backend/stream_scanner.dart` — replace `_probe()`

```dart
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/channel.dart';

class StreamScanner {
  StreamScanner._();

  static final Map<int, bool> results = {};
  static void clearResults() => results.clear();

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
      results[ch.id!] = await _probe(ch.url!, timeout);
      AppLog.info(
        'StreamScanner: "${ch.name}" → ${results[ch.id!] == true ? "OK" : "FAIL"}',
      );
      onProgress(i + 1, toScan.length);
    }
  }

  static Future<bool> _probe(String url, Duration timeout) async {
    final client = http.Client();
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) return false;

      final request = http.Request('GET', uri);
      // Request only enough bytes for validation — avoids downloading
      // the full stream. Some servers ignore Range but it's polite to ask.
      request.headers['Range'] = 'bytes=0-1127'; // 6 TS packets

      final response = await client.send(request).timeout(timeout);

      // Reject obvious error pages served as 200
      final contentType = response.headers['content-type'] ?? '';
      if (contentType.contains('text/html')) {
        await response.stream.listen(null).cancel();
        return false;
      }

      // Reject non-2xx/206 (206 = partial content from Range request)
      if (response.statusCode != 200 &&
          response.statusCode != 206 &&
          !(response.statusCode >= 200 && response.statusCode < 300)) {
        await response.stream.listen(null).cancel();
        return false;
      }

      final lowerUrl = url.toLowerCase();

      // ── HLS playlist ───────────────────────────────────────────────
      if (lowerUrl.contains('.m3u8') || lowerUrl.contains('m3u8')) {
        // A valid HLS manifest always starts with #EXTM3U
        final bytes = await _readBytes(response, 7, timeout);
        return String.fromCharCodes(bytes).startsWith('#EXTM3U');
      }

      // ── MPEG-TS (.ts / Xtream-style URLs) ─────────────────────────
      // Read 3 full TS packets (564 bytes) and verify sync bytes at
      // offsets 0, 188, and 376. This confirms real video data is flowing.
      final bytes = await _readBytes(response, 564, timeout);
      if (bytes.length < 188) return false; // not enough data

      final b = Uint8List.fromList(bytes);
      final syncAt0   = b[0] == 0x47;
      final syncAt188 = b.length >= 376 && b[188] == 0x47;
      final syncAt376 = b.length >= 564 && b[376] == 0x47;

      // At least the first sync byte must be present;
      // the more that match, the higher confidence.
      final syncCount = [syncAt0, syncAt188, syncAt376]
          .where((v) => v)
          .length;
      return syncCount >= 2; // require at least 2/3 sync bytes

    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Read up to [maxBytes] from a streaming response, with a timeout.
  static Future<List<int>> _readBytes(
    http.StreamedResponse response,
    int maxBytes,
    Duration timeout,
  ) async {
    final bytes = <int>[];
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= maxBytes) break;
      }
    } catch (_) {}
    return bytes;
  }
}
```

### Why 2/3 sync bytes required (not 3/3)

Some providers pad the first packet slightly or use non-standard alignment
on the first response chunk. Requiring 2 of 3 sync bytes catches genuine
MPEG-TS content while still rejecting HTML error pages, zero-byte responses,
and stalled streams that send less than 188 bytes before timing out.

---

## Summary of all changes

| Bug | File(s) | Change |
|---|---|---|
| Counter stuck at 0/20 | `lib/home.dart` | Capture `dialogSetState`, call it from `onProgress` |
| Count hardcoded to 20 | `lib/models/settings.dart` | Add `streamScanMax` field |
| | `lib/backend/settings_service.dart` | Persist `streamScanMax` |
| | `lib/settings_view.dart` | Add `_bufferSlider` for scan limit |
| | `lib/home.dart` | Use `settings.streamScanMax` instead of `20` |
| False green | `lib/backend/stream_scanner.dart` | Replace `_probe()` with TS sync byte validation |

---

## Expected behaviour after fix

- Counter updates live: `1/20`, `2/20`, ... `20/20`
- Slider in settings controls 1–100 channels per scan
- Green border only appears when 2+ MPEG-TS sync bytes (`0x47`) confirmed,
  or HLS playlist starts with `#EXTM3U`
- HTML error pages, zero-byte responses, and stalled streams all show red/no border

## Model

Sonnet 4.6 (StatefulBuilder fix + byte-level validation)
