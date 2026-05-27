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

  /// Which search implementation to use (fix68). Defaults to ftsAnd.
  SearchMethod searchMethod;

  /// When true, channels matching the adult-content blocklist are excluded
  /// from all queries (fix70). Mirrors Settings.safeMode.
  bool safeMode;

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
    // fix68's searchMethod setting which controls this more explicitly.
    this.useKeywords = true,
    this.searchMethod = SearchMethod.ftsAnd,
    this.safeMode = false,
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
      );
}
