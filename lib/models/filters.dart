import 'package:open_tv/models/media_type.dart';
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

  Filters({
    this.query,
    this.sourceIds,
    this.mediaTypes,
    required this.viewType,
    this.page = 1,
    this.seriesId,
    this.groupId,
    this.useKeywords = false,
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
      );
}
