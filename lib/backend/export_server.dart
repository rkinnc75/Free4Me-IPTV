import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:open_tv/backend/app_logger.dart';

/// A single named payload to serve.
class ExportItem {
  final String key;          // url-safe id, e.g. 'backup' / 'log'
  final String filename;     // download name
  final String label;        // human label for the index page
  // fix328: file-backed instead of in-memory. The export bundle is written to
  // temp files and streamed from disk, so the TV box never holds every file
  // (huge source dumps + their byte copies + the zip) in the heap at once
  // (observed OOM on a 2GB box when starting with the source data).
  final String filePath;
  final int sizeBytes;
  final String contentType;

  const ExportItem({
    required this.key,
    required this.filename,
    required this.label,
    required this.filePath,
    required this.sizeBytes,
    required this.contentType,
  });
}

/// Local HTTP server (port 9479) that serves one or more payloads over the
/// LAN for download from a phone or PC. Built for Google TV where the
/// Storage Access Framework is unavailable. Local-network only, no auth,
/// short-lived, auto-stops after 10 minutes idle.
class ExportServer {
  static const int port = 9479;

  HttpServer? _server;
  final List<ExportItem> _items;
  final String? capturedAt; // fix166
  /// fix329: human-readable device name shown in the portal header so the
  /// export identifies its origin device (aligns with device-tagged files).
  final String? deviceName;
  /// fix317: called with the uploaded settings-file bytes when the user POSTs
  /// a sources import from the portal. Returns the number of sources imported
  /// (or -1 on error). Null disables the import form.
  final Future<int> Function(List<int> bytes)? onImportSources;
  Timer? _idleTimeout;

  /// fix347 (review HIGH-4): one-time access token. The server binds on
  /// anyIPv4 with no auth, and /import-sources WRITES to the source list and
  /// then triggers a network refresh — so while the dialog is open (up to the
  /// 10-min idle window) anyone on the same LAN could inject auto-refreshing
  /// sources. Every route now requires `?t=token`; the QR and the displayed
  /// URLs carry it, so possession of the QR/dialog IS the authorisation.
  /// 12 hex chars (48 bits) is ample for a short-lived LAN window while
  /// staying typeable from the on-screen URL.
  final String token = _genToken();

  static String _genToken() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  ExportServer(this._items,
      {this.capturedAt, this.deviceName, this.onImportSources});

  /// Start the server and return the LAN URLs to display (one per IPv4).
  Future<List<String>> start() async {
    _server = await HttpServer.bind(
        InternetAddress.anyIPv4, port, shared: true);
    AppLog.info('ExportServer: listening on :$port items=${_items.length}');
    _server!.listen(_handle);
    _resetIdle();

    final urls = <String>[];
    for (final ni in await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false)) {
      for (final addr in ni.addresses) {
        urls.add('http://${addr.address}:$port/?t=$token');
      }
    }
    return urls;
  }

  // fix329: minimal HTML escape for the device name in the portal header.
  static String _esc(String s) => const HtmlEscape().convert(s);

  void _resetIdle() {
    _idleTimeout?.cancel();
    _idleTimeout = Timer(const Duration(minutes: 10), stop);
  }

  void _handle(HttpRequest req) async {
    _resetIdle();
    final path = req.uri.path;

    // fix347: every route requires the access token from the QR/dialog URL.
    if (req.uri.queryParameters['t'] != token) {
      AppLog.warn('ExportServer: rejected request without valid token'
          ' path=$path from=${req.connectionInfo?.remoteAddress.address}');
      req.response
        ..statusCode = 403
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><body style="font-family:sans-serif;'
            'padding:2em"><h2>403</h2><p>This portal requires the link from '
            'the QR code shown on the TV.</p></body>');
      await req.response.close();
      return;
    }

    if (path == '/') {
      final buf = StringBuffer()
        ..write('<!doctype html>'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<body style="font-family:sans-serif;padding:2em;max-width:32em;'
            'margin:auto"><h2>Free4Me-IPTV export</h2>');
      if (deviceName != null && deviceName!.isNotEmpty) {
        buf.write('<p style="font-size:1em;margin:-.6em 0 .2em;color:#444">'
            'From <strong>${_esc(deviceName!)}</strong></p>');
      }
      if (capturedAt != null) {
        buf.write('<p style="color:#888;font-size:.85em;margin:-.4em 0 1em">'
            'Snapshot taken $capturedAt</p>');
      }
      buf.write('<p>Tap a file to download:</p>');
      for (final it in _items) {
        final kb = (it.sizeBytes / 1024).toStringAsFixed(0);
        buf.write('<p><a href="/file/${it.key}?t=$token" '
            'style="display:block;font-size:1.2em;padding:.7em 1em;margin:.4em 0;'
            'background:#4E9FE5;color:#fff;text-decoration:none;'
            'border-radius:8px">'
            '${it.label} '
            '<small style="font-size:.75em">'
            '(${it.filename}, $kb KB)</small></a></p>');
      }
      if (onImportSources != null) {
        buf.write('<hr style="margin:1.5em 0;border:none;'
            'border-top:1px solid #ddd">'
            '<h3>Import sources</h3>'
            '<p style="color:#888;font-size:.85em">Upload a settings file to '
            'add its sources to this device. Only sources are imported; other '
            'settings are ignored. The device will ask to confirm the refresh.'
            '</p>'
            '<form method="POST" action="/import-sources?t=$token" '
            'enctype="multipart/form-data">'
            '<input type="file" name="file" accept=".json,application/json" '
            'required style="display:block;margin:.6em 0">'
            '<button type="submit" '
            'style="font-size:1.1em;padding:.6em 1.2em;background:#2ea44f;'
            'color:#fff;border:none;border-radius:8px">Import sources</button>'
            '</form>');
      }
      buf.write('<p style="color:#888;font-size:.85em">'
          'Server stops after 10 minutes idle.</p></body>');
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(buf.toString());
      await req.response.close();
      return;
    }

    if (path.startsWith('/file/')) {
      final key = path.substring('/file/'.length);
      final item = _items.where((i) => i.key == key).cast<ExportItem?>()
          .firstWhere((_) => true, orElse: () => null);
      if (item == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final file = File(item.filePath);
      if (!await file.exists()) {
        AppLog.warn('ExportServer: backing file missing ${item.filePath}');
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.parse(item.contentType)
        ..headers.add('Content-Disposition',
            'attachment; filename="${item.filename}"')
        ..headers.contentLength = item.sizeBytes;
      // Stream from disk — never loads the whole file into memory.
      await req.response.addStream(file.openRead());
      await req.response.close();
      AppLog.info('ExportServer: served ${item.filename} '
          '(${item.sizeBytes} bytes, streamed)');
      return;
    }

    // fix317: receive an uploaded settings file and import only its sources.
    if (path == '/import-sources' && req.method == 'POST') {
      if (onImportSources == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      try {
        final bytes = await _collectBytes(req);
        final fileBytes = _extractMultipartFile(bytes,
            req.headers.contentType?.parameters['boundary']);
        if (fileBytes == null || fileBytes.isEmpty) {
          throw 'no file part found';
        }
        final n = await onImportSources!(fileBytes);
        final ok = n >= 0;
        final msg = !ok
            ? 'Import failed — invalid or incompatible settings file.'
            : n == 0
                ? 'No sources found in the file.'
                : 'Imported $n source${n == 1 ? '' : 's'}. '
                    'Confirm the refresh on the device.';
        req.response
          ..statusCode = ok ? 200 : 400
          ..headers.contentType = ContentType.html
          ..write('<!doctype html>'
              '<meta name="viewport" content="width=device-width,initial-scale=1">'
              '<body style="font-family:sans-serif;padding:2em;max-width:32em;'
              'margin:auto"><h2>${ok ? 'Done' : 'Error'}</h2><p>$msg</p>'
              '<p><a href="/?t=$token">← Back</a></p></body>'); // fix363/LOW-2: keep token
        await req.response.close();
        AppLog.info('ExportServer: import-sources result n=$n');
      } catch (e) {
        AppLog.warn('ExportServer: import-sources failed — $e');
        req.response
          ..statusCode = 400
          ..headers.contentType = ContentType.html
          ..write('<!doctype html><body style="font-family:sans-serif;'
              'padding:2em"><h2>Error</h2><p>Import failed: $e</p>'
              '<p><a href="/?t=$token">← Back</a></p></body>'); // fix363/LOW-2: keep token
        await req.response.close();
      }
      return;
    }

    req.response.statusCode = 404;
    await req.response.close();
  }

  // fix317: read the full request body into a byte list.
  // fix347: capped — a settings export is tens of KB; an uncapped multipart
  // body let any LAN client OOM a 2GB box (same class as the fix328 export-
  // side fix). 5 MB is generous headroom.
  static const _maxImportBytes = 5 * 1024 * 1024;

  Future<List<int>> _collectBytes(HttpRequest req) async {
    final out = <int>[];
    await for (final chunk in req) {
      out.addAll(chunk);
      if (out.length > _maxImportBytes) {
        throw 'request body too large (max 5 MB)';
      }
    }
    return out;
  }

  // fix317: extract the first file part's raw bytes from a multipart/form-data
  // body. Minimal parser: splits on the boundary, finds the part with a
  // filename, and returns the bytes between its header blank-line and the next
  // boundary (trailing CRLF trimmed).
  List<int>? _extractMultipartFile(List<int> body, String? boundary) {
    if (boundary == null) return null;
    final delim = utf8.encode('--$boundary');
    final parts = _splitBytes(body, delim);
    for (final part in parts) {
      // A part starts with headers, then \r\n\r\n, then content.
      final headerEnd = _indexOf(part, utf8.encode('\r\n\r\n'));
      if (headerEnd < 0) continue;
      final header = utf8.decode(part.sublist(0, headerEnd),
          allowMalformed: true);
      if (!header.contains('filename=')) continue;
      var content = part.sublist(headerEnd + 4);
      // Trim the trailing CRLF that precedes the next boundary.
      while (content.isNotEmpty &&
          (content.last == 10 || content.last == 13)) {
        content = content.sublist(0, content.length - 1);
      }
      return content;
    }
    return null;
  }

  List<List<int>> _splitBytes(List<int> data, List<int> sep) {
    final result = <List<int>>[];
    var start = 0;
    while (true) {
      final idx = _indexOf(data, sep, start);
      if (idx < 0) {
        result.add(data.sublist(start));
        break;
      }
      result.add(data.sublist(start, idx));
      start = idx + sep.length;
    }
    return result;
  }

  int _indexOf(List<int> haystack, List<int> needle, [int from = 0]) {
    if (needle.isEmpty) return -1;
    for (var i = from; i <= haystack.length - needle.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  Future<void> stop() async {
    _idleTimeout?.cancel();
    _idleTimeout = null;
    await _server?.close(force: true);
    _server = null;
    AppLog.info('ExportServer: stopped');
  }
}
