import 'package:open_tv/models/channel.dart';

/// Tiered channel ↔ EPG ID matcher.
///
/// Tier 1: exact `tvg-id` / `epg_channel_id` match against XMLTV channel map
/// Tier 2: normalized display-name match (strips HD/4K/FHD/SD/+1/dots/case)
/// Tier 3: tvg-id with stripped regional suffix (.us .uk .sxm etc.)
/// Tier 4: unmatched → epgChannelId stays null; user can manually map
class EpgMatcher {
  /// Returns a map of channel.id → matched epg_channel_id.
  /// [channelMap] is the map returned by XmltvParser: epg-id → display-name.
  /// [channels] is the list of live channels for the source.
  static Map<int, String> match(
    Map<String, String> channelMap,
    List<Channel> channels,
  ) {
    // Build reverse lookup: normalized-name → epg-id
    final byNormalizedName = <String, String>{};
    final byStrippedId = <String, String>{};

    for (final entry in channelMap.entries) {
      final epgId = entry.key;
      final displayName = entry.value;
      byNormalizedName[_normalize(displayName)] = epgId;

      // Tier 3: strip regional suffix from the EPG id itself
      final stripped = _stripRegionalSuffix(epgId);
      if (stripped != epgId) byStrippedId[stripped] = epgId;
    }

    final result = <int, String>{};

    for (final ch in channels) {
      if (ch.id == null) continue;

      // Tier 1: exact match on existing epg_channel_id or channel name as id
      if (ch.epgChannelId != null && channelMap.containsKey(ch.epgChannelId)) {
        result[ch.id!] = ch.epgChannelId!;
        continue;
      }

      // Tier 1b: channel name directly matches an EPG id (some providers
      //          store the EPG id as the channel name)
      if (channelMap.containsKey(ch.name)) {
        result[ch.id!] = ch.name;
        continue;
      }

      // Tier 2: normalized display-name
      final normName = _normalize(ch.name);
      final tier2 = byNormalizedName[normName];
      if (tier2 != null) {
        result[ch.id!] = tier2;
        continue;
      }

      // Tier 3: strip suffix from channel name used as id, then look up
      final strippedCh = _stripRegionalSuffix(ch.name);
      final tier3direct = byStrippedId[strippedCh] ?? byStrippedId[ch.name];
      if (tier3direct != null) {
        result[ch.id!] = tier3direct;
        continue;
      }

      // Tier 3b: check if stripping from the normalized name matches
      final normStripped = _normalize(strippedCh);
      final tier3norm = byNormalizedName[normStripped];
      if (tier3norm != null) {
        result[ch.id!] = tier3norm;
      }
      // Tier 4: no match — leave out of result; epg_channel_id stays null
    }

    return result;
  }

  /// Strips quality/variant suffixes and normalizes case + punctuation.
  static String _normalize(String s) {
    return s
        .toLowerCase()
        // Remove common quality tags
        .replaceAll(RegExp(r'\b(hd|fhd|4k|uhd|sd|hevc|h265|h264)\b'), '')
        // Remove +1 / +2 time-shift suffixes
        .replaceAll(RegExp(r'\+\d+'), '')
        // Remove trailing/leading/multiple dots and spaces
        .replaceAll(RegExp(r'[.\-_]+'), ' ')
        // Collapse multiple spaces
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static final _regionalSuffix = RegExp(
    r'\.(us|uk|ca|au|nz|ie|sxm|de|fr|es|it|nl|be|se|no|dk|fi|pl|pt|br|mx)$',
    caseSensitive: false,
  );

  static String _stripRegionalSuffix(String id) =>
      id.replaceFirst(_regionalSuffix, '');
}
