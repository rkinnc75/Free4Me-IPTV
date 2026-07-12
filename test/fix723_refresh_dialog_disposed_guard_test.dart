// fix723 — leaving Settings during a Re-match / source-refresh no longer aborts
// it. The work runs on BackgroundTaskService (fix349) and outlives the screen;
// _updateRefreshDialog used to call the captured dialog setState even after this
// State (and the dialog's) was disposed → an unhandled 'Null check operator'
// throw that aborted the loop partway. The guard skips the UI update once
// disposed so the work runs headless to completion.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

void main() {
  final sv = File('lib/settings_view.dart').readAsStringSync();
  final body = _slice(sv, 'void _updateRefreshDialog(String status) {', '\n  }');

  group('fix723 refresh-dialog disposed guard', () {
    test('_updateRefreshDialog bails once the State is disposed', () {
      expect(body.contains('if (!mounted) return;'), isTrue);
      // the guard precedes the captured setState call
      expect(body.indexOf('if (!mounted) return;') <
          body.indexOf('_refreshSetState?.call'), isTrue);
    });

    test('the setState call is wrapped (belt-and-suspenders for the dialog race)',
        () {
      expect(body.contains('try {'), isTrue);
      expect(body.contains('_refreshSetState?.call(() {});'), isTrue);
      expect(body.contains('} catch (_) {'), isTrue);
    });

    test('status is still latched so a re-opened dialog repaints', () {
      expect(body.contains('_refreshStatus = status;'), isTrue);
    });

    test('post-await subtitle refresh re-checks mounted (review finding #4)', () {
      // _runEpgRefresh checked mounted before `await getLatestEpgRefresh()` but
      // setState after it without re-checking → a distinct setState-after-dispose
      // if the user leaves during the await. Folded into fix723.
      expect(
          sv.contains('if (mounted) setState(() => _latestEpgRefreshTs = ts);'),
          isTrue);
    });
  });
}
