import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:open_tv/backend/m3u.dart';
import 'package:open_tv/backend/settings_io.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/xtream.dart';
import 'package:open_tv/memory.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class Utils {
  static String? _appDir;
  static Future<String> get appDir async {
    _appDir ??= (await getApplicationSupportDirectory()).path;
    return _appDir!;
  }

  static Future<String> getTempPath(String fileName) async {
    final path = await appDir;
    final tempDir = join(path, "temp");
    await Directory(tempDir).create(recursive: true);
    return join(tempDir, fileName);
  }

  static Future<void> refreshSource(Source source) async {
    refreshedSeries.clear();
    await processSource(source, true);
    // After channels are populated, apply any favorites and last-
    // watched timestamps that an imported backup staged for this
    // source (see fix28.2 / SettingsIo.applyPendingPreserves). No-op
    // if no preserve list is pending.
    await SettingsIo.applyPendingPreserves(source.name);
  }

  static Future<void> processSource(
    Source source, [
    bool wipe = false,
    void Function(String)? onProgress,
  ]) async {
    switch (source.sourceType) {
      case SourceType.m3u:
        await processM3U(source, wipe, null, onProgress);
        break;
      case SourceType.m3uUrl:
        await processM3UUrl(source, wipe, onProgress);
        break;
      case SourceType.xtream:
        await getXtream(source, wipe, onProgress);
        break;
    }
  }

  static Future<void> refreshAllSources() async {
    final sources = await Sql.getSources();
    const maxConcurrent = 2;
    for (var i = 0; i < sources.length; i += maxConcurrent) {
      final chunk = sources.skip(i).take(maxConcurrent);
      await Future.wait(chunk.map(refreshSource));
    }
  }

  static Future<bool> hasTouchScreen() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return androidInfo.systemFeatures
          .contains('android.hardware.touchscreen');
    }
    return true;
  }
}
