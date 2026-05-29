import 'package:open_tv/models/channel.dart';

/// Outcome of a single match attempt — used internally for telemetry.
enum MatchTier {
  exactId, // already-set epg_channel_id is in the XMLTV map
  nameAsId, // channel name is itself an EPG id
  normalizedName, // exact match after normalization
  strippedSuffix, // after stripping regional suffix (.us, .uk, …)
  tokenSuperset, // channel-name tokens ⊇ EPG-name tokens
  callsign, // US K/W callsign substring match in EPG id or display name
  jaccard, // best Jaccard overlap above threshold
  ambiguous, // a fuzzy tier found >1 equally-good candidates — skipped
  none,
}

/// Per-tier counts after running [EpgMatcher.match] — purely informational.
class MatchReport {
  final Map<MatchTier, int> counts;
  final List<String> sampleUnmatched;
  final int totalChannels;

  const MatchReport({
    required this.counts,
    required this.sampleUnmatched,
    required this.totalChannels,
  });

  int get matched => counts.entries
      .where((e) =>
          e.key != MatchTier.none && e.key != MatchTier.ambiguous)
      .fold(0, (s, e) => s + e.value);

  @override
  String toString() {
    final parts = counts.entries
        .where((e) => e.value > 0)
        .map((e) => '${e.key.name}=${e.value}')
        .join(', ');
    return '$matched/$totalChannels matched ($parts)';
  }
}

/// Tiered channel ↔ EPG ID matcher with fuzzy fallbacks.
///
/// In order of preference:
///   1. Existing `epg_channel_id` already valid in the XMLTV map
///   2. Channel name is itself a valid EPG id
///   3. Normalized name exact match (strips HD/4K/+1/country-prefix/etc.)
///   4. Same after stripping regional suffix from id (.us, .uk, .sxm, …)
///   5. Token superset — every word in the EPG display name appears in
///      the channel name (e.g. EPG "ESPN" ⊂ channel "US| ESPN HD")
///   6. US callsign — 4-letter K/W callsign from channel name appears as
///      a substring of an EPG id (catches "KXDF" → "CBSKXDF.us")
///   7. Jaccard token-overlap ≥ 0.6 — best candidate among all EPG names
class EpgMatcher {
  /// Convenience shim for callers that don't care about the report.
  static Map<int, String> match(
    Map<String, String> channelMap,
    List<Channel> channels,
  ) =>
      matchWithReport(channelMap, channels).$1;

  /// Returns ([map of channel.id → epg_channel_id], [report]).
  static (Map<int, String>, MatchReport) matchWithReport(
    Map<String, String> channelMap,
    List<Channel> channels,
  ) {
    // Build reverse lookups
    final byNormalizedName = <String, String>{}; // norm → epg-id
    final byStrippedId = <String, String>{};     // stripped epg-id → original epg-id
    // For fuzzy tiers we keep parallel arrays of normalized names + tokens.
    final epgNorms = <String>[];
    final epgTokens = <Set<String>>[];
    final epgIds = <String>[];

    for (final entry in channelMap.entries) {
      final epgId = entry.key;
      final displayName = entry.value;
      final norm = _normalize(displayName);
      byNormalizedName[norm] = epgId;
      // Also key by the EPG id itself (some feeds reuse names as IDs)
      byNormalizedName.putIfAbsent(_normalize(epgId), () => epgId);

      epgNorms.add(norm);
      epgTokens.add(_tokens(norm));
      epgIds.add(epgId);

      final stripped = _stripRegionalSuffix(epgId);
      if (stripped != epgId) byStrippedId[stripped] = epgId;
    }

    // Inverted token index: token → list of EPG indices whose token set
    // contains it. Built once per call and used by tier 5 (token-superset)
    // and tier 7 (Jaccard) to narrow their candidate set from "all EPG
    // entries" to "EPG entries sharing at least one token with the channel".
    //
    // Correctness note: any EPG entry with zero token overlap with the
    // channel cannot pass tier 5 (subset check requires every EPG token to
    // appear in the channel's tokens — impossible when the EPG token set
    // is non-empty and shares nothing with the channel) AND scores 0 in
    // tier 7 Jaccard. So narrowing to the union of postings lists for the
    // channel's tokens is a strict superset of every candidate that could
    // possibly match, which makes the optimization a no-op on results.
    final tokenIndex = <String, List<int>>{};
    for (var i = 0; i < epgTokens.length; i++) {
      for (final t in epgTokens[i]) {
        (tokenIndex[t] ??= <int>[]).add(i);
      }
    }

    final result = <int, String>{};
    final counts = <MatchTier, int>{};
    final unmatched = <String>[];

    void record(MatchTier tier) =>
        counts[tier] = (counts[tier] ?? 0) + 1;

    for (final ch in channels) {
      if (ch.id == null) {
        record(MatchTier.none);
        continue;
      }

      // 1. Existing epg_channel_id is valid
      if (ch.epgChannelId != null && channelMap.containsKey(ch.epgChannelId)) {
        result[ch.id!] = ch.epgChannelId!;
        record(MatchTier.exactId);
        continue;
      }

      // 2. Channel name is itself an EPG id
      if (channelMap.containsKey(ch.name)) {
        result[ch.id!] = ch.name;
        record(MatchTier.nameAsId);
        continue;
      }

      // 3. Normalized display-name
      final normName = _normalize(ch.name);
      final tier3 = byNormalizedName[normName];
      if (tier3 != null) {
        result[ch.id!] = tier3;
        record(MatchTier.normalizedName);
        continue;
      }

      // 4. Stripped regional suffix on either side
      final strippedCh = _stripRegionalSuffix(ch.name);
      final tier4 = byStrippedId[strippedCh] ??
          byStrippedId[ch.name] ??
          byNormalizedName[_normalize(strippedCh)];
      if (tier4 != null) {
        result[ch.id!] = tier4;
        record(MatchTier.strippedSuffix);
        continue;
      }

      // Rule for every fuzzy tier: if two or more candidates tie for "best",
      // skip the match entirely. Better unmatched than wrong.
      bool fuzzyAmbiguous = false;

      // 5. Token-superset: channel name contains every word of an EPG name.
      // Pick the entry with the MOST tokens (most specific). Skip if there's
      // a tie at the most-specific level.
      //
      // Candidates come from the inverted index: union of postings lists for
      // each channel token. Any EPG entry not in this union has zero tokens
      // in common with the channel and cannot pass the subset check (its
      // token set is non-empty and shares nothing with the channel).
      final chTokens = _tokens(normName);
      if (chTokens.isNotEmpty) {
        final candidates = _candidatesFor(chTokens, tokenIndex);
        String? bestId;
        int bestEpgSize = 0;
        int bestCount = 0;
        for (final i in candidates) {
          final epgT = epgTokens[i];
          if (epgT.isEmpty || epgT.length > chTokens.length) continue;
          if (!epgT.every(chTokens.contains)) continue;
          if (epgT.length > bestEpgSize) {
            bestEpgSize = epgT.length;
            bestId = epgIds[i];
            bestCount = 1;
          } else if (epgT.length == bestEpgSize) {
            bestCount++;
          }
        }
        if (bestCount == 1 && bestId != null) {
          result[ch.id!] = bestId;
          record(MatchTier.tokenSuperset);
          continue;
        } else if (bestCount > 1) {
          fuzzyAmbiguous = true;
        }
      }

      // 6. US callsign — extract 4-letter K/W callsigns from the *original*
      // channel name (preserves uppercase) and look for an EPG id whose
      // lowercased form contains that callsign as a substring. Skip on ties.
      final callsigns = _extractCallsigns(ch.name);
      if (callsigns.isNotEmpty) {
        String? bestId;
        int bestEpgLen = 1 << 30;
        int bestCount = 0;
        for (final cs in callsigns) {
          final csLower = cs.toLowerCase();
          for (final epgId in epgIds) {
            if (!epgId.toLowerCase().contains(csLower)) continue;
            if (epgId.length < bestEpgLen) {
              bestEpgLen = epgId.length;
              bestId = epgId;
              bestCount = 1;
            } else if (epgId.length == bestEpgLen && epgId != bestId) {
              bestCount++;
            }
          }
        }
        if (bestCount == 1 && bestId != null) {
          result[ch.id!] = bestId;
          record(MatchTier.callsign);
          continue;
        } else if (bestCount > 1) {
          fuzzyAmbiguous = true;
        }
      }

      // 7. Jaccard fallback — keep best score above threshold. Skip on ties.
      //
      // Same candidate narrowing as tier 5: any EPG entry with zero token
      // overlap scores Jaccard = 0 and would have been skipped by the
      // `inter == 0` early-out anyway. Iterating the inverted-index union
      // produces the identical set of (score > 0) candidates.
      if (chTokens.isNotEmpty) {
        final candidates = _candidatesFor(chTokens, tokenIndex);
        String? bestId;
        double bestScore = 0;
        int bestCount = 0;
        for (final i in candidates) {
          final epgT = epgTokens[i];
          if (epgT.isEmpty) continue;
          final inter = chTokens.intersection(epgT).length;
          if (inter == 0) continue;
          final union = chTokens.union(epgT).length;
          final score = inter / union;
          if (score > bestScore) {
            bestScore = score;
            bestId = epgIds[i];
            bestCount = 1;
          } else if (score == bestScore) {
            bestCount++;
          }
        }
        if (bestCount == 1 &&
            bestId != null &&
            bestScore >= _jaccardThreshold) {
          result[ch.id!] = bestId;
          record(MatchTier.jaccard);
          continue;
        } else if (bestCount > 1 && bestScore >= _jaccardThreshold) {
          fuzzyAmbiguous = true;
        }
      }

      if (fuzzyAmbiguous) {
        record(MatchTier.ambiguous);
        if (unmatched.length < 10) {
          unmatched.add('${ch.name} (ambiguous)');
        }
        continue;
      }

      // No match
      record(MatchTier.none);
      if (unmatched.length < 10) unmatched.add(ch.name);
    }

    final report = MatchReport(
      counts: counts,
      sampleUnmatched: unmatched,
      totalChannels: channels.length,
    );
    return (result, report);
  }

  static const double _jaccardThreshold = 0.6;

  /// Aggressive normalization for IPTV channel names.
  /// Lowercases, strips country/region prefixes, channel-number prefixes,
  /// quality tags, time-shift suffixes, and most punctuation.
  static String _normalize(String s) {
    var out = s.toLowerCase().trim();

    // Strip leading "[xx]" or "[xxx]"
    out = out.replaceFirst(RegExp(r'^\[[a-z]{2,4}\]\s*'), '');

    // Strip leading country/region prefix: "us|", "usa -", "uk:", "en.", "us "
    out = out.replaceFirst(
      RegExp(
        r'^(us|usa|uk|ca|aus|au|nz|ie|en|fr|de|es|it|nl|be|se|no|dk|fi|pl|pt|br|mx|sxm)\b\s*[|:\-.]?\s*',
      ),
      '',
    );

    // Strip channel-number prefix: "001 - ", "302. ", "12) ", "5 :"
    out = out.replaceFirst(RegExp(r'^\d{1,4}\s*[-.:\)\]]\s*'), '');

    // Remove quality tags anywhere
    out = out.replaceAll(
      RegExp(
        r'\b(hd|fhd|4k|uhd|sd|hevc|h\.?265|h\.?264|hdr|dolby)\b',
      ),
      '',
    );

    // Remove +N timeshift markers
    out = out.replaceAll(RegExp(r'\+\d+'), '');

    // Replace punctuation with space
    out = out.replaceAll(RegExp(r'[.\-_:|/\\()\[\]]+'), ' ');

    // Collapse whitespace
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  /// US TV station callsigns: 4 letters starting with K (west of Mississippi)
  /// or W (east). We require exactly 4 to avoid grabbing network names like
  /// WGN/WWE/MTV/CNN. Also tolerates `-TV` / `-DT` / `-CD` suffixes which the
  /// word boundary handles correctly (the dash is a word boundary).
  static final _callsignRe = RegExp(r'\b[KW][A-Z]{3}\b');

  static List<String> _extractCallsigns(String originalName) {
    return _callsignRe
        .allMatches(originalName)
        .map((m) => m.group(0)!)
        .toList(growable: false);
  }

  static final _stopWords = <String>{
    // Words that are too common to be discriminating in matches
    'tv', 'channel', 'network', 'the',
  };

  /// Tokenize a normalized name into a set of meaningful words.
  static Set<String> _tokens(String norm) {
    if (norm.isEmpty) return const {};
    return norm
        .split(' ')
        .where((t) => t.isNotEmpty && !_stopWords.contains(t))
        .toSet();
  }

  static final _regionalSuffix = RegExp(
    r'\.(us|uk|ca|au|nz|ie|sxm|de|fr|es|it|nl|be|se|no|dk|fi|pl|pt|br|mx)$',
    caseSensitive: false,
  );

  static String _stripRegionalSuffix(String id) =>
      id.replaceFirst(_regionalSuffix, '');

  /// Returns the unique EPG indices whose token sets share at least one
  /// token with [chTokens], using the prebuilt inverted [tokenIndex].
  ///
  /// Used by tiers 5 and 7 to skip EPG entries that have zero token overlap
  /// with the channel — those entries cannot match either tier (see the
  /// correctness notes at each call site).
  static Iterable<int> _candidatesFor(
    Set<String> chTokens,
    Map<String, List<int>> tokenIndex,
  ) {
    final seen = <int>{};
    for (final t in chTokens) {
      final postings = tokenIndex[t];
      if (postings == null) continue;
      seen.addAll(postings);
    }
    return seen;
  }
}
