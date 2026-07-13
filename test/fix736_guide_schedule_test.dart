// fix736 — the Live guide's channel menu opens the channel's full programme
// schedule (ChannelScheduleView) so a user can browse FUTURE shows, read
// details, and Record (schedule) them from the guide. Reuses the proven
// ChannelScheduleView + RecordingActions.recordProgramme (real SR arc).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final guide = File('lib/tv/tv_guide_view.dart').readAsStringSync();
  final schedule = File('lib/views/channel_schedule.dart').readAsStringSync();

  test('guide imports + opens ChannelScheduleView (live only)', () {
    expect(
        guide.contains("import 'package:open_tv/views/channel_schedule.dart'"),
        isTrue);
    expect(guide.contains("title: const Text('Program guide & record')"), isTrue);
    expect(guide.contains('ChannelScheduleView(channel: ch)'), isTrue);
  });

  test('ChannelScheduleView still exposes future-show details + record', () {
    // guard the reused capability so a refactor there can't silently gut this
    expect(schedule.contains('void _recordProgramme(Program p)'), isTrue);
    expect(
        schedule.contains('RecordingActions.recordProgramme('), isTrue);
    expect(schedule.contains('void _showDetails('), isTrue);
  });
}
