# Changelog

All notable changes to Free4Me-IPTV are documented here.
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
