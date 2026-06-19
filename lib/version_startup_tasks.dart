import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/whats_new_modal.dart';

/// fix403: the once-per-version startup tasks — rotate (clear) the debug log and
/// playback metrics on a version change, then show the What's New dialog.
///
/// These previously lived ONLY inside `Home(firstLaunch: true)` (the phone
/// entry constructed in main.dart). The TV entry routes through `TvHome`, which
/// pushes `Home(firstLaunch: false)`, so on a TV NEITHER task ever ran: the
/// debug log never cleared across versions (it just accumulated every build's
/// sessions) and release notes never appeared after an update. This shared
/// helper lets both entry points run the same tasks.
///
/// Both steps are idempotent — gated on `lastLogClearedVersion` /
/// `lastSeenVersion` inside [SettingsService] — so calling this on every entry
/// is a cheap no-op once it has run for the current version. The What's New
/// modal marks `lastSeenVersion` itself when it closes (see whats_new_modal),
/// so this helper does not need to.
Future<void> runVersionStartupTasks(BuildContext context) async {
  await SettingsService.maybeRotateLogOnVersionChange();
  final version = await SettingsService.shouldShowWhatsNew();
  if (version == null) return;
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (context) => WhatsNewModal(version: version),
  );
}
