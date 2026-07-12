// fix721 (Phase 5) — two folded changes:
//  (a) a TV-gated dialogTheme giving AlertDialog/SelectDialog the same redesign
//      glass as the fix720 bottom sheets (phone → null → Material default).
//  (b) a pub-cache CI step (actions/cache@v4 on ~/.pub-cache) added to both
//      workflows so `flutter pub get` reuses resolved deps across runs — pure
//      dependency-download speedup, no gate/needs/trigger/concurrency change.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final main = File('lib/main.dart').readAsStringSync();
  final analyzeYml = File('.github/workflows/analyze.yml').readAsStringSync();
  final releaseYml = File('.github/workflows/release.yml').readAsStringSync();

  group('fix721 (a) TV dialog glass', () {
    test('dialogTheme is TV-gated (null on phone)', () {
      expect(main.contains('dialogTheme: hasTouchScreen'), isTrue);
      expect(main.contains('DialogThemeData('), isTrue);
    });
    test('dialog uses the same F4 glass fill + radius as the bottom sheet', () {
      // both the bottomSheet (fix720) and the dialog (fix721) use 0xF00B0F19
      expect(
          RegExp(r'backgroundColor: Color\(0xF00B0F19\)')
              .allMatches(main)
              .length,
          greaterThanOrEqualTo(2));
      expect(main.contains('BorderRadius.all(Radius.circular(20))'), isTrue);
    });
  });

  group('fix721 (b) pub-cache CI step', () {
    test('analyze.yml caches ~/.pub-cache after Flutter setup', () {
      expect(analyzeYml.contains('actions/cache@v4'), isTrue);
      expect(analyzeYml.contains('path: ~/.pub-cache'), isTrue);
      expect(
          analyzeYml
              .contains(r"key: pub-${{ runner.os }}-${{ hashFiles('pubspec.lock') }}"),
          isTrue);
    });
    test('release.yml adds the pub-cache step to BOTH jobs (gate + build)', () {
      // two occurrences = analyze gate job + build-and-release job.
      // String implements Pattern, so allMatches counts literal occurrences.
      expect(
          'path: ~/.pub-cache'.allMatches(releaseYml).length, 2);
    });
    test('the cache step is additive — analyze gate + needs untouched', () {
      // sanity: the hard-gate invocation + the build dependency still present
      expect(releaseYml.contains('flutter analyze --no-fatal-infos'), isTrue);
      expect(releaseYml.contains('needs: analyze'), isTrue);
    });
  });
}
