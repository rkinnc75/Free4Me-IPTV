# Phase 4 — TV Player OSD (Peer2 three-bar) — implementation plan

Owner-approved (2026-07-12) for autonomous implementation. Replaces the flat
top+bottom gradient overlay (`player.dart:_buildTvOverlay`, ~1752) with Peer2's
three-bar anatomy. **Chrome rebuild only — the engine, channel-surf, seek, and
`_navMode` focus model stay untouched.** Doc: `docs/TV_GUI_REDESIGN.md` §4.6.
Risk: HIGH (player.dart = 2549 lines, complex state) → small units, verify each.

## Current structure (baseline, keep working)
`_buildTvOverlay` → `Positioned.fill` → `FocusTraversalGroup` → gradient
`Container` → `Column[topBar, Spacer, if(seekable) _buildOverlayProgress(),
bottomBar]`.
- **topBar**: back · `PlayerChannelNameLabel` · `PlayerEpgNowLabel` (live) · cast · pip
- **bottomBar**: subtitles/audio · surf▲ · rewind · playPause(`_overlayFirstFocus`) ·
  forward · back-to-live(dvr) · surf▼ · aspect · mini-player(live, !tvMode)
- Keys: `_onPlayerKey` — `_navMode` true (overlay open) → return ignored so the
  `FocusTraversalGroup` traverses bar buttons + OK activates; reset auto-hide.
  `_navMode` false → direct D-pad: surf ▲▼ / seek ◀▶ (accel ladder) / OK =
  playPauseReveal. Auto-hide via `_resetOverlayHideTimer`.

## Units (each: implement → test → adversarial review → ship → onn-verify)
### fix713 — Info Bar (unit 1, LOW-MED risk) ← START HERE
Bottom info strip, token-styled (glass surface, `F4Tokens`):
`[logo] [num] [name] [HD/SD badges if available] | NOW <prog> · NEXT <prog> |
<start–end> + progress`. Reuse `PlayerChannelNameLabel`, `PlayerEpgNowLabel`,
`_buildOverlayProgress` (do NOT rewrite their data sources). Mostly a layout move
(topBar name/EPG + progress → a bottom Info Bar card) + token styling. Keep the
back button reachable. Trigger = channel ▲▼ or a single D-pad press (existing
reveal). NO engine/surf/key changes.

### fix714 — Actions Bar (unit 2, MED risk)
The `bottomBar` buttons → `TvFocusable` (accent ring + Peer2 2→8dp elevation lift).
Trigger = long-press D-pad Center/Down (detect via `KeyRepeatEvent`; the existing
playPauseReveal stays for a short press). Subtitle/audio/speed = small positioned
`ListView` card popups. Speed presets {0.25…2.0}. Keep every existing action
(surf/seek/aspect/mini/cast/pip) wired to its current callback.

### fix715 — Channel Bar (unit 3, MED risk)
D-pad Center → horizontal channel list of the current group (reuse the guide's
visible list for consistency); highlight ring on the tuned channel. Layout-driven
stacking: a bottom-gravity `Column` — showing the Channel Bar expands it upward,
pushing the Info Bar up (no coordinate math).

### polish (fold in): auto-hide `F4Motion.osdAutoHide` (5s) + fade-out on `easeOut`.

## KEPT / untouched (verify after each unit)
Engine + buffering; channel-surf (`_surf`, `_onPlayerKey` direct D-pad ▲▼/CH,
`playerKeyAction`); seek progress row + mm:ss + skip chip + seek accel ladder
(fix651); DVR back-to-live; mini-player (`overlay_player_widget.dart`); cast/pip;
`_navMode` + `FocusTraversalGroup` semantics; `_overlayFirstFocus` autofocus.

## Files
`player.dart` (`_buildTvOverlay` + bottom bar); new `lib/player/tv_osd/
{info_bar,channel_bar,actions_bar}.dart`; `player_channel_name_label.dart` /
`player_epg_now_label.dart` (reuse, maybe tokenize); `overlay_player_widget.dart`
unchanged.

## onn verify per unit
Open a channel → OK reveals bars → D-pad traverses buttons / OK activates → surf
▲▼ changes channel → seek ◀▶ works (DVR/VOD) → back exits → auto-hide after 5s.
Do NOT regress the direct-D-pad (non-overlay) path.
