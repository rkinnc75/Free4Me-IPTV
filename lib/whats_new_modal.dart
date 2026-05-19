import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:url_launcher/url_launcher.dart';

class WhatsNewModal extends StatelessWidget {
  final String version;
  const WhatsNewModal({super.key, required this.version});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text("What's new: update $version"),
      actions: [
        TextButton(
          onPressed: () async {
            await launchUrl(
              Uri.parse(
                "https://github.com/Fredolx/fred-tv-mobile/discussions/1",
              ),
              mode: LaunchMode.externalApplication,
            );
            Navigator.pop(context, false);
          },
          child: const Text("Donate"),
        ),
        TextButton(
          onPressed: () async {
            await SettingsService.updateLastSeenVersion();
            Navigator.pop(context, true);
          },
          child: const Text("Don't show again"),
        ),
      ],
      content: Scrollbar(
        thumbVisibility: true,
        child: SingleChildScrollView(
          child: const Padding(
            padding: EdgeInsets.only(right: 8.0),
            child: const Text('''
Welcome to Free4Me-IPTV — a fork of Fred TV (Fredolx/fred-tv-mobile) with playback reliability improvements for Android TV.

What's different in this fork:

- Configurable buffer (cache seconds, demuxer size) for live and VOD
- Player startup timeout and proper reconnect on error/stall
- Hardware decode (mediacodec) enabled by default
- Watchdog reconnect after sustained buffering
- Network connectivity awareness
- HTTP timeouts and retry on source refresh
- Fixed groups/categories SQL bug
- FTS5-backed channel search
- Pre-warm channel URL on focus

All credit for the original app goes to Fredolx. Please support the upstream project.
'''),
          ),
        ),
      ),
    );
  }
}
