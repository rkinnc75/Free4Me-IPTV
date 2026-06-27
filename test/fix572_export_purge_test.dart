// fix572: export artifacts accumulated in the temp dir forever. Each QR/LAN
// export writes a `free4me-export-<stamp>/` bundle dir (which can hold
// multi-hundred-MB DB snapshots) that was never deleted after the download
// server stopped; the save-to-file flow leaves `free4me-backup-<stamp>.json`
// on a crash. The fix purges prior artifacts at the start of each export
// session, keeping only what that session is creating.
//
// The IO wrapper `purgeStaleExportArtifacts` depends on getTemporaryDirectory
// (a platform channel), so the unit-testable part is the pure decision
// function `staleExportArtifactNames` — this test pins exactly which basenames
// it selects for deletion under each "keep" mode.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/settings_io.dart';

void main() {
  group('SettingsIo.staleExportArtifactNames (fix572)', () {
    final names = <String>[
      'free4me-export-shield-20260627-101500', // current QR bundle dir
      'free4me-export-shield-20260626-090000', // prior QR bundle dir
      'free4me-export-onn-20260625-080000', // prior QR bundle dir (other device)
      'free4me-export-shield-20260620-070000.zip', // stray legacy zip
      'free4me-backup-shield-20260627-101500.json', // current save-to-file backup
      'free4me-backup-shield-20260624-060000.json', // orphaned backup (crash)
      'some-other-cache-file.tmp', // unrelated temp file
      'flutter_engine_xyz', // unrelated temp file
    ];

    test('QR flow keeps its bundle dir, purges all other artifacts', () {
      final stale = SettingsIo.staleExportArtifactNames(
        names,
        keepExportDir: 'free4me-export-shield-20260627-101500',
      );
      // The current bundle dir is kept; every other export dir/zip and EVERY
      // backup json (none is the current session's) is stale.
      expect(stale, containsAll(<String>[
        'free4me-export-shield-20260626-090000',
        'free4me-export-onn-20260625-080000',
        'free4me-export-shield-20260620-070000.zip',
        'free4me-backup-shield-20260627-101500.json',
        'free4me-backup-shield-20260624-060000.json',
      ]));
      expect(stale, isNot(contains('free4me-export-shield-20260627-101500')));
      // Unrelated temp files are never touched.
      expect(stale, isNot(contains('some-other-cache-file.tmp')));
      expect(stale, isNot(contains('flutter_engine_xyz')));
    });

    test('save-to-file flow keeps its backup, purges all other artifacts', () {
      final stale = SettingsIo.staleExportArtifactNames(
        names,
        keepBackupFile: 'free4me-backup-shield-20260627-101500.json',
      );
      expect(stale,
          isNot(contains('free4me-backup-shield-20260627-101500.json')));
      // All export bundle dirs/zips are stale from this flow's perspective.
      expect(stale, containsAll(<String>[
        'free4me-export-shield-20260627-101500',
        'free4me-export-shield-20260626-090000',
        'free4me-export-onn-20260625-080000',
        'free4me-export-shield-20260620-070000.zip',
        'free4me-backup-shield-20260624-060000.json',
      ]));
      expect(stale, isNot(contains('some-other-cache-file.tmp')));
    });

    test('with no keep args, every artifact of both families is stale', () {
      final stale = SettingsIo.staleExportArtifactNames(names);
      expect(stale.where((n) => n.startsWith('free4me-')).length, 6);
      expect(stale, isNot(contains('some-other-cache-file.tmp')));
      expect(stale, isNot(contains('flutter_engine_xyz')));
    });

    test('empty input yields nothing', () {
      expect(SettingsIo.staleExportArtifactNames(const <String>[]), isEmpty);
    });

    test('a backup-prefixed non-json file is NOT treated as a backup artifact',
        () {
      // Guard the suffix check: only `.json` backups are recognised, so a
      // `.tmp`/partial write of a backup name is left alone (not our family).
      final stale = SettingsIo.staleExportArtifactNames(
        const ['free4me-backup-x-20260101-000000.json.tmp'],
      );
      expect(stale, isEmpty);
    });
  });
}
