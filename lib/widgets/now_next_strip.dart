import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/program.dart';

// fix604 (#5): use the shared guideClockFmt() (honors the 12/24-hour setting).

/// Displays "Now: <title>  •  Next: <title>" for a channel that has EPG data.
/// Returns [SizedBox.shrink()] when no EPG data is available.
class NowNextStrip extends StatefulWidget {
  final String epgChannelId;
  final int sourceId;
  final VoidCallback? onTap;

  const NowNextStrip({
    super.key,
    required this.epgChannelId,
    required this.sourceId,
    this.onTap,
  });

  @override
  State<NowNextStrip> createState() => _NowNextStripState();
}

class _NowNextStripState extends State<NowNextStrip> {
  (Program?, Program?)? _data;
  Timer? _rollover;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant NowNextStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Review finding 156: element reuse on channel swap (e.g. a multi-view
    // cell) kept the previous channel's Now/Next until a full remount. Reload
    // when the identity changes.
    if (oldWidget.epgChannelId != widget.epgChannelId ||
        oldWidget.sourceId != widget.sourceId) {
      _rollover?.cancel();
      _data = null; // clear stale channel data while the new load is in flight
      _load();
    }
  }

  @override
  void dispose() {
    _rollover?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    (Program?, Program?)? data;
    try {
      data = await Sql.getNowNext(widget.epgChannelId, widget.sourceId);
    } catch (_) {
      // Review finding 156: fail soft — keep whatever is on screen and retry
      // on the next didUpdateWidget / scheduled rollover rather than crashing
      // the cell.
      return;
    }
    if (!mounted) return;
    setState(() => _data = data);
    _scheduleRollover(data);
  }

  void _scheduleRollover((Program?, Program?)? data) {
    _rollover?.cancel();
    final now = data?.$1;
    if (now == null) return;
    // Re-query shortly after the current programme's stop so "Now" advances.
    var delay = now.stopTime.difference(DateTime.now()) +
        const Duration(seconds: 2);
    if (delay < const Duration(seconds: 1)) delay = const Duration(seconds: 30);
    // Cap far-future stops (or clock skew) so a bad EPG stop_utc can't overflow
    // the Timer or leave it never firing.
    const maxDelay = Duration(hours: 3);
    if (delay > maxDelay) delay = maxDelay;
    _rollover = Timer(delay, () {
      if (mounted) _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) return const SizedBox.shrink(); // loading

    final (now, next) = data;
    if (now == null && next == null) return const SizedBox.shrink();

    final style = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        );

    final parts = <String>[];
    if (now != null) {
      parts.add('▶ ${now.title}');
    }
    if (next != null) {
      final startStr = guideClockFmt().format(next.startTime.toLocal());
      parts.add('Next $startStr: ${next.title}');
    }

    final text = Text(
      parts.join('  •  '),
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    final body = Padding(
      padding: const EdgeInsets.only(top: 2),
      child: text,
    );

    if (widget.onTap == null) return body;
    // Consume the tap (HitTestBehavior.opaque) so the parent tile's "tap to
    // play" gesture doesn't also fire.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: body,
    );
  }
}
