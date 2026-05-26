class ChannelPreserve {
  String name;
  int? favorite;
  int? lastWatched;
  // fix50: also preserve EPG assignments so source refresh doesn't
  // erase every EPG match the user has accumulated.
  String? epgChannelId;
  String? epgManualOverride;

  ChannelPreserve({
    required this.name,
    this.favorite,
    this.lastWatched,
    this.epgChannelId,
    this.epgManualOverride,
  });
}
