// fix328: verify the disk-backed export zip (ZipFileEncoder streams files from
// disk and produces a valid, re-readable archive). Guards the OOM fix's core
// mechanism.
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ZipFileEncoder streams files to a valid zip on disk', () async {
    final tmp = await Directory.systemTemp.createTemp('export_zip_test');
    final a = File('${tmp.path}/free4me-source-dump.txt')
      ..writeAsStringSync('===== FILE: x.json =====\n${'big' * 5000}\n');
    final b = File('${tmp.path}/free4me-settings.json')
      ..writeAsStringSync('{"schema":3}');
    final zipPath = '${tmp.path}/out.zip';

    final enc = ZipFileEncoder()..create(zipPath);
    await enc.addFile(a, 'free4me-source-dump.txt');
    await enc.addFile(b, 'free4me-settings.json');
    await enc.close();

    final zf = File(zipPath);
    expect(await zf.exists(), isTrue);
    expect(await zf.length(), greaterThan(0));

    final arch = ZipDecoder().decodeBytes(await zf.readAsBytes());
    final names = arch.files.map((f) => f.name).toSet();
    expect(names, {'free4me-source-dump.txt', 'free4me-settings.json'});
    final settings =
        arch.files.firstWhere((f) => f.name == 'free4me-settings.json');
    expect(
        String.fromCharCodes(settings.content as List<int>), '{"schema":3}');

    await tmp.delete(recursive: true);
  });
}
