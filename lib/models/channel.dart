import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart' show safeModeBlocklist;

class Channel {
  int? id;
  String name;
  int? groupId;
  String? group;
  String? image;
  String? url;
  MediaType mediaType;
  int sourceId;
  bool favorite;
  int? seriesId;
  int? streamId;
  String? epgChannelId;
  /// Non-null when the user explicitly picked this EPG mapping via the
  /// channel-mapping screen. Auto-matched channels have this as null.
  String? epgManualOverride;

  /// Catchup engine: 'default', 'append', 'shift', 'flussonic', 'xc' (xtream).
  /// Null when the channel doesn't support catchup at all.
  String? catchupType;

  /// Provider-specific URL template (M3U `catchup-source`). May contain
  /// placeholders like {Y}, {m}, {d}, {H}, {M}, {S}, {utc}, {duration},
  /// ${start}, ${end}, ${timestamp}.
  String? catchupSource;

  /// How many days back the provider promises catchup will work.
  /// Programs older than this hide the "Watch from beginning" button.
  int? catchupDays;

  /// Per-channel engine override. Null = use source/global/auto selection.
  EngineType? engineOverride;

  /// Unix epoch seconds of last watch event. Null = never watched.
  int? lastWatched;

  /// Result of the most recent StreamScanner probe.
  /// null = never scanned, true = valid media, false = invalid/unreachable.
  bool? streamValidated;

  /// fix256: the provider's intended display order (Xtream `num`, or import
  /// sequence). Null for sources imported before this existed. Used to sort
  /// browse views when the source's sort_mode is 'provider'.
  int? providerOrder;

  /// fix272: true when this channel is a provider "divider" — a name fully
  /// wrapped in '#' (e.g. "##### KIDS NETWORK #####") used as a visual section
  /// header. These have no playable stream; the hide_dividers source toggle
  /// filters them out.
  bool isDivider;

  /// fix300: 1 = adult content (from provider is_adult OR a safeModeBlocklist
  /// name match, computed at import). Drives the unified safe-mode filter.
  bool isAdult;

  /// fix278: for category (group) tiles only — whether the category is enabled
  /// (shown). Null for normal channels. Toggled by the Categories view.
  bool? groupEnabled;

  /// fix272: a name fully wrapped in '#' (after trimming) is a provider
  /// section-divider, not a real channel. Matches "## X ##", "##### X #####",
  /// etc. Does NOT match names that merely contain '#' (e.g. "US (BTN+ 017)").
  static bool nameIsDivider(String? name) {
    if (name == null) return false;
    final s = name.trim();
    return s.length >= 2 && s.startsWith('#') && s.endsWith('#');
  }

  /// fix300: true if [name] or [group] contains any safeModeBlocklist term.
  /// Used at import to bake the hardcoded blocklist into the is_adult column so
  /// every safe-mode filter is a single indexed check.
  static bool nameIsAdult(String? name, String? group) {
    final n = (name ?? '').toLowerCase();
    final g = (group ?? '').toLowerCase();
    for (final t in safeModeBlocklist) {
      final lt = t.toLowerCase();
      if (n.contains(lt) || g.contains(lt)) return true;
    }
    return false;
  }

  Channel({
    this.id,
    required this.name,
    this.group,
    this.groupId,
    this.image,
    this.url,
    required this.mediaType,
    required this.sourceId,
    required this.favorite,
    this.seriesId,
    this.streamId,
    this.epgChannelId,
    this.epgManualOverride,
    this.catchupType,
    this.catchupSource,
    this.catchupDays,
    this.engineOverride,
    this.lastWatched,
    this.streamValidated,
    this.providerOrder,
    this.isDivider = false,
    this.isAdult = false,
    this.groupEnabled,
  });

  /// True iff this channel has any flavor of catchup support.
  bool get supportsCatchup =>
      catchupType != null && catchupType!.isNotEmpty;
}
