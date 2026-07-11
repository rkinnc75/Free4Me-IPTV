import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/recording_capture.dart';
import 'package:open_tv/backend/recording_scheduler.dart';
import 'package:open_tv/backend/recording_status_journal.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/recording.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/player.dart';

/// fix669: Scheduled Recording list — a top-level destination alongside
/// Live/Movies/Series. Shows recordings grouped by state with per-item actions:
/// scheduled → cancel; recording → stop; done → play (opens the captured file);
/// failed → shows the error; any → delete (removes the row).
///
/// This is distinct from the app's live "DVR" (rewind-within-live-stream).
class RecordingsView extends StatefulWidget {
  const RecordingsView({super.key});

  @override
  State<RecordingsView> createState() => _RecordingsViewState();
}

class _RecordingsViewState extends State<RecordingsView> {
  List<Recording> _recordings = [];
  bool _loading = true;
  bool _firstLoad = true; // fix697: suppress completion snacks on the opening drain
  // fix697: ids the user just stopped via the Stop button — their capture still
  // finalizes to 'done' (row kept), so skip the "Recording complete" snack for
  // them (mirrors the native postCompletion user-stop suppression).
  final Set<int> _userEndedIds = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // fix681: apply any status events the native capture service wrote to its
    // journal (single-writer: only Dart touches the DB) before reading rows.
    // fix697: drain reports the terminal (done/failed) transitions it applied.
    final completions = await RecordingStatusJournal.drain();
    final recs = await Sql.getRecordings();
    if (!mounted) return;
    final wasFirst = _firstLoad;
    _firstLoad = false;
    setState(() {
      _recordings = recs;
      _loading = false;
    });
    // fix697: item 2 — in-app twin of the native completion notification. Only
    // for transitions observed while the screen is already open (not the opening
    // drain of a stale journal, which the native notification already covered).
    if (!wasFirst && completions.isNotEmpty) _showCompletionSnacks(completions);
  }

  // fix697: SnackBar for recordings that finished/failed while this screen was
  // open. Only for rows STILL present — a recording the user just stopped/deleted
  // is dropped from the list, so we don't surface a spurious "complete" toast for
  // it (the native completion notification is likewise suppressed on user stop).
  void _showCompletionSnacks(List<RecordingCompletion> events) {
    Recording? rowOf(int id) {
      for (final r in _recordings) {
        if (r.id == id) return r;
      }
      return null;
    }

    final live = <(RecordingCompletion, String)>[];
    for (final e in events) {
      if (_userEndedIds.remove(e.id)) continue; // fix697: user stopped it → silent
      final row = rowOf(e.id);
      if (row == null) continue; // user-deleted → don't announce
      live.add((e, row.channelName));
    }
    if (live.isEmpty) return;

    final failed =
        live.where((p) => p.$1.status == RecordingStatus.failed).length;
    final String msg;
    if (live.length == 1) {
      final (e, name) = live.first;
      msg = e.status == RecordingStatus.failed
          ? 'Recording failed: $name'
          : 'Recording complete: $name';
    } else {
      msg = failed > 0
          ? '${live.length} recordings finished ($failed failed)'
          : '${live.length} recordings complete';
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _play(Recording r) async {
    final path = r.outputPath;
    if (path == null || path.isEmpty) return;
    final settings =
        SettingsService.cached ?? await SettingsService.getSettings();
    if (!mounted) return;
    // Synthetic channel so the Player has a title; overrideUrl carries the file.
    final ch = Channel(
      id: null,
      name: r.channelName,
      image: null,
      url: path,
      mediaType: MediaType.movie,
      sourceId: 0,
      favorite: false,
    );
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Player(
          channel: ch,
          settings: settings,
          overrideUrl: path,
        ),
      ),
    );
  }

  Future<void> _stop(Recording r) async {
    if (r.id == null) return;
    _userEndedIds.add(r.id!); // fix697: don't announce a user-stopped recording
    await RecordingCapture.stop(r.id!);
    await _load();
  }

  Future<void> _cancel(Recording r) async {
    if (r.id == null) return;
    await RecordingScheduler.cancel(r.id!);
    await _load();
  }

  /// fix693: shared channel with the native recording service — reused here to
  /// delete the saved MediaStore file (remuxDeleteTs) and to read file metadata
  /// (recordingFileInfo).
  static const MethodChannel _recCh = MethodChannel('me.free4me.iptv/recording');

  Future<void> _delete(Recording r) async {
    if (r.id == null) return;
    final hasFile = (r.outputPath ?? '').isNotEmpty;
    // fix693: three choices when a saved file exists — remove the file too, or
    // keep it on disk and only drop the list entry. No file → plain confirm.
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(hasFile
            ? 'Delete "${r.channelName}" from the list. Do you also want to '
                'remove the saved video file?'
            : 'Remove "${r.channelName}" from the list?'),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Cancel'),
          ),
          if (hasFile)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep'),
              child: const Text('Delete, keep file'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, hasFile ? 'remove' : 'keep'),
            child: Text(hasFile ? 'Delete + remove file' : 'Delete'),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return;

    if (r.status == RecordingStatus.recording) {
      // fix697: stop the live capture; if the user chose "remove file" the native
      // service deletes the partial itself once its output stream closes (no
      // cross-isolate open-fd race), so we must NOT also delete it here. Since
      // fix697 the row carries its content:// URI while recording, so hasFile is
      // true and the remove option is offered for a running recording too.
      // Passing the URI lets the native side delete it directly if this row is a
      // STALE "recording" (capture already finished, journal not yet drained) or
      // the capture process was killed — cases where no live thread would honor
      // the delete flag and the finalized file would otherwise be orphaned.
      await RecordingCapture.stop(r.id!,
          deleteFile: choice == 'remove', uri: r.outputPath);
    } else if (choice == 'remove' && hasFile) {
      // fix693: remove the finalized MediaStore file (content:// URI) for a
      // not-recording row.
      try {
        await _recCh.invokeMethod('remuxDeleteTs', {'uri': r.outputPath});
      } catch (e) {
        AppLog.warn('RecordingsView: file delete failed — $e');
      }
    }
    // fix679: cancel the alarm before removing the row, otherwise its
    // rescheduleOnReboot registration is orphaned and re-fires on every boot
    // (hitting a now-missing row). Alarm-only cancel: no status write on a row
    // we're about to delete.
    await RecordingScheduler.cancelAlarm(r.id!);
    await Sql.deleteRecording(r.id!);
    await _load();
  }

  /// fix693: long-press / held-OK → file metadata (MediaMetadataRetriever) +
  /// local path in a bottom sheet.
  Future<void> _showDetails(Recording r) async {
    Map<String, dynamic>? info;
    final path = r.outputPath;
    if (path != null && path.isNotEmpty) {
      try {
        final raw = await _recCh
            .invokeMapMethod<String, dynamic>('recordingFileInfo', {'uri': path});
        info = raw;
      } catch (e) {
        AppLog.warn('RecordingsView: file info failed — $e');
      }
    }
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _DetailsSheet(recording: r, info: info),
    );
  }

  (IconData, Color, String) _statusChip(RecordingStatus s) {
    switch (s) {
      case RecordingStatus.scheduled:
        return (Icons.schedule, Colors.blueGrey, 'Scheduled');
      case RecordingStatus.recording:
        return (Icons.fiber_manual_record, Colors.redAccent, 'Recording');
      case RecordingStatus.compressing:
        return (Icons.compress, Colors.orange, 'Processing');
      case RecordingStatus.done:
        return (Icons.check_circle, Colors.green, 'Done');
      case RecordingStatus.failed:
        return (Icons.error_outline, Colors.red, 'Failed');
      case RecordingStatus.cancelled:
        return (Icons.cancel, Colors.grey, 'Cancelled');
    }
  }

  String _subtitle(Recording r) {
    final start = DateFormat('EEE d MMM, h:mm a').format(r.startTime.toLocal());
    final mins = (r.durationMs / 60000).round();
    final base = '$start · ${mins}m';
    if (r.status == RecordingStatus.failed && r.error != null) {
      return '$base · ${r.error}';
    }
    return base;
  }

  Widget _trailing(Recording r) {
    final buttons = <Widget>[];
    switch (r.status) {
      case RecordingStatus.done:
        if (r.outputPath != null) {
          buttons.add(IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Play',
            onPressed: () => _play(r),
          ));
        }
        break;
      case RecordingStatus.recording:
        buttons.add(IconButton(
          icon: const Icon(Icons.stop, color: Colors.redAccent),
          tooltip: 'Stop',
          onPressed: () => _stop(r),
        ));
        break;
      case RecordingStatus.scheduled:
        buttons.add(IconButton(
          icon: const Icon(Icons.alarm_off),
          tooltip: 'Cancel',
          onPressed: () => _cancel(r),
        ));
        break;
      default:
        break;
    }
    buttons.add(IconButton(
      icon: const Icon(Icons.delete_outline),
      tooltip: 'Delete',
      onPressed: () => _delete(r),
    ));
    return Row(mainAxisSize: MainAxisSize.min, children: buttons);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _recordings.isEmpty
              ? _emptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _recordings.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = _recordings[i];
                      final (icon, color, label) = _statusChip(r.status);
                      final blinking = r.status == RecordingStatus.recording;
                      return _RecordingTile(
                        leading: _BlinkingDot(
                          icon: icon,
                          color: color,
                          blinking: blinking,
                        ),
                        title: r.channelName,
                        subtitle: '$label · ${_subtitle(r)}',
                        trailing: _trailing(r),
                        onTap: r.status == RecordingStatus.done
                            ? () => _play(r)
                            : null,
                        onDetails: () => _showDetails(r),
                      );
                    },
                  ),
                ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_smart_record,
              size: 64, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          const Text('No recordings yet'),
          const SizedBox(height: 4),
          Text(
            'Record a show from the TV guide, or use "Record now" on a channel.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// fix693: the recording-status leading icon, pulsing while actively recording.
class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot({
    required this.icon,
    required this.color,
    required this.blinking,
  });

  final IconData icon;
  final Color color;
  final bool blinking;

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    if (widget.blinking) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _BlinkingDot old) {
    super.didUpdateWidget(old);
    if (widget.blinking && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.blinking && _c.isAnimating) {
      _c.stop();
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(widget.icon, color: widget.color);
    if (!widget.blinking) return icon;
    // Fade between full and dim (never fully invisible, so focus/layout is
    // stable) to read as a pulsing "REC" indicator.
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.25).animate(_c),
      child: icon,
    );
  }
}

/// fix693: a focusable recordings row. Short OK/tap = [onTap]; long-press
/// (touch) or held-OK (D-pad, fix586/fix607 pattern) = [onDetails].
class _RecordingTile extends StatefulWidget {
  const _RecordingTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
    required this.onDetails,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;
  final VoidCallback onDetails;

  @override
  State<_RecordingTile> createState() => _RecordingTileState();
}

class _RecordingTileState extends State<_RecordingTile> {
  final FocusNode _node = FocusNode(debugLabel: 'recording-tile');
  Timer? _holdTimer;
  bool _selectDown = false;
  bool _heldLong = false;
  static const Duration _holdDelay = Duration(milliseconds: 600);

  @override
  void initState() {
    super.initState();
    // fix693: held-OK on the D-pad opens details (mirrors tv_top_tab_bar's
    // fix607 model — timer marks the hold, KeyUp decides held vs quick).
    _node.onKeyEvent = (n, event) {
      final k = event.logicalKey;
      final isSelect = k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.numpadEnter ||
          k == LogicalKeyboardKey.gameButtonA;
      if (!isSelect) return KeyEventResult.ignored;
      if (event is KeyDownEvent) {
        _selectDown = true;
        _heldLong = false;
        _holdTimer?.cancel();
        _holdTimer = Timer(_holdDelay, () {
          if (mounted && n.hasFocus) _heldLong = true;
        });
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _holdTimer?.cancel();
        _holdTimer = null;
        if (!_selectDown) return KeyEventResult.handled;
        _selectDown = false;
        final long = _heldLong;
        _heldLong = false;
        if (long) {
          widget.onDetails();
        } else {
          widget.onTap?.call();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled; // swallow repeats; timer marks the hold
    };
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      focusNode: _node,
      leading: widget.leading,
      title: Text(widget.title,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(widget.subtitle,
          maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: widget.trailing,
      onTap: widget.onTap,
      onLongPress: widget.onDetails, // touchscreens
    );
  }
}

/// fix693: recording detail sheet — file metadata (MediaMetadataRetriever) +
/// local path.
class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({required this.recording, required this.info});

  final Recording recording;
  final Map<String, dynamic>? info;

  String _fmtDuration(int? ms) {
    if (ms == null || ms <= 0) return '—';
    final s = ms ~/ 1000;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0
        ? '${h}h ${m}m ${sec}s'
        : (m > 0 ? '${m}m ${sec}s' : '${sec}s');
  }

  String _fmtSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    var b = bytes.toDouble();
    var u = 0;
    while (b >= 1024 && u < units.length - 1) {
      b /= 1024;
      u++;
    }
    return '${b.toStringAsFixed(b >= 10 || u == 0 ? 0 : 1)} ${units[u]}';
  }

  @override
  Widget build(BuildContext context) {
    final i = info ?? const {};
    final w = (i['width'] as num?)?.toInt();
    final h = (i['height'] as num?)?.toInt();
    final rows = <(String, String)>[
      ('Channel', recording.channelName),
      if (w != null && h != null) ('Resolution', '$w × $h'),
      ('Duration', _fmtDuration((i['durationMs'] as num?)?.toInt())),
      if (i['bitrate'] != null)
        ('Bitrate', '${(((i['bitrate'] as num).toInt()) / 1000).round()} kbps'),
      if (i['mime'] != null) ('Format', i['mime'].toString()),
      ('Size', _fmtSize((i['sizeBytes'] as num?)?.toInt())),
      ('File', (i['path'] ?? recording.outputPath ?? '—').toString()),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recording details',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(k,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    Expanded(
                      child: Text(v,
                          style: Theme.of(context).textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
