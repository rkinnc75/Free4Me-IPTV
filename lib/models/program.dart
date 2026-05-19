class Program {
  final int? id;
  final String epgChannelId;
  final int sourceId;
  final String title;
  final String? description;
  final String? category;
  final int startUtc; // Unix epoch seconds
  final int stopUtc;  // Unix epoch seconds
  final String? episodeNum;

  const Program({
    this.id,
    required this.epgChannelId,
    required this.sourceId,
    required this.title,
    this.description,
    this.category,
    required this.startUtc,
    required this.stopUtc,
    this.episodeNum,
  });

  DateTime get startTime =>
      DateTime.fromMillisecondsSinceEpoch(startUtc * 1000);
  DateTime get stopTime => DateTime.fromMillisecondsSinceEpoch(stopUtc * 1000);
  Duration get duration => stopTime.difference(startTime);

  bool isOnNow(int nowEpoch) => startUtc <= nowEpoch && nowEpoch < stopUtc;
}
