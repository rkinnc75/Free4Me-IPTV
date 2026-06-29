import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/program.dart';

// fix604 (#5): use the shared guideClockFmt() (honors the 12/24-hour setting).

/// fix406: shows the channel's CURRENT EPG programme in the player's top bar,
/// to the right of the channel name (the remaining space). Renders nothing when
/// the channel has no EPG mapping or no programme is on now, so it can sit in an
/// `Expanded` and double as the spacer that pushes the cast/PiP icons right.
///
/// Refreshes periodically so the label follows programme changes during a long
/// session.
class PlayerEpgNowLabel extends StatefulWidget {
  final String? epgChannelId;
  final int sourceId;

  const PlayerEpgNowLabel({
    super.key,
    required this.epgChannelId,
    required this.sourceId,
  });

  @override
  State<PlayerEpgNowLabel> createState() => _PlayerEpgNowLabelState();
}

class _PlayerEpgNowLabelState extends State<PlayerEpgNowLabel> {
  Program? _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.epgChannelId != null) {
      _load();
      // Follow programme changes without hammering the DB.
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    }
  }

  Future<void> _load() async {
    final id = widget.epgChannelId;
    if (id == null) return;
    final (now, _) = await Sql.getNowNext(id, widget.sourceId);
    if (mounted) setState(() => _now = now);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    if (now == null) return const SizedBox.shrink();
    final start = guideClockFmt().format(now.startTime.toLocal());
    final stop = guideClockFmt().format(now.stopTime.toLocal());
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        '$start–$stop   ${now.title}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white70, fontSize: 14),
      ),
    );
  }
}
