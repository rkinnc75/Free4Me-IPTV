import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:loader_overlay/loader_overlay.dart';
import 'package:open_tv/models/result.dart';
import 'package:url_launcher/url_launcher.dart';

class Error {
  static Future<void> handleError(BuildContext context, String error) async {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            backgroundColor: Colors.red[700],
            content: const Text(
              "An error occured. Click on 'Details' for more information",
              style: TextStyle(color: Colors.white),
            ),
            action: SnackBarAction(
                label: 'Details',
                textColor: Colors.white,
                onPressed: () async => {
                      await showDialog(
                          barrierDismissible: true,
                          context: context,
                          builder: (builder) => AlertDialog(
                                title: const Text('Error'),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                        "The following error occured. If this error persists, please report it.\n"),
                                    Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(
                                            8.0), // Padding inside the box
                                        decoration: BoxDecoration(
                                            color: Colors.black,
                                            borderRadius:
                                                BorderRadius.circular(8.0)),
                                        child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                maxHeight: 200),
                                            child: SingleChildScrollView(
                                                child: Text(
                                              error,
                                              style: const TextStyle(
                                                  color: Colors.white),
                                            ))))
                                  ],
                                ),
                                actions: <Widget>[
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      textStyle: Theme.of(context)
                                          .textTheme
                                          .labelLarge,
                                    ),
                                    child: const Text('Report issue'),
                                    onPressed: () async {
                                      final Uri url = Uri.parse(
                                          'https://github.com/rkinnc75/Free4Me-IPTV/issues/new?template=Blank+issue');
                                      await launchUrl(url,
                                          mode: LaunchMode.externalApplication);
                                    },
                                  ),
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      textStyle: Theme.of(context)
                                          .textTheme
                                          .labelLarge,
                                    ),
                                    child: const Text('Copy'),
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(
                                          text: error.toString()));
                                    },
                                  ),
                                  TextButton(
                                    autofocus: true,
                                    style: TextButton.styleFrom(
                                      textStyle: Theme.of(context)
                                          .textTheme
                                          .labelLarge,
                                    ),
                                    child: const Text('Close'),
                                    onPressed: () {
                                      Navigator.of(context).pop();
                                    },
                                  ),
                                ],
                              ))
                    })),
      );
    }
  }

  /// Returns a user-friendly one-line description of [error].
  /// Falls back to the raw exception string so callers never get an empty message.
  static String friendlyMessage(dynamic error) {
    final msg = error.toString().toLowerCase();

    if (msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('network is unreachable') ||
        msg.contains('connection refused')) {
      return 'Cannot reach server — check your internet connection';
    }
    if (msg.contains('timeoutexception') ||
        msg.contains('timed out') ||
        msg.contains('connection timed out')) {
      return 'Connection timed out — the server is not responding';
    }
    if (msg.contains('401') || msg.contains('403') ||
        msg.contains('unauthorized') || msg.contains('forbidden')) {
      return 'Authentication failed — check your username and password';
    }
    if (msg.contains('404') || msg.contains('not found')) {
      return 'Stream or playlist not found — your provider may have changed the URL';
    }
    if (msg.contains('50') && msg.contains('http')) {
      return "Provider's server is down — try again in a few minutes";
    }
    if (msg.contains('formatexception') ||
        msg.contains('m3u') ||
        msg.contains('malformed')) {
      return 'Playlist file is malformed — verify the URL is correct';
    }
    if (msg.contains('buffering watchdog')) {
      return 'Stream is not responding — reconnecting…';
    }
    if (msg.contains('mpv') || msg.contains('codec') ||
        msg.contains('player.open')) {
      return 'Stream codec or format not supported by this player';
    }
    if (msg.contains('ssl') || msg.contains('certificate') ||
        msg.contains('handshake')) {
      return 'SSL/TLS error — try enabling "Ignore SSL" for this source';
    }

    // Fall back to raw message so information is never lost.
    return error.toString();
  }

  static void showSuccess(BuildContext context, String message) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  static Future<Result<T>> tryAsync<T>(
      Future<T?> Function() fn, BuildContext context,
      [String? successMessage = "Action completed successfully",
      bool useLoading = true,
      bool useSuccess = true]) async {
    var success = false;
    T? result;
    if (useLoading && context.mounted) {
      context.loaderOverlay.show();
    }
    try {
      result = await fn();
      // ignore: use_build_context_synchronously
      if (useSuccess && context.mounted) showSuccess(context, successMessage!);
      success = true;
    } catch (e, stackTrace) {
      final error = "${e.toString()}\n${stackTrace.toString()}";
      // ignore: use_build_context_synchronously
      if (context.mounted) await handleError(context, error);
    }
    // ignore: use_build_context_synchronously
    if (useLoading && context.mounted && context.loaderOverlay.visible) {
      context.loaderOverlay.hide();
    }
    return Result(success: success, data: result);
  }

  static Future<Result<T>> tryAsyncNoLoading<T>(
      Future<T?> Function() fn, BuildContext context,
      [bool useSuccess = false, String? successMessage]) async {
    return await tryAsync(fn, context, successMessage, false, useSuccess);
  }
}
