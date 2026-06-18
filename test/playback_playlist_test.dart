// fix397: pure-logic guard for channel +/- neighbour resolution. The player
// surfs through "whatever list the stream started on" (e.g. search ESPN -> 12
// results, open #4, channel-down through the rest), skipping non-playable rows
// (category folders, series folders, url-less entries) and wrapping at ends.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/playback_playlist.dart';

Channel _live(String name, {String? url = 'http://x/stream.ts'}) => Channel(
      name: name,
      mediaType: MediaType.livestream,
      sourceId: 1,
      favorite: false,
      url: url,
    );

Channel _group(String name) => Channel(
      name: name,
      mediaType: MediaType.group,
      sourceId: 1,
      favorite: false,
      url: null,
    );

Channel _serie(String name) => Channel(
      name: name,
      mediaType: MediaType.serie,
      sourceId: 1,
      favorite: false,
      seriesId: 99,
    );

void main() {
  group('PlaybackPlaylist.neighborIndex (fix397)', () {
    test('ESPN-like list: open #4, channel down/up moves within the list', () {
      final pl = PlaybackPlaylist(
        channels: List.generate(12, (i) => _live('ESPN $i')),
        index: 3, // the "4th" result
      );
      expect(pl.neighborIndex(1), 4); // down -> 5th
      expect(pl.neighborIndex(-1), 2); // up -> 3rd
    });

    test('wraps at the ends', () {
      final pl = PlaybackPlaylist(
        channels: List.generate(3, (i) => _live('C$i')),
        index: 2,
      );
      expect(pl.neighborIndex(1), 0); // last -> first
      expect(PlaybackPlaylist(channels: pl.channels, index: 0).neighborIndex(-1),
          2); // first -> last
    });

    test('skips non-playable rows (group folders, series folders)', () {
      final ch = [
        _live('A'), // 0
        _group('Movies'), // 1 - skip
        _serie('Show'), // 2 - skip
        _live('B'), // 3
      ];
      final pl = PlaybackPlaylist(channels: ch, index: 0);
      expect(pl.neighborIndex(1), 3); // skips 1 and 2, lands on B
      expect(PlaybackPlaylist(channels: ch, index: 3).neighborIndex(1), 0);
    });

    test('skips url-less entries', () {
      final ch = [_live('A'), _live('B', url: null), _live('C')];
      expect(PlaybackPlaylist(channels: ch, index: 0).neighborIndex(1), 2);
    });

    test('single playable channel -> no neighbour', () {
      final ch = [_group('X'), _live('only'), _serie('Y')];
      final pl = PlaybackPlaylist(channels: ch, index: 1);
      expect(pl.neighborIndex(1), isNull);
      expect(pl.neighborIndex(-1), isNull);
      expect(pl.hasSurfableNeighbor, isFalse);
    });

    test('empty / out-of-range / zero direction -> null (no crash)', () {
      expect(PlaybackPlaylist(channels: const [], index: 0).neighborIndex(1),
          isNull);
      final pl = PlaybackPlaylist(channels: [_live('A'), _live('B')], index: 0);
      expect(pl.neighborIndex(0), isNull);
      expect(PlaybackPlaylist(channels: pl.channels, index: 9).neighborIndex(1),
          isNull);
    });

    test('hasSurfableNeighbor true when >1 playable', () {
      final pl =
          PlaybackPlaylist(channels: [_live('A'), _live('B')], index: 0);
      expect(pl.hasSurfableNeighbor, isTrue);
    });
  });
}
