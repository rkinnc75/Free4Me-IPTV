import 'package:flutter/material.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/tv/tv_shell.dart';
import 'package:open_tv/version_startup_tasks.dart';

/// fix500: the Android-TV entry point.
///
/// Runs the once-per-version startup tasks (What's New + log/metrics rotation,
/// fix403) on first frame, then hosts the persistent [TvShell] tabbed UI. The
/// old two-level giant-button menu (Channels/Categories/Favorites/History +
/// nested All/Live/Vods/Series) is gone — replaced by the shell.
class TvHome extends StatefulWidget {
  final Settings settings;
  const TvHome({super.key, required this.settings});

  @override
  State<TvHome> createState() => _TvHomeState();
}

class _TvHomeState extends State<TvHome> {
  @override
  void initState() {
    super.initState();
    // The version-startup tasks (log rotation + What's New) historically lived
    // in Home(firstLaunch:true) — the phone entry. The TV entry is TvHome, so
    // run them here for the TV root. Idempotent — a no-op once done for the
    // current version.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) runVersionStartupTasks(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return TvShell(settings: widget.settings);
  }
}
