import 'dart:async';
import 'dart:io';
import 'package:open_tv/backend/app_logger.dart';

/// A single named payload to serve.
class ExportItem {
  final String key;          // url-safe id, e.g. 'backup' / 'log'
  final String filename;     // download name
  final String label;        // human label for the index page
  final List<int> bytes;
  final String contentType;

  const ExportItem({
    required this.key,
    required this.filename,
    required this.label,
    required this.bytes,
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
  Timer? _idleTimeout;

  ExportServer(this._items);

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
        urls.add('http://${addr.address}:$port/');
      }
    }
    return urls;
  }

  void _resetIdle() {
    _idleTimeout?.cancel();
    _idleTimeout = Timer(const Duration(minutes: 10), stop);
  }

  void _handle(HttpRequest req) async {
    _resetIdle();
    final path = req.uri.path;

    if (path == '/') {
      final buf = StringBuffer()
        ..write('<!doctype html>'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<body style="font-family:sans-serif;padding:2em;max-width:32em;'
            'margin:auto"><h2>Free4Me-IPTV export</h2>'
            '<p>Tap a file to download:</p>');
      for (final it in _items) {
        final kb = (it.bytes.length / 1024).toStringAsFixed(0);
        buf.write('<p><a href="/file/${it.key}" '
            'style="display:block;font-size:1.2em;padding:.7em 1em;margin:.4em 0;'
            'background:#4E9FE5;color:#fff;text-decoration:none;'
            'border-radius:8px">'
            '${it.label} '
            '<small style="font-size:.75em">'
            '(${it.filename}, $kb KB)</small></a></p>');
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
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.parse(item.contentType)
        ..headers.add('Content-Disposition',
            'attachment; filename="${item.filename}"')
        ..add(item.bytes);
      await req.response.close();
      AppLog.info('ExportServer: served ${item.filename} '
          '(${item.bytes.length} bytes)');
      return;
    }

    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<void> stop() async {
    _idleTimeout?.cancel();
    _idleTimeout = null;
    await _server?.close(force: true);
    _server = null;
    AppLog.info('ExportServer: stopped');
  }
}
