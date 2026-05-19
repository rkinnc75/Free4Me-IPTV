import 'package:open_tv/models/channel.dart';

/// Outcome of a single match attempt — used internally for telemetry.
enum MatchTier {
  exactId, // already-set epg_channel_id is in the XMLTV map
  nameAsId, // channel name is itself an EPG id
  normalizedName, // exact match after normalization
  strippedSuffix, // after stripping regional suffix (.us, .uk, …)
  tokenSuperset, // channel-name tokens ⊇ EPG-name tokens
  jaccard, // best Jaccard overlap above threshold
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

  int get matched =>
      counts.entries.where((e) => e.key != MatchTier.none).fold(0, (s, e) => s + e.value);

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
///   6. Jaccard token-overlap ≥ 0.6 — best candidate among all EPG names
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

      // 5. Token-superset: channel name contains every word of an EPG name
      final chTokens = _tokens(normName);
      if (chTokens.isNotEmpty) {
        String? bestId;
        int bestEpgSize = 0; // prefer longest (most specific) EPG name
        for (var i = 0; i < epgTokens.length; i++) {
          final epgT = epgTokens[i];
          if (epgT.isEmpty) continue;
          if (epgT.length > chTokens.length) continue;
          if (epgT.every(chTokens.contains)) {
            // Take the EPG name with the most tokens — "espn 2" beats "espn"
            if (epgT.length > bestEpgSize) {
              bestEpgSize = epgT.length;
              bestId = epgIds[i];
            }
          }
        }
        if (bestId != null) {
          result[ch.id!] = bestId;
          record(MatchTier.tokenSuperset);
          continue;
        }
      }

      // 6. Jaccard fallback — keep best score above threshold
      if (chTokens.isNotEmpty) {
        String? bestId;
        double bestScore = 0;
        for (var i = 0; i < epgTokens.length; i++) {
          final epgT = epgTokens[i];
          if (epgT.isEmpty) continue;
          final inter = chTokens.intersection(epgT).length;
          if (inter == 0) continue;
          final union = chTokens.union(epgT).length;
          final score = inter / union;
          if (score > bestScore) {
            bestScore = score;
            bestId = epgIds[i];
          }
        }
        if (bestId != null && bestScore >= _jaccardThreshold) {
          result[ch.id!] = bestId;
          record(MatchTier.jaccard);
          continue;
        }
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
}
