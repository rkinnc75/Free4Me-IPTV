import 'package:flutter/material.dart';
import 'package:open_tv/backend/recording_scheduler.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/program.dart';

/// fix670: shared entry points for the three "create a recording" surfaces
/// (guide dialog, channel long-press menu, player). Centralises the low-space
/// handling and the user feedback so each surface is a one-liner.
class RecordingActions {
  RecordingActions._();

  /// Schedule [programme] on [channel]. Shows a confirmation or a low-space
  /// message. Returns true if scheduled.
  static Future<bool> recordProgramme(
    BuildContext context,
    Channel channel,
    Program programme,
  ) async {
    try {
      final id = await RecordingScheduler.scheduleForProgramme(channel, programme);
      if (!context.mounted) return false;
      if (id == null) {
        _snack(context, 'Could not schedule recording.');
        return false;
      }
      _snack(context, 'Recording scheduled: ${programme.title}');
      return true;
    } on LowDiskSpaceException catch (e) {
      if (context.mounted) _snack(context, e.toString());
      return false;
    } catch (e) {
      if (context.mounted) _snack(context, 'Could not schedule recording.');
      return false;
    }
  }

  /// Prompt for a duration (30 / 60 / 120 / custom) and start a "record now"
  /// on [channel]. Returns true if started.
  static Future<bool> recordNow(BuildContext context, Channel channel) async {
    final minutes = await _pickDuration(context);
    if (minutes == null || !context.mounted) return false;
    try {
      final id = await RecordingScheduler.scheduleNow(
        channel,
        durationMinutes: minutes,
      );
      if (!context.mounted) return false;
      if (id == null) {
        _snack(context, 'Could not start recording.');
        return false;
      }
      _snack(context, 'Recording for $minutes min: ${channel.name}');
      return true;
    } on LowDiskSpaceException catch (e) {
      if (context.mounted) _snack(context, e.toString());
      return false;
    } catch (e) {
      if (context.mounted) _snack(context, 'Could not start recording.');
      return false;
    }
  }

  static Future<int?> _pickDuration(BuildContext context) {
    return showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Record for how long?'),
        children: [
          for (final m in const [30, 60, 120])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, m),
              child: Text('$m minutes'),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final custom = await _customMinutes(ctx);
              if (ctx.mounted) Navigator.pop(ctx, custom);
            },
            child: const Text('Custom…'),
          ),
        ],
      ),
    );
  }

  static Future<int?> _customMinutes(BuildContext context) async {
    final controller = TextEditingController(text: '90');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom duration'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Minutes',
            hintText: '1–720',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              if (v != null && v >= 1) {
                Navigator.pop(ctx, v.clamp(1, 720));
              } else {
                Navigator.pop(ctx);
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  static void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }
}
