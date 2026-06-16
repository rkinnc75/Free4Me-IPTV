// fix384: Edit and Delete buttons on a source row in Settings should
// always be enabled, regardless of the source's enabled/disabled
// state. (Color picker and Refresh stay gated on source.enabled —
// the user only sees / interacts with those when the source is
// actually being used.)
//
// This test is a regression guard against re-introducing a
// `!source.enabled` guard in front of the Edit or Delete `onPressed`
// callbacks. The check is grep-based because the gated logic lives
// inside the build method of a private State class
// (`_SettingsState.getSource` in lib/settings_view.dart), which is
// not directly constructable from a widget test without mounting the
// full SettingsView (heavy — pulls in platform channels, the
// SettingsService cache, etc.). The grep is the cheapest reliable
// signal that the gate is gone.

import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

void main() {
  group('fix384 — Edit and Delete not gated by source.enabled', () {
    test('Edit IconButton onPressed is unconditional (no !source.enabled gate)',
        () {
      final src = File('lib/settings_view.dart');
      expect(src.existsSync(), isTrue,
          reason: 'settings_view.dart must exist for the grep to run');
      final content = src.readAsStringSync();
      // Find the Edit IconButton block: the onPressed line should
      // be `onPressed: () async => await showEditDialog(context, source),`
      // with no `!source.enabled ? null :` guard.
      final editMatch = RegExp(
        r"onPressed:\s*!\s*source\.enabled\s*\?\s*null\s*:\s*\(\)\s*async\s*=>\s*await\s+showEditDialog",
        multiLine: true,
      ).hasMatch(content);
      expect(editMatch, isFalse,
          reason: 'Edit IconButton must not be gated by !source.enabled '
              '(fix384). Grep matched:\n'
              '${RegExp(r".{0,80}showEditDialog.{0,80}", multiLine: true).firstMatch(content)?.group(0)}');
    });

    test('Delete IconButton onPressed is unconditional (no !source.enabled gate)',
        () {
      final src = File('lib/settings_view.dart');
      expect(src.existsSync(), isTrue);
      final content = src.readAsStringSync();
      final deleteMatch = RegExp(
        r"onPressed:\s*!\s*source\.enabled\s*\?\s*null\s*:\s*\(\)\s*async\s*=>\s*await\s+showConfirmDeleteDialog",
        multiLine: true,
      ).hasMatch(content);
      expect(deleteMatch, isFalse,
          reason: 'Delete IconButton must not be gated by !source.enabled '
              '(fix384).');
    });

    test('Color picker (leading icon) IS still gated by !source.enabled',
        () {
      // Regression guard for the other side: Color picker and
      // Refresh stay gated. If someone removes ALL the gates by
      // accident, the design intent is lost. This test pins that
      // those two remain gated.
      final src = File('lib/settings_view.dart');
      final content = src.readAsStringSync();
      // The color picker is the leading InkWell's onTap. Look for
      // the `onTap: !source.enabled ? null :` pattern specifically
      // for the color-picker comment.
      final colorMatch = RegExp(
        r"onTap:\s*!\s*source\.enabled\s*\?\s*null\s*:",
        multiLine: true,
      ).hasMatch(content);
      expect(colorMatch, isTrue,
          reason: 'Color picker (leading icon) must remain gated by '
              '!source.enabled. fix384 only removed the gate from '
              'Edit and Delete.');
    });
  });
}
