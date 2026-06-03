# Changelog

All notable changes to Free4Me-IPTV are documented here.
## [v1.25.5+252] - 2026-06-03

**Three fixes:** changelog documentation (fix248) + TV D-pad cell menu (fix250) + TV channel selector focus (fix252).

### Fixed
- **fix248 — Changelog documentation** — Added missing detailed entries for releases 1.25.3 and 1.25.4 to `_changelog` in `whats_new_modal.dart`. These entries now appear in the "Full changelog" history and the "What's new" summary (1.25.4 release notes). Previously both versions fell back to placeholder text. Regenerated `version.json` with 1.25.4 release notes.
- **fix250 — TV D-pad access to cell options menu** — On TV, once all cells in a multi-view grid were filled, the cell options menu (Replace channel / Full screen / Close) became unreachable because it was bound to `onLongPress` (touch only). Added D-pad shortcuts: `select`, `enter`, `gameButtonA`, and `contextMenu` keys now open the cell menu via `FocusableActionDetector`. Also improved the empty-cell "+" button: replaced `FloatingActionButton` with a focusable circular button that autofocuses on cell 0 with visible focus ring and highlights.
- **fix252 — TV channel selector focus** — Channel picker's search field no longer autofocuses, so the first channel tile receives initial D-pad focus. Users can now scroll immediately with the D-pad; pressing UP from the top row moves focus into the search bar (via existing `DpadTextField` traversal). The "UP → search" plumbing already existed; fix252 unblocks it by stopping autofocus trapping.

### Technical
- **fix248**: Two edits to `lib/whats_new_modal.dart` (added 1.25.4 and 1.25.3 changelog entries); regenerated `version.json` via `scripts/update_version_json.py`
- **fix250**: Five edits to `lib/multi_view_cell.dart` (services import, `_CellMenuIntent` class, `_addButtonFocused` state, D-pad shortcuts/actions on filled cells, focusable "+" on empty cells)
- **fix252**: Four edits to `lib/channel_picker_screen.dart` (`autofocus: false` on search field, `autofocus` parameter on `_buildTile`, pass `autofocus: i == 0` at both call sites)
- `flutter analyze --no-fatal-infos` clean (2 pre-existing tolerated INFOs)

---

## [v1.25.4+246] - 2026-06-03

**Two fixes:** EPG auto-match performance (fix244) + multi-view cell self-healing (fix246).

### Fixed
- **fix244 — EPG auto-match scan 1.3s → sub-second** — Partial index `idx_epg_unmatched` on `channels(source_id)` with `WHERE media_type=0 AND epg_manual_override IS NULL AND epg_channel_id IS NULL` turns the unmatched-live-channel scan (runs during EPG refresh) from a `media_type` index scan into a targeted lookup. Pre-verified on a 320k catalog: query time 9.05ms → 2.25ms. Storage overhead negligible (index only covers unmatched rows).
- **fix246 — Multi-view cells self-heal mid-session drops** — After exhausting fast transient retries (5 × 3s), cells now attempt bounded slow recovery: up to 5 re-opens at 60 s intervals, then permanent error UI. Each slow attempt gets a fresh fast budget. Gentle on provider connection limits (important for 4-connection accounts). If the stream recovers and plays stably for 15 s, both budgets reset and it can self-heal again. Cancelled on dispose / channel change. Pre-verified against the TV 2×2 scenario (cells dropped at +22, +28, +56 min).

### Technical
- **fix244**: Migration 19 in `lib/backend/db_factory.dart` (partial index creation)
- **fix244**: Comment-only fix to default doc in `lib/models/settings.dart` (no code behavior change)
- **fix246**: Five edits to `lib/multi_view_cell.dart`: new slow-recovery fields + scheduler; reset on fresh start & stable playback; call scheduler in transient give-up branch
- `flutter analyze --no-fatal-infos` clean (2 pre-existing tolerated INFOs)

---

## [v1.25.3+240] - 2026-06-03

**Bug fix** — "Analyze playback & suggest settings" can recommend values outside the slider range.

### Fixed
- **Analyzer bounds mismatch** — `PlaybackAnalyzer.recommend()` was clamping suggestions to its own hardcoded numbers instead of the settings UI sliders' min/max. Example: `liveCacheSecs` could suggest up to 120 while the slider maxes at 60; `startupGraceMs` could suggest below 100 while the slider floor is 100.
- **Solution** — introduce `SettingBounds` as the single source of truth for all playback setting min/max values; the analyzer now clamps to these bounds, which exactly match the current sliders.

### Technical
- New file: `lib/backend/setting_bounds.dart` (SettingBounds class with 5 pairs of min/max constants)
- Modified: `lib/backend/playback_analyzer.dart` (import SettingBounds; 5 clamp sites updated)
- Constants are device-dependent where applicable: `bufferSizeMax` is a getter returning `DeviceMemory.maxBufferSizeMb`
- Future hardening: sliders can be migrated to read their min/max from SettingBounds for guaranteed lock-step (values already match, migration is mechanical)


## [v1.23.29+222] - 2026-06-02

**Diagnostic release** for refresh slowness (supersedes v1.23.28+218, fix220).

### Added
- **Per-closure timing diagnostics** inside write transactions to identify which refresh phase (insert batch / updateGroups / restorePreserve) is slow on-device
- **Raw Xtream response export** to files (`xtream_dump_*.json`) when debug logging is on, allowing exact apples-to-apples sandbox replay of the parse + insert workload
- **One-shot EXPLAIN QUERY PLAN** logging for the two index-sensitive refresh statements (restorePreserve UPDATE and updateGroups UPDATE+correlated-subquery), executed once per refresh, not per row

### Changed
- Dropped fix220's `synchronous=OFF` SQLite pragma experiment (Samsung S25 with fast UFS storage shows the bottleneck is not storage I/O but likely Dart/isolate round-trip overhead, and the durability risk isn't justified)
- Enhanced logging in `Sql.commitWriteBatched`: per-closure timing callback, slow-closure count summary

### Technical
- All changes are diagnostic/logging only; no behavior changes
- New symbols: `Sql.onClosureTimed` callback parameter; `Sql.logRefreshQueryPlans(sourceId)`
- New imports: `dart:io`, `utils.dart` in `xtream.dart`; `dart:io` in `settings_view.dart`
- UI: long-press "Export log file" tile now exports raw Xtream dumps (concatenated) for easier diagnostic collection on phones (separate from the normal log export)
- `flutter analyze --no-fatal-infos` clean (2 pre-existing tolerated INFOs in settings_view.dart only)

### How to use
1. Enable debug logging in Settings
2. Refresh Emjay (and Aniel) — this generates `xtream_dump_*.json` files in the app directory
3. **TAP** "Export log file" to save the normal debug log (unchanged)
4. **LONG-PRESS** "Export log file" to export the raw source dumps concatenated into a single file (diagnostic)
5. Send both the log and the source dumps back — the raw payloads enable true apples-to-apples sandbox replay of the exact parse + insert workload

---
