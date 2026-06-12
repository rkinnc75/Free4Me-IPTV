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
  /// fix184: provider connection limit (null = unknown).
  /// Auto-detected for Xtream; manual for M3U.
  int? maxConnections;
  /// fix196: per-source tag color as ARGB int (null = None/no tint).
  int? color;

  /// fix256/fix272: per-source browse sort.
  /// 'provider' = provider's intended order (channels.provider_order);
  /// 'category' = group by category (group_name) then provider order (fix272);
  /// 'alpha' or null = alphabetical by name.
  String? sortMode;

  /// fix268: counts from the most recent refresh (null until first refresh
  /// after this shipped). Shown read-only in the source edit dialog.
  int? lastLiveCount;
  int? lastMovieCount;
  int? lastSeriesCount;

  /// fix272: when 1, hide provider "divider" channels (is_divider=1) from
  /// browse views. Null/0 = show them.
  int? hideDividers;

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
    this.maxConnections,
    this.color,
    this.sortMode,
    this.lastLiveCount,
    this.lastMovieCount,
    this.lastSeriesCount,
    this.hideDividers,
  });
}
