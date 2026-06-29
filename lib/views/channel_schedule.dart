import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_tv/backend/catchup_url.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/program.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/player.dart';

final _dateFmt = DateFormat.MMMEd(); // e.g. "Mon, May 19"
// fix604 (#5): program times use the shared guideClockFmt() (12/24-hour setting).
final _durationFmt = NumberFormat('0');

sealed class _ListItem {}

class _DayHeader extends _ListItem {
  final DateTime day;
  _DayHeader(this.day);
}

class _ProgItem extends _ListItem {
  final Program p;
  final bool isNow;
  _ProgItem(this.p, {required this.isNow});
}


/// Full program schedule for a single channel.
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
  final _nowKey = GlobalKey();
  // Flat-list index of the "now" tile — used to estimate the initial scroll
  // offset before the lazy ListView has built that item.
  int _nowFlatIndex = -1;

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
      final progs = results[0] as List<Program>;
      final sources = results[1] as List<Source>;
      final source = sources.firstWhere(
        (s) => s.id == widget.channel.sourceId,
        orElse: () => sources.first,
      );

      // Build flat list, recording the index of the "now" tile as we go.
      final items = <_ListItem>[];
      int nowFlatIndex = -1;
      DateTime? currentDay;
      for (final p in progs) {
        final local = p.startTime.toLocal();
        final day = DateTime(local.year, local.month, local.day);
        if (day != currentDay) {
          items.add(_DayHeader(day));
          currentDay = day;
        }
        final isNow = p.isOnNow(nowEpoch);
        if (isNow && nowFlatIndex < 0) nowFlatIndex = items.length;
        items.add(_ProgItem(p, isNow: isNow));
      }

      if (!mounted) return;
      setState(() {
        _items = items;
        _source = source;
        _nowFlatIndex = nowFlatIndex;
      });

      // Two-step scroll that works with ListView.builder's lazy rendering:
      //  1. jumpTo an estimated pixel offset — brings the "now" tile into the
      //     viewport so Flutter builds and attaches _nowKey.
      //  2. ensureVisible in the next frame for exact alignment.
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToNow());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  // Approximate heights used to estimate scroll offset before the lazy
  // list has built the target tile.
  static const double _headerH = 52.0;
  static const double _tileH = 80.0; // avg tile including optional subtitle

  void _scrollToNow() {
    if (_nowFlatIndex < 0) return;
    if (!_scrollController.hasClients) return;

    final items = _items;
    if (items == null) return;

    // Step 1 — estimate the pixel offset of the "now" tile by summing
    // approximate heights of all items above it.
    double approxOffset = 0;
    for (int i = 0; i < _nowFlatIndex && i < items.length; i++) {
      approxOffset += items[i] is _DayHeader ? _headerH : _tileH;
    }

    // Subtract 25 % of viewport so the tile lands about 1/4 from the top.
    final pos = _scrollController.position;
    final target = (approxOffset - pos.viewportDimension * 0.25)
        .clamp(0.0, pos.maxScrollExtent);

    _scrollController.jumpTo(target);

    // Step 2 — now that the "now" tile is in the viewport and built, use
    // ensureVisible in the next frame for pixel-perfect placement.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _nowKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.25,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
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
      return const Center(child: Text('No program data available.'));
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
            _programTile(p, nowEpoch, isNow: isNow),
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

  Widget _programTile(Program p, int nowEpoch, {required bool isNow}) {
    final isPast = p.stopUtc <= nowEpoch;
    final start = guideClockFmt().format(p.startTime.toLocal());
    final durationMins = _durationFmt.format(p.duration.inMinutes.toDouble());

    final source = _source;
    final showCatchup = source != null &&
        widget.channel.supportsCatchup &&
        (isPast || isNow);
    final catchupUrl = showCatchup
        ? CatchupUrl.build(
            channel: widget.channel,
            program: p,
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

    // Leading: time + "NOW" chip stacked vertically for the current program
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

  Future<void> _playCatchup(Program p, String url) async {
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

  void _showDetails(Program p) {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = _source;
    final canCatchup = source != null &&
        widget.channel.supportsCatchup &&
        (p.stopUtc <= nowEpoch || p.isOnNow(nowEpoch));
    final catchupUrl = canCatchup
        ? CatchupUrl.build(
            channel: widget.channel,
            program: p,
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
                '${guideClockFmt().format(p.startTime.toLocal())} – '
                '${guideClockFmt().format(p.stopTime.toLocal())}',
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
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
