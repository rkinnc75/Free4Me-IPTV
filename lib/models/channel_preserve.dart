class ChannelPreserve {
  String name;
  int? favorite;
  int? lastWatched;
  // fix50: also preserve EPG assignments so source refresh doesn't
  // erase every EPG match the user has accumulated.
  String? epgChannelId;
  String? epgManualOverride;
  // fix74: preserve stream scan result across source refresh.
  int? streamValidated;

  ChannelPreserve({
    required this.name,
    this.favorite,
    this.lastWatched,
    this.epgChannelId,
    this.epgManualOverride,
    this.streamValidated,
  });
}
