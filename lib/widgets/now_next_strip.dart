import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/programme.dart';

final _timeFmt = DateFormat.Hm(); // e.g. "20:30"

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
  (Programme?, Programme?)? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await Sql.getNowNext(widget.epgChannelId, widget.sourceId);
    if (mounted) setState(() => _data = data);
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
      final startStr = _timeFmt.format(next.startTime.toLocal());
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
