import 'package:flutter/material.dart';
import 'package:open_tv/tv/theme/f4_tokens.dart';

/// fix708 (TV GUI redesign, Phase 3 unit 3) — genre normalizer.
///
/// There is no per-channel genre in the data model (a locked product decision:
/// the browse rail shows the provider's own categories, not curated genres).
/// The only genre signal is `Program.category` — a per-programme free-text
/// `String?` from XMLTV. So genre colour is applied **per on-now cell**, and the
/// free-text category must first be normalized onto one of the 7 fixed buckets
/// that key [kGenreColors].
///
/// Case-insensitive substring match, most-specific bucket first. Anything
/// unknown or null falls back to `general` (a neutral slate) — the normalizer
/// never guesses a vivid colour it isn't reasonably sure of.
String normalizeGenre(String? category) {
  if (category == null) return 'general';
  final c = category.toLowerCase();
  bool has(List<String> keys) => keys.any(c.contains);
  // Order matters: specific buckets before the broad `movies` ("film") so a
  // "children's film" reads as kids and a "documentary film" as docs.
  if (has(const ['news', 'current affairs', 'weather'])) return 'news';
  if (has(const [
    'sport',
    'football',
    'soccer',
    'basketball',
    'baseball',
    'hockey',
    'tennis',
    'golf',
    'racing',
    'boxing',
    'wrestl',
    'ufc',
    'mixed martial', // not bare 'mma' — that false-matches "programma"/"grammar"
    'rugby',
    'cricket',
    'olympic',
  ])) {
    return 'sport';
  }
  if (has(const ['kid', 'child', 'cartoon', 'animat', 'youth', 'family'])) {
    return 'kids';
  }
  if (has(const ['music', 'concert', 'ballet', 'dance'])) return 'music';
  if (has(const [
    'document',
    'nature',
    'science',
    'history',
    'biograph',
    'wildlife',
    'educat',
  ])) {
    return 'docs';
  }
  if (has(const ['movie', 'film', 'cinema'])) return 'movies';
  return 'general';
}

/// The left-edge tint colour for an on-now programme cell, from its category.
/// Uses the vivid (`$1`) member of the [kGenreColors] pair.
Color genreEdgeColor(String? category) {
  final pair = kGenreColors[normalizeGenre(category)] ?? kGenreColors['general']!;
  return pair.$1;
}
