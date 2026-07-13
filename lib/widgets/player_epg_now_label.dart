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

  /// fix731: pause the 30s DB poll while the OSD is hidden. The OSD is now
  /// always mounted (for the fade), so without this the label would run
  /// Sql.getNowNext every 30s for the whole session even when invisible —
  /// needless DB traffic on the DB-lock-sensitive onn.
  final bool active;

  const PlayerEpgNowLabel({
    super.key,
    required this.epgChannelId,
    required this.sourceId,
    this.active = true,
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
    if (widget.active) _start();
  }

  void _start() {
    if (widget.epgChannelId == null || _timer != null) return;
    _load(); // refresh immediately on (re)activation
    // Follow programme changes without hammering the DB.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didUpdateWidget(PlayerEpgNowLabel old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _start(); // OSD opened → resume + refresh
    } else if (!widget.active && old.active) {
      _stop(); // OSD hidden → pause polling (keep last _now for the fade-out)
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
