/// fix667: a Scheduled Recording (SR) — a scheduled, active, or finished capture of a
/// channel's HTTP stream to a file.
///
/// The stored window ([scheduledStartUtc] + [durationMs]) is ALREADY padded:
/// pads are folded in at schedule time so later changing the global pad
/// defaults never retroactively shifts an existing recording. [padBeforeMin] /
/// [padAfterMin] are retained for display and per-recording editing.
enum RecordingStatus {
  scheduled,
  recording,
  compressing,
  done,
  failed,
  cancelled;

  static RecordingStatus fromName(String? s) {
    for (final v in RecordingStatus.values) {
      if (v.name == s) return v;
    }
    return RecordingStatus.scheduled;
  }
}

class Recording {
  final int? id;
  final int? channelId;
  final String channelName;
  final String url;

  /// Padded start (epoch seconds) — programme start minus the before-pad.
  final int scheduledStartUtc;

  /// Padded total duration in milliseconds — programme length plus both pads
  /// (or the manual duration for a "record now").
  final int durationMs;

  final int padBeforeMin;
  final int padAfterMin;

  final RecordingStatus status;
  final String? outputPath;
  final String? error;
  final int createdUtc;

  const Recording({
    this.id,
    this.channelId,
    required this.channelName,
    required this.url,
    required this.scheduledStartUtc,
    required this.durationMs,
    this.padBeforeMin = 0,
    this.padAfterMin = 0,
    this.status = RecordingStatus.scheduled,
    this.outputPath,
    this.error,
    required this.createdUtc,
  });

  DateTime get startTime =>
      DateTime.fromMillisecondsSinceEpoch(scheduledStartUtc * 1000);
  DateTime get endTime =>
      startTime.add(Duration(milliseconds: durationMs));

  Recording copyWith({
    int? id,
    RecordingStatus? status,
    String? outputPath,
    String? error,
  }) =>
      Recording(
        id: id ?? this.id,
        channelId: channelId,
        channelName: channelName,
        url: url,
        scheduledStartUtc: scheduledStartUtc,
        durationMs: durationMs,
        padBeforeMin: padBeforeMin,
        padAfterMin: padAfterMin,
        status: status ?? this.status,
        outputPath: outputPath ?? this.outputPath,
        error: error ?? this.error,
        createdUtc: createdUtc,
      );

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'channel_id': channelId,
        'channel_name': channelName,
        'url': url,
        'scheduled_start_utc': scheduledStartUtc,
        'duration_ms': durationMs,
        'pad_before_min': padBeforeMin,
        'pad_after_min': padAfterMin,
        'status': status.name,
        'output_path': outputPath,
        'error': error,
        'created_utc': createdUtc,
      };
}
