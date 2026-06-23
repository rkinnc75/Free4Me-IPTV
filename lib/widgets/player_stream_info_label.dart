import 'dart:async';

import 'package:flutter/material.dart';

/// fix515: shows the stream's actual resolution + codec ("720p H.264") in
/// the player's top bar, once mpv reports a real decoded frame size.
/// Renders nothing until then (no "0x0" flash) and nothing if the engine
/// never produces a usable reading.
///
/// Self-contained StatefulWidget by design, following the same pattern as
/// PlayerEpgNowLabel: media_kit's MaterialVideoControlsTheme reads
/// topButtonBar/bottomButtonBar ONCE at mount and never re-reads the list on
/// parent rebuilds (the fix367/fix405 landmine noted in player.dart) — so a
/// plain Text built from State that changes after mount would never update.
/// Placing a StatefulWidget in that frozen list slot sidesteps the problem:
/// the SLOT is frozen, but the widget occupying it is free to rebuild its
/// own subtree via its own setState whenever its stream emits.
class PlayerStreamInfoLabel extends StatefulWidget {
  final Stream<String> streamInfoStream;

  const PlayerStreamInfoLabel({super.key, required this.streamInfoStream});

  @override
  State<PlayerStreamInfoLabel> createState() => _PlayerStreamInfoLabelState();
}

class _PlayerStreamInfoLabelState extends State<PlayerStreamInfoLabel> {
  String? _label;
  late final StreamSubscription<String> _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.streamInfoStream.listen((label) {
      if (mounted) setState(() => _label = label);
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = _label;
    if (label == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white70, fontSize: 14),
      ),
    );
  }
}
