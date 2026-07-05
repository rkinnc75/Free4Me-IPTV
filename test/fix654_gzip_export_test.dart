// fix654: export files (diagnostic bundle + backup/restore) are now gzipped
// at level 9 via dart:io's native ZLibEncoder instead of archive's pure-Dart
// Deflate (which OOM'd on a 532MB source dump) or its XZEncoder (which never
// actually compresses — see settings_io.dart doc comment). This guards the
// round trip: gzipBytes -> maybeGunzip recovers the original bytes, and
// maybeGunzip is a no-op passthrough for pre-fix654 plain (ungzipped) files.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/settings_io.dart';

void main() {
  group('SettingsIo gzip round trip (fix654)', () {
    test('gzipBytes -> maybeGunzip recovers the original payload', () {
      final original = utf8.encode('{"schemaVersion":4,"sources":[]}' * 100);
      final compressed = SettingsIo.gzipBytes(original);
      expect(compressed.length, lessThan(original.length));
      expect(SettingsIo.maybeGunzip(compressed), equals(original));
    });

    test('maybeGunzip passes through non-gzip (legacy plain) bytes', () {
      final plain = utf8.encode('{"schemaVersion":4}');
      expect(SettingsIo.maybeGunzip(plain), equals(plain));
    });

    test('maybeGunzip handles input shorter than the magic header', () {
      expect(SettingsIo.maybeGunzip(const [0x1f]), equals(const [0x1f]));
      expect(SettingsIo.maybeGunzip(const []), equals(const []));
    });
  });

  group('SettingsIo.staleExportArtifactNames recognises .json.gz (fix654)',
      () {
    test('a gzipped backup is treated as the same artifact family', () {
      final stale = SettingsIo.staleExportArtifactNames(
        const [
          'free4me-backup-x-20260701-000000.json.gz',
          'free4me-backup-x-20260705-101007.json.gz',
        ],
        keepBackupFile: 'free4me-backup-x-20260705-101007.json.gz',
      );
      expect(stale, ['free4me-backup-x-20260701-000000.json.gz']);
    });
  });
}
