import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_tv/backend/catchup_url.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/programme.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/player.dart';

final _dateFmt = DateFormat.MMMEd(); // e.g. "Mon, May 19"
final _timeFmt = DateFormat.Hm(); // e.g. "20:30"
final _durationFmt = NumberFormat('0');

// ─── Flat list item types ────────────────────────────────────────────────────
sealed class _ListItem {}

class _DayHeader extends _ListItem {
  final DateTime day;
  _DayHeader(this.day);
}

class _ProgItem extends _ListItem {
  final Programme p;
  final bool isNow;
  _ProgItem(this.p, {required this.isNow});
}

// ─── View ────────────────────────────────────────────────────────────────────

/// Full programme schedule for a single channel.
class ChannelScheduleView extends StatefulWidget {
  final Channel channel;

  const ChannelScheduleView({super.key, required this.channel});

  @override
  State<ChannelScheduleView> createState() => _ChannelScheduleViewState();
}

class _ChannelScheduleViewState extends State<ChannelScheduleView> {
  List<_ListItem>? _items;
  Source? _source;
  String? _error;

  final _scrollController = ScrollController();
  // Key placed on the "now" tile so we can scroll to it reliably regardless
  // of variable tile heights (descriptions, catchup buttons, etc.).
  final _nowKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final epgId = widget.channel.epgChannelId;
    if (epgId == null) {
      setState(() => _error = 'No EPG data for this channel.');
      return;
    }
    try {
      final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final windowStart = nowEpoch - 86400; // 1 day back
      final windowEnd = nowEpoch + 7 * 86400;

      final results = await Future.wait([
        Sql.getSchedule(epgId, widget.channel.sourceId, windowStart, windowEnd),
        Sql.getSources(),
      ]);
      final progs = results[0] as List<Programme>;
      final sources = results[1] as List<Source>;
      final source = sources.firstWhere(
        (s) => s.id == widget.channel.sourceId,
        orElse: () => sources.first,
      );

      // Build flat list grouping programmes by local date
      final items = <_ListItem>[];
      DateTime? currentDay;
      for (final p in progs) {
        final local = p.startTime.toLocal();
        final day = DateTime(local.year, local.month, local.day);
        if (day != currentDay) {
          items.add(_DayHeader(day));
          currentDay = day;
        }
        items.add(_ProgItem(p, isNow: p.isOnNow(nowEpoch)));
      }

      setState(() {
        _items = items;
        _source = source;
      });

      // After the first frame renders, scroll so the "now" tile is visible
      // and roughly 1/3 from the top — enough context above and below.
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToNow());
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _scrollToNow() {
    final ctx = _nowKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      // alignment 0.25 puts the item ~25 % from the top of the viewport,
      // which feels right for a TV remote — you see one past item and
      // several upcoming ones without having to scroll immediately.
      alignment: 0.25,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
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
    final items = _items;
    if (items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return const Center(child: Text('No programme data available.'));
    }

    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    return ListView.builder(
      controller: _scrollController,
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return switch (item) {
          _DayHeader(:final day) => _buildDayHeader(day),
          _ProgItem(:final p, :final isNow) =>
            _programmeTile(p, nowEpoch, isNow: isNow),
        };
      },
    );
  }

  Widget _buildDayHeader(DateTime day) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        _dateFmt.format(day),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _programmeTile(Programme p, int nowEpoch, {required bool isNow}) {
    final isPast = p.stopUtc <= nowEpoch;
    final start = _timeFmt.format(p.startTime.toLocal());
    final durationMins = _durationFmt.format(p.duration.inMinutes.toDouble());

    final source = _source;
    final showCatchup = source != null &&
        widget.channel.supportsCatchup &&
        (isPast || isNow);
    final catchupUrl = showCatchup
        ? CatchupUrl.build(
            channel: widget.channel,
            programme: p,
            source: source,
          )
        : null;

    Widget? trailing;
    if (catchupUrl != null) {
      trailing = IconButton(
        icon: const Icon(Icons.replay_outlined),
        tooltip: 'Watch from beginning',
        color: Theme.of(context).colorScheme.primary,
        onPressed: () => _playCatchup(p, catchupUrl),
      );
    } else {
      trailing = Text(
        '$durationMins min',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isNow
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
      );
    }

    // Leading: time + "NOW" chip stacked vertically for the current programme
    Widget leading = SizedBox(
      width: 56,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            start,
            style: TextStyle(
              fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
              color: isNow ? Theme.of(context).colorScheme.primary : null,
              fontSize: 13,
            ),
          ),
          if (isNow)
            Container(
              margin: const EdgeInsets.only(top: 3),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'NOW',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
        ],
      ),
    );

    final tile = ListTile(
      key: isNow ? _nowKey : null,
      leading: leading,
      title: Text(
        p.title,
        style: TextStyle(
          fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
          fontSize: isNow ? 15 : null,
        ),
      ),
      subtitle: p.description != null
          ? Text(p.description!, maxLines: 2, overflow: TextOverflow.ellipsis)
          : null,
      trailing: trailing,
      // No tileColor here — we wrap with a DecoratedBox for the left border
      onTap: () => _showDetails(p),
    );

    if (!isNow) return tile;

    // "Now" row: primary-coloured left border + gentle background tint
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 4,
          ),
        ),
      ),
      child: tile,
    );
  }

  Future<void> _playCatchup(Programme p, String url) async {
    final settings =
        SettingsService.cached ?? await SettingsService.getSettings();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Player(
          channel: widget.channel,
          settings: settings,
          overrideUrl: url,
        ),
      ),
    );
  }

  void _showDetails(Programme p) {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = _source;
    final canCatchup = source != null &&
        widget.channel.supportsCatchup &&
        (p.stopUtc <= nowEpoch || p.isOnNow(nowEpoch));
    final catchupUrl = canCatchup
        ? CatchupUrl.build(
            channel: widget.channel,
            programme: p,
            source: source,
          )
        : null;

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
          if (catchupUrl != null)
            FilledButton.icon(
              icon: const Icon(Icons.replay_outlined),
              label: const Text('Watch from beginning'),
              onPressed: () {
                Navigator.pop(context);
                _playCatchup(p, catchupUrl);
              },
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
