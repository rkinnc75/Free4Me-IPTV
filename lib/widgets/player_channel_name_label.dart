import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/player/player_engine.dart';

/// fix575: the player top bar's channel name with the stream's actual
/// resolution + codec appended once known — e.g. "ESPN HD" → "ESPN HD
/// (720p H.264)".
///
/// Replaces the separate `PlayerStreamInfoLabel` (fix515/522), which never
/// reliably appeared: it sat AFTER an `Expanded` EPG label that consumed the
/// row (squeezing it to ~zero width) and relied on a one-shot broadcast that
/// raced the topButtonBar mount. This widget instead occupies the
/// always-rendered NAME slot (before the Expanded) and POLLS the engine's
/// latched [PlayerEngine.lastStreamInfo] — exactly the self-updating approach
/// `PlayerEpgNowLabel` uses for the EPG. media_kit freezes the topButtonBar
/// list at its mount, but a StatefulWidget in that slot is free to rebuild its
/// own subtree, so polling sidesteps the frozen-slot problem entirely.
class PlayerChannelNameLabel extends StatefulWidget {
  final String channelName;
  final PlayerEngine engine;

  const PlayerChannelNameLabel({
    super.key,
    required this.channelName,
    required this.engine,
  });

  @override
  State<PlayerChannelNameLabel> createState() => _PlayerChannelNameLabelState();
}

class _PlayerChannelNameLabelState extends State<PlayerChannelNameLabel> {
  String? _info;
  Timer? _timer;
  StreamSubscription<String>? _sub;
  int _polls = 0;

  // First-frame sizing normally lands within a couple of seconds. Bound the
  // poll so audio-only / radio streams (where mpv never reports a frame size,
  // so lastStreamInfo stays null forever) don't leave the timer running for
  // the whole player-view lifetime. The subscription still covers a late emit.
  static const _maxPolls = 10;

  @override
  void initState() {
    super.initState();
    _info = widget.engine.lastStreamInfo; // already latched? seed it
    // Cover a later emission (immediacy)…
    _sub = widget.engine.streamInfoStream.listen((label) {
      if (mounted) setState(() => _info = label);
    });
    // …and poll the latch, since the first-frame sample can land before this
    // mounts (broadcast event dropped with no listener) or after. Self-cancels
    // once a value is in hand, or after [_maxPolls] if none ever arrives.
    if (_info == null || _info!.isEmpty) {
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        final latest = widget.engine.lastStreamInfo;
        if (latest != null && latest.isNotEmpty) {
          t.cancel();
          if (latest != _info && mounted) setState(() => _info = latest);
        } else if (++_polls >= _maxPolls) {
          t.cancel(); // no frame size will arrive (audio-only / radio)
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final text = (info == null || info.isEmpty)
        ? widget.channelName
        : '${widget.channelName}  ($info)';
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
