// fix385: regression guards for the Edit Source dialog changes.
//
// Scopes verified (per the in-conversation review):
//   - #1  Name is now an editable form field (was: read from source).
//   - #4  Color is rendered (palette icon + tap-to-edit), state held
//        in _EditDialogState._color (was: read from source only).
//   - #6  Cancel button is autofocused on dialog open (was: Save).
//   - #9  Counts info section sits at the top of the dialog
//        (was: at the bottom, after the form fields).
//   - #10 Placeholder "Counts appear after the next refresh."
//        appears when ANY of the three counts is null
//        (was: only when ALL three were null).
//   - #11 URL field has a real URL-shape validator
//        (was: required-only).
//   - #16 A "Test connection" button is present, dispatches per
//        source type (Xtream → fetchXtreamMaxConnections,
//        M3U URL → HttpClient.headUrl, M3U file → File.existsSync).
//   - #21 Title truncates the source name with ellipsis
//        (was: unbounded, could overflow the dialog title on TV).
//
// All checks below are grep-based on lib/edit_dialog.dart because
// the gated logic lives inside _EditDialogState, which is not
// directly constructable from a widget test without mounting the
// full dialog (which transitively pulls in SQL via
// fetchXtreamMaxConnections + the FormBuilderTextField keyboard
// platform channels). The grep is the cheapest reliable signal.

import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

void main() {
  final src = File('lib/edit_dialog.dart');
  final content = src.readAsStringSync();

  group('fix385 — Edit dialog: source file present', () {
    test('lib/edit_dialog.dart exists', () {
      expect(src.existsSync(), isTrue,
          reason: 'edit_dialog.dart must exist for the grep to run');
    });
  });

  group('fix385 — Edit dialog: name editable', () {
    test('name field uses FormBuilderTextField with name="name" and a controller', () {
      final fieldKey = RegExp(
        r"name:\s*'name',",
        multiLine: true,
      ).hasMatch(content);
      expect(fieldKey, isTrue,
          reason: 'name="name" field is required (fix385 #1).');
      final usesNameController = content.contains('_nameController');
      expect(usesNameController, isTrue,
          reason: 'A controller must back the name field (fix385 #1).');
    });

    test('name validator requires non-empty AND rejects duplicates via existingSourceNames', () {
      final hasRequired = RegExp(
        r'FormBuilderValidators\.required\(\)',
        multiLine: true,
      ).allMatches(content).isNotEmpty;
      expect(hasRequired, isTrue);
      final hasDupCheck = content.contains('_otherSourceNames');
      expect(hasDupCheck, isTrue,
          reason: 'Duplicate-name validator must check _otherSourceNames (fix385 #1).');
    });

    test('Save handler reads the new name from _nameController (not widget.source.name)', () {
      final saveReadsController = RegExp(
        r'name:\s*formName',
        multiLine: true,
      ).hasMatch(content);
      expect(saveReadsController, isTrue,
          reason: 'Save must persist the new name from the form '
              '(fix385 #1). The old code passed widget.source.name.');
    });
  });

  group('fix385 — Edit dialog: color editable', () {
    test('palette icon is rendered in the info section with an InkWell', () {
      final hasPalette = content.contains('Icons.palette_outlined');
      expect(hasPalette, isTrue,
          reason: 'Color picker swatch must be in the info section (fix385 #4).');
      final hasInkWell = content.contains('showSourceColorPicker(context');
      expect(hasInkWell, isTrue,
          reason: 'Tapping the color swatch must open the color picker (fix385 #4).');
    });

    test('_color state is held in the dialog (not derived from widget.source on render)', () {
      final usesColor = content.contains('color: _color,');
      expect(usesColor, isTrue,
          reason: 'Save must persist the in-state _color (fix385 #4).');
    });
  });

  group('fix385 — Edit dialog: Cancel autofocused', () {
    test('Save button no longer has autofocus: true', () {
      // Look for "Save" + "autofocus: true" within a 200-char window.
      final saveWithAutofocus = RegExp(
        r'autofocus:\s*true[\s\S]{0,200}Text\("Save"\)|Text\("Save"\)[\s\S]{0,200}autofocus:\s*true',
        multiLine: true,
      ).hasMatch(content);
      expect(saveWithAutofocus, isFalse,
          reason: 'Save must NOT be autofocused (fix385 #6).');
    });

    test('Cancel button has autofocus: true', () {
      final cancelAutofocus = RegExp(
        r'autofocus:\s*true[\s\S]{0,200}Text\("Cancel"\)|Text\("Cancel"\)[\s\S]{0,200}autofocus:\s*true',
        multiLine: true,
      ).hasMatch(content);
      expect(cancelAutofocus, isTrue,
          reason: 'Cancel must be autofocused (fix385 #6).');
    });
  });

  group('fix385 — Edit dialog: counts moved to top', () {
    test('info section is rendered before the form fields', () {
      final infoIdx = content.indexOf('_infoSection(context)');
      final nameIdx = content.indexOf("name: 'name'");
      expect(infoIdx, greaterThan(0),
          reason: '_infoSection must be called in the build method (fix385 #9).');
      expect(nameIdx, greaterThan(0),
          reason: 'name="name" field must exist (fix385 #1).');
      expect(infoIdx, lessThan(nameIdx),
          reason: 'Info section must come BEFORE the name field (fix385 #9).');
    });

    test('placeholder text "Counts appear after the next refresh" uses any-null', () {
      // Old code used AND (all null). New code must use OR (any null).
      final oldAllNull = RegExp(
        r'lastLiveCount\s*==\s*null\s*&&\s*lastMovieCount\s*==\s*null\s*&&\s*lastSeriesCount\s*==\s*null',
        multiLine: true,
      ).hasMatch(content);
      expect(oldAllNull, isFalse,
          reason: 'Placeholder must use ANY-null, not ALL-null (fix385 #10).');
      final hasAnyNull = content.contains('anyCountNull');
      expect(hasAnyNull, isTrue,
          reason: 'Code must define anyCountNull (fix385 #10).');
    });
  });

  group('fix385 — Edit dialog: URL validator + Test connection', () {
    test('URL field has a Uri.tryParse-based validator', () {
      final hasUriCheck = content.contains('Uri.tryParse');
      final hasHostCheck = content.contains('uri.host.isEmpty');
      expect(hasUriCheck && hasHostCheck, isTrue,
          reason: 'URL field must have a real URL-shape validator (fix385 #11).');
    });

    test('Test connection button is present and dispatches per source type', () {
      final hasButton = content.contains('Test connection');
      expect(hasButton, isTrue,
          reason: 'Test connection button must be in the form (fix385 #16).');
      final handlesXtream = content.contains('fetchXtreamMaxConnections');
      final handlesM3uUrl = content.contains('headUrl');
      final handlesM3u = content.contains('File(path).existsSync()');
      expect(handlesXtream, isTrue,
          reason: 'Xtream probe must call fetchXtreamMaxConnections (fix385 #16).');
      expect(handlesM3uUrl, isTrue,
          reason: 'M3U URL probe must use HttpClient.headUrl (fix385 #16).');
      expect(handlesM3u, isTrue,
          reason: 'M3U file probe must check File.existsSync (fix385 #16).');
    });
  });

  group('fix385 — Edit dialog: title truncation', () {
    test('title Text has maxLines: 1 and overflow: TextOverflow.ellipsis', () {
      final hasMaxLines = RegExp(
        r'maxLines:\s*1',
        multiLine: true,
      ).hasMatch(content);
      expect(hasMaxLines, isTrue,
          reason: 'Title must have maxLines: 1 (fix385 #21).');
      final hasEllipsis = content.contains('TextOverflow.ellipsis');
      expect(hasEllipsis, isTrue,
          reason: 'Title must have TextOverflow.ellipsis (fix385 #21).');
    });
  });
}
