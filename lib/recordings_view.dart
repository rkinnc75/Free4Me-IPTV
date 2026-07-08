import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_tv/backend/recording_capture.dart';
import 'package:open_tv/backend/recording_scheduler.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final recs = await Sql.getRecordings();
    if (!mounted) return;
    setState(() {
      _recordings = recs;
      _loading = false;
    });
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
    await RecordingCapture.stop(r.id!);
    await _load();
  }

  Future<void> _cancel(Recording r) async {
    if (r.id == null) return;
    await RecordingScheduler.cancel(r.id!);
    await _load();
  }

  Future<void> _delete(Recording r) async {
    if (r.id == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text('Remove "${r.channelName}" from the list? '
            'This does not delete the saved video file.'),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    // If it's still running, stop the capture first.
    if (r.status == RecordingStatus.recording && r.id != null) {
      await RecordingCapture.stop(r.id!);
    }
    await Sql.deleteRecording(r.id!);
    await _load();
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
                      return ListTile(
                        leading: Icon(icon, color: color),
                        title: Text(r.channelName,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('$label · ${_subtitle(r)}',
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: _trailing(r),
                        onTap: r.status == RecordingStatus.done
                            ? () => _play(r)
                            : null,
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
