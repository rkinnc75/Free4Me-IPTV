// fix708 (TV GUI redesign, Phase 3 unit 3) — genre tint. Two parts:
//  (1) normalizeGenre(): free-text XMLTV Program.category → one of 7 fixed
//      buckets (keys of kGenreColors), case-insensitive substring, most-specific
//      first, `general` fallback for unknown/null.
//  (2) the on-now guide cell gets a vivid left-edge stripe from genreEdgeColor().
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/tv/theme/f4_tokens.dart';
import 'package:open_tv/tv/theme/genre.dart';

void main() {
  group('normalizeGenre', () {
    test('null / empty / unknown → general (neutral fallback)', () {
      expect(normalizeGenre(null), 'general');
      expect(normalizeGenre(''), 'general');
      expect(normalizeGenre('Cooking'), 'general');
      expect(normalizeGenre('Talk Show'), 'general');
      expect(normalizeGenre('Drama'), 'general');
    });

    test('case-insensitive substring match into each bucket', () {
      expect(normalizeGenre('News'), 'news');
      expect(normalizeGenre('BBC NEWS'), 'news');
      expect(normalizeGenre('News / Current Affairs'), 'news');
      expect(normalizeGenre('Sports'), 'sport');
      expect(normalizeGenre('NBA Basketball'), 'sport');
      expect(normalizeGenre('Premier League Soccer'), 'sport');
      expect(normalizeGenre('Feature Film'), 'movies');
      expect(normalizeGenre('Movie'), 'movies');
      expect(normalizeGenre("Children's / Youth"), 'kids');
      expect(normalizeGenre('Cartoon'), 'kids');
      expect(normalizeGenre('Music / Ballet / Dance'), 'music');
      expect(normalizeGenre('Concert'), 'music');
      expect(normalizeGenre('Documentary'), 'docs');
      expect(normalizeGenre('Nature / Wildlife'), 'docs');
    });

    test('precedence: specific buckets beat the broad movies("film")', () {
      // a kids film reads as kids, not movies
      expect(normalizeGenre("Children's Film"), 'kids');
      // a documentary film reads as docs, not movies
      expect(normalizeGenre('Documentary Film'), 'docs');
      // "sports news" resolves to news (news is checked before sport)
      expect(normalizeGenre('Sports News'), 'news');
    });

    test('no false-positive from bare substrings (review: mma)', () {
      // 'mma' as a bare substring would wrongly hit "programma"/"grammar";
      // the sport key is 'mixed martial' instead.
      expect(normalizeGenre('Programma'), 'general');
      expect(normalizeGenre('Grammar School'), 'general');
      expect(normalizeGenre('UFC 300 (Mixed Martial Arts)'), 'sport');
    });

    test('every returned bucket is a valid kGenreColors key', () {
      for (final c in <String?>[
        null,
        'News',
        'Sport',
        'Movie',
        'Kids',
        'Music',
        'Docs',
        'Random'
      ]) {
        expect(kGenreColors.containsKey(normalizeGenre(c)), isTrue);
      }
    });
  });

  group('genreEdgeColor', () {
    test('returns the vivid (first) member of the bucket pair', () {
      expect(genreEdgeColor('News'), kGenreColors['news']!.$1);
      expect(genreEdgeColor('Sports'), kGenreColors['sport']!.$1);
      // unknown → general vivid (never null, never crashes)
      expect(genreEdgeColor(null), kGenreColors['general']!.$1);
      expect(genreEdgeColor('Cooking'), kGenreColors['general']!.$1);
      expect(genreEdgeColor('News'), isA<Color>());
    });
  });

  group('guide wiring', () {
    final guide = File('lib/tv/tv_guide_view.dart').readAsStringSync();
    test('imports the genre helper', () {
      expect(guide.contains('tv/theme/genre.dart'), isTrue);
    });
    test('on-now cell draws a 3px genre TOP-edge stripe (fix711)', () {
      expect(guide.contains('if (isNow)'), isTrue);
      expect(guide.contains('genreEdgeColor(p.category)'), isTrue);
      // fix711: full-width TOP-edge stripe (was a left-edge stripe hidden under
      // the now-line). left+right:0 + top:0 + height:3.
      expect(
          guide.contains('right: 0,') &&
              guide.contains('top: 0,') &&
              guide.contains('height: 3,') &&
              guide.contains('Container(color: genreEdgeColor(p.category))'),
          isTrue);
      // the old left-edge form (width:3 vertical stripe) is gone
      expect(guide.contains('width: 3,\n                    child: Container(color: genreEdgeColor'),
          isFalse);
    });
  });
}
