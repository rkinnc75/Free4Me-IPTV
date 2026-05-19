import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/programme.dart';

final _dateFmt = DateFormat.MMMEd();   // e.g. "Mon, May 19"
final _timeFmt = DateFormat.Hm();      // e.g. "20:30"
final _durationFmt = NumberFormat('0');

/// Full programme schedule for a single channel.
class ChannelScheduleView extends StatefulWidget {
  final Channel channel;

  const ChannelScheduleView({super.key, required this.channel});

  @override
  State<ChannelScheduleView> createState() => _ChannelScheduleViewState();
}

class _ChannelScheduleViewState extends State<ChannelScheduleView> {
  List<Programme>? _programmes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final epgId = widget.channel.epgChannelId;
    if (epgId == null) {
      setState(() => _error = 'No EPG data for this channel.');
      return;
    }
    try {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final start = now - 86400; // 1 day back
      final end = now + 7 * 86400; // 7 days forward
      final progs = await Sql.getSchedule(
        epgId,
        widget.channel.sourceId,
        start,
        end,
      );
      setState(() => _programmes = progs);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.channel.name)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Text(_error!, textAlign: TextAlign.center));
    }
    final programmes = _programmes;
    if (programmes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (programmes.isEmpty) {
      return const Center(child: Text('No programme data available.'));
    }

    // Group by local date
    final byDay = <DateTime, List<Programme>>{};
    for (final p in programmes) {
      final local = p.startTime.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      byDay.putIfAbsent(day, () => []).add(p);
    }
    final days = byDay.keys.toList()..sort();

    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    return ListView.builder(
      itemCount: days.length,
      itemBuilder: (context, dayIdx) {
        final day = days[dayIdx];
        final dayProgs = byDay[day]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                _dateFmt.format(day),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            ...dayProgs.map((p) => _programmeTile(p, nowEpoch)),
          ],
        );
      },
    );
  }

  Widget _programmeTile(Programme p, int nowEpoch) {
    final isNow = p.isOnNow(nowEpoch);
    final start = _timeFmt.format(p.startTime.toLocal());
    final durationMins =
        _durationFmt.format(p.duration.inMinutes.toDouble());

    return ListTile(
      leading: SizedBox(
        width: 48,
        child: Text(
          start,
          style: TextStyle(
            fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
            color: isNow
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
        ),
      ),
      title: Text(
        p.title,
        style: TextStyle(
          fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: p.description != null
          ? Text(p.description!, maxLines: 2, overflow: TextOverflow.ellipsis)
          : null,
      trailing: Text(
        '$durationMins min',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      tileColor: isNow
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
          : null,
      onTap: () => _showDetails(p),
    );
  }

  void _showDetails(Programme p) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(p.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_timeFmt.format(p.startTime.toLocal())} – '
                '${_timeFmt.format(p.stopTime.toLocal())}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (p.category != null) ...[
                const SizedBox(height: 4),
                Text(p.category!,
                    style: Theme.of(context).textTheme.labelSmall),
              ],
              if (p.description != null) ...[
                const SizedBox(height: 12),
                Text(p.description!),
              ],
              if (p.episodeNum != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Episode: ${p.episodeNum}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
