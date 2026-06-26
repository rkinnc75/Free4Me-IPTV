import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';

class Filters {
  String? query;
  List<int>? sourceIds;
  List<MediaType>? mediaTypes;
  ViewType viewType;
  int page;
  int? seriesId;
  int? groupId;
  bool useKeywords;

  /// Which search implementation to use. Defaults to ftsAnd.
  SearchMethod searchMethod;

  /// When true, channels matching the adult-content blocklist are excluded
  /// from all queries. Mirrors Settings.safeMode.
  bool safeMode;

  /// fix557: optional override for the page size. Null (the default) means
  /// "use the global `pageSize` constant" — every existing caller (phone
  /// browse, TV browse/guide) is unaffected. Set this when a caller wants
  /// more than one page of results in a single query, e.g. TV search, which
  /// previously silently capped at pageSize (36) with no way to see more.
  int? limit;

  Filters({
    this.query,
    this.sourceIds,
    this.mediaTypes,
    required this.viewType,
    this.page = 1,
    this.seriesId,
    this.groupId,
    // Default true — AND mode is measurably faster than phrase for
    // multi-word queries (6s vs 17s on 54k channels). Superseded by
    this.useKeywords = true,
    this.searchMethod = SearchMethod.inMemory,
    this.safeMode = false,
    this.limit,
  });

  /// Returns a shallow copy of this [Filters] with all fields cloned.
  /// Lists are copied so mutations to the original don't affect the snapshot.
  Filters copy() => Filters(
        query: query,
        sourceIds: sourceIds != null ? List.of(sourceIds!) : null,
        mediaTypes: mediaTypes != null ? List.of(mediaTypes!) : null,
        viewType: viewType,
        page: page,
        seriesId: seriesId,
        groupId: groupId,
        useKeywords: useKeywords,
        searchMethod: searchMethod,
        safeMode: safeMode,
        limit: limit,
      );
}
