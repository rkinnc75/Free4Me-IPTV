import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/media_type.dart';

/// fix397: the ordered list a full-screen stream was launched from — search
/// results, a category, favorites, browse, etc. — plus the index of the
/// channel currently playing. This is what lets the player surf channel +/-
/// through "whatever list the stream started on".
///
/// Immutable: switching channels produces a new instance via [withIndex] and a
/// fresh Player route, so the playback state machine never has to mutate its
/// channel in place (the player references its channel in ~55 places).
class PlaybackPlaylist {
  final List<Channel> channels;
  final int index;

  const PlaybackPlaylist({required this.channels, required this.index});

  Channel get current => channels[index];

  /// A row is surfable only if it can be opened directly: it has a URL and is
  /// not a category folder ([MediaType.group]) or a series folder
  /// ([MediaType.serie] / a `seriesId` placeholder). Those require drilling in,
  /// not direct playback, so channel +/- skips them.
  static bool isPlayable(Channel c) =>
      c.url != null &&
      c.url!.isNotEmpty &&
      c.mediaType != MediaType.group &&
      c.mediaType != MediaType.serie &&
      c.seriesId == null;

  /// Whether at least one OTHER playable channel exists — i.e. whether the
  /// channel +/- control should be offered at all.
  bool get hasSurfableNeighbor => neighborIndex(1) != null;

  /// Index of the next playable channel in [direction] (+1 = down/next in the
  /// list, -1 = up/previous), skipping non-playable rows and wrapping at the
  /// ends. Returns null when no other playable channel exists.
  int? neighborIndex(int direction) {
    final n = channels.length;
    if (n == 0 || direction == 0 || index < 0 || index >= n) return null;
    // Walk every other position once, in surf order, wrapping.
    for (int step = 1; step < n; step++) {
      final i = ((index + direction * step) % n + n) % n;
      if (isPlayable(channels[i])) return i;
    }
    return null;
  }

  PlaybackPlaylist withIndex(int i) =>
      PlaybackPlaylist(channels: channels, index: i);
}
