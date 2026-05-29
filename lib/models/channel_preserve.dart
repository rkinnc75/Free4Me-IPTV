class ChannelPreserve {
  String name;
  int? favorite;
  int? lastWatched;
  // erase every EPG match the user has accumulated.
  String? epgChannelId;
  String? epgManualOverride;
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
