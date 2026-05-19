import 'package:open_tv/models/media_type.dart';

class Channel {
  int? id;
  String name;
  int? groupId;
  String? group;
  String? image;
  String? url;
  MediaType mediaType;
  int sourceId;
  bool favorite;
  int? seriesId;
  int? streamId;
  String? epgChannelId;

  // --- Catchup / time-shift (v1.3) ---
  /// Catchup engine: 'default', 'append', 'shift', 'flussonic', 'xc' (xtream).
  /// Null when the channel doesn't support catchup at all.
  String? catchupType;

  /// Provider-specific URL template (M3U `catchup-source`). May contain
  /// placeholders like {Y}, {m}, {d}, {H}, {M}, {S}, {utc}, {duration},
  /// ${start}, ${end}, ${timestamp}.
  String? catchupSource;

  /// How many days back the provider promises catchup will work.
  /// Programs older than this hide the "Watch from beginning" button.
  int? catchupDays;

  Channel({
    this.id,
    required this.name,
    this.group,
    this.groupId,
    this.image,
    this.url,
    required this.mediaType,
    required this.sourceId,
    required this.favorite,
    this.seriesId,
    this.streamId,
    this.epgChannelId,
    this.catchupType,
    this.catchupSource,
    this.catchupDays,
  });

  /// True iff this channel has any flavor of catchup support.
  bool get supportsCatchup =>
      catchupType != null && catchupType!.isNotEmpty;
}
