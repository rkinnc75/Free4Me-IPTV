// fix733 (mock §4.5) — the History tab is a TV-native poster grid
// (TvHistoryView) instead of the reused phone Home. Source checks.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final view = File('lib/tv/tv_history_view.dart').readAsStringSync();
  final shell = File('lib/tv/tv_shell.dart').readAsStringSync();

  test('TvHistoryView exists + queries the history viewType', () {
    expect(view.contains('class TvHistoryView'), isTrue);
    expect(view.contains('viewType: ViewType.history'), isTrue);
  });

  test('reuses the shared ChannelTile poster grid spec', () {
    expect(view.contains('ChannelTile('), isTrue);
    expect(view.contains('maxCrossAxisExtent: 130'), isTrue);
    expect(view.contains('childAspectRatio: 0.838'), isTrue);
    expect(view.contains('poster: true'), isTrue);
    expect(view.contains('showSourceEdgeBar: true'), isTrue);
  });

  test('shell routes ViewType.history to TvHistoryView (not phone Home)', () {
    expect(shell.contains('import '
        "'package:open_tv/tv/tv_history_view.dart'"), isTrue);
    expect(shell.contains('t.viewType == ViewType.history'), isTrue);
    expect(shell.contains('TvHistoryView('), isTrue);
    // the Clear-history rebuild also uses the TV grid now
    expect(RegExp(r'TvHistoryView\(').allMatches(shell).length,
        greaterThanOrEqualTo(2));
  });

  test('empty + error + removal paths exist', () {
    expect(view.contains('Nothing watched yet'), isTrue);
    expect(view.contains("'Retry'"), isTrue);
    expect(view.contains('onRemoveHistory'), isTrue);
  });
}
