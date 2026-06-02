import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/source_type.dart';

class Source {
  int? id;
  String name;
  String? url;
  String? urlOrigin;
  String? username;
  String? password;
  SourceType sourceType;
  bool enabled;
  String? epgUrl;
  /// Default engine for all channels from this source. Null = auto.
  EngineType? defaultEngine;
  /// fix184: provider connection limit (null = unknown).
  /// Auto-detected for Xtream; manual for M3U.
  int? maxConnections;
  /// fix196: per-source tag color as ARGB int (null = None/no tint).
  int? color;

  Source({
    this.id,
    required this.name,
    this.url,
    this.urlOrigin,
    this.username,
    this.password,
    required this.sourceType,
    this.enabled = true,
    this.epgUrl,
    this.defaultEngine,
    this.maxConnections,
    this.color,
  });
}
