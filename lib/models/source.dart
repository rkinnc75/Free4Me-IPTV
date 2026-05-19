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
  });
}
