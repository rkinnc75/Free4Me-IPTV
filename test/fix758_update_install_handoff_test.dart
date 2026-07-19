// fix758: suppress picture-in-picture during the in-app APK install handoff.
//
// When the user taps "Update" while a channel is playing, the app hands the
// downloaded APK to the system installer (OpenFilex → VIEW intent). On
// Android 12+ the leaving activity can auto-enter PiP, popping the OLD build
// into a small window on top of the "install this update?" prompt. This fix
// sets an `apkInstallHandoff` flag that suppresses PiP for the handoff and is
// cleared when the user returns (onResume) or if the installer never opened
// (endApkInstall).
//
// Design note (why this is PiP-suppression ONLY): OpenFilex serves the APK to
// the installer through this app's own FileProvider, so the process must stay
// alive for the installer to read the file. The earlier runbook draft also
// removed the app task (finishAndRemoveTask) after a timer — that is dropped
// here: killing/reaping the task while the FileProvider is still the source of
// the package can produce "problem parsing the package" on low-RAM TVs. These
// tests pin BOTH the behaviour we keep and the risky bits we deliberately
// left out, so a future edit can't quietly reintroduce them.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final native = File(
    'android/app/src/main/kotlin/me/free4me/iptv/MainActivity.kt',
  ).readAsStringSync();
  final dart = File('lib/backend/update_checker.dart').readAsStringSync();

  group('native (MainActivity.kt)', () {
    test('declares the apkInstallHandoff flag, defaulting to false', () {
      expect(native.contains('private var apkInstallHandoff = false'), isTrue);
    });

    test('exposes the update_install MethodChannel with begin/end only', () {
      expect(native.contains('"me.free4me.iptv/update_install"'), isTrue);
      expect(native.contains('"beginApkInstall" ->'), isTrue);
      expect(native.contains('"endApkInstall" ->'), isTrue);
      // beginApkInstall SETS the flag; endApkInstall CLEARS it.
      final begin = native.indexOf('"beginApkInstall" ->');
      final end = native.indexOf('"endApkInstall" ->');
      expect(begin, greaterThan(0));
      expect(end, greaterThan(begin));
      expect(native.substring(begin, end).contains('apkInstallHandoff = true'),
          isTrue);
      expect(
          native.substring(end, end + 200).contains('apkInstallHandoff = false'),
          isTrue);
    });

    test('onUserLeaveHint refuses PiP during the handoff', () {
      final idx = native.indexOf('override fun onUserLeaveHint()');
      expect(idx, greaterThan(0));
      final body = native.substring(idx, idx + 400);
      expect(body.contains('!apkInstallHandoff'), isTrue);
    });

    test('auto-enter PiP is disabled during the handoff', () {
      expect(
        native.contains(
            'setAutoEnterEnabled(isVideoPlaying && !apkInstallHandoff)'),
        isTrue,
      );
    });

    test('onResume clears the handoff flag (PiP restored after cancel)', () {
      final idx = native.indexOf('override fun onResume()');
      expect(idx, greaterThan(0));
      final body = native.substring(idx, idx + 400);
      expect(body.contains('apkInstallHandoff = false'), isTrue);
    });

    test('does NOT remove the app task — FileProvider still serves the APK', () {
      // The risky bit from the original runbook draft. Its absence is the fix.
      expect(native.contains('finishAndRemoveTask'), isFalse);
    });

    test('the handoff never force-clears isVideoPlaying', () {
      // We suppress PiP via the flag, not by lying about playback state. The
      // only `isVideoPlaying = false` allowed is the field's default
      // initializer; no handoff code path may assign it.
      final withoutDecl =
          native.replaceAll('private var isVideoPlaying = false', '');
      expect(withoutDecl.contains('isVideoPlaying = false'), isFalse);
    });

    test('no completeApkInstallHandoff / delayed-kill handshake', () {
      expect(native.contains('completeApkInstall'), isFalse);
      // No timer-based task teardown was introduced.
      expect(native.contains('Handler(Looper'), isFalse);
    });
  });

  group('dart (update_checker.dart)', () {
    test('talks to the update_install channel', () {
      expect(dart.contains("MethodChannel('me.free4me.iptv/update_install')"),
          isTrue);
      expect(dart.contains("invokeMethod<void>('beginApkInstall')"), isTrue);
      expect(dart.contains("invokeMethod<void>('endApkInstall')"), isTrue);
    });

    test('begins the handoff immediately before opening the installer', () {
      final begin = dart.indexOf('_beginApkInstallHandoff()');
      final open = dart.indexOf('OpenFilex.open(outFile.path)');
      expect(begin, greaterThan(0));
      expect(open, greaterThan(begin));
    });

    test('ends the handoff only on the installer-did-not-open path', () {
      final open = dart.indexOf('OpenFilex.open(outFile.path)');
      final tail = dart.substring(open);
      // endApkInstall lives inside the `result.type != ResultType.done` branch.
      expect(tail.contains('result.type != ResultType.done'), isTrue);
      expect(tail.contains('_endApkInstallHandoff()'), isTrue);
      // On the success path we do NOT end/complete — native onResume owns it.
      expect(dart.contains('_completeApkInstallHandoff'), isFalse);
    });

    test('the handoff calls are Android-guarded and swallow channel errors', () {
      final idx = dart.indexOf('static Future<void> _beginApkInstallHandoff()');
      expect(idx, greaterThan(0));
      final body = dart.substring(idx, idx + 600);
      expect(body.contains('if (!Platform.isAndroid) return;'), isTrue);
      expect(body.contains('catch'), isTrue);
    });
  });
}
