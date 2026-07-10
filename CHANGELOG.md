# Changelog

All notable changes to Free4Me-IPTV are documented here.
## [v4.0.2+686] - 2026-07-10

**Recording conversion now actually runs:** the fix685 re-mux was silently skipped for every recording; this makes `.ts` → `.mp4`/`.mkv` conversion fire as intended.

### Fixed
- **fix686 — Re-mux skip guard used the wrong path shape** — fix685 wired the FFI re-mux but `_processOne` gated on `outputPath.endsWith('.ts')`. Captured recordings are MediaStore entries whose `output_path` is a `content://` URI, which never ends in `.ts` (only the display name does), so the guard skipped **every** recording — confirmed on v4.0.1 (`remux: id=17 skip … path=content://media/external_primary/video/media/1000062227`), leaving the file a `.ts`. Removed the suffix test: `RecordingStatusJournal.drain()` already calls `process()` only for ids the native service flagged `"remux":true` on a fresh capture, so `status==done` + non-null path is the correct, sufficient guard. Container choice remains codec-probed (not extension-based), so nothing downstream assumed `.ts`.

### Technical
- **fix686**: one-guard fix in `lib/backend/recording_remux.dart` (`_processOne`); version → 4.0.2+686. Verified with a standalone `dart analyze` → "No issues found!".

## [v4.0.1+685] - 2026-07-10

**Scheduled Recording re-mux (works at last):** captured `.ts` recordings are now repackaged into a real `.mp4` (or `.mkv`) container when the re-mux option is on — no re-encode, no quality loss.

### Fixed
- **fix685 — App-side FFI re-mux of scheduled recordings** — The fix671 native MediaExtractor/MediaMuxer re-mux was a dead end: Android's extractor cannot parse these live-TV `.ts` streams (`Failed to instantiate extractor`), so re-mux always failed and the recording stayed a `.ts`. Re-mux now runs in Dart via FFI over the FFmpeg (libavformat n6.0) symbols exported by the v4.0.0 custom `libmpv.so` (muxer allowlist added in the vnext libmpv build). After a capture finishes, the native service records that re-mux was requested; on the next Recordings load, Dart stream-copies the `.ts` into MP4 (h264/hevc + aac/mp3) or falls back to MKV, then deletes the `.ts`. Fully fail-open — any failure keeps the original `.ts`, so a recording is never lost. The heavy copy runs in a background isolate; MediaStore access and DB writes stay on the UI isolate (single-writer invariant from fix681 preserved).

### Technical
- **fix685**: app-side re-mux over exported libavformat, no NDK / no JNI shim baked into libmpv
  - New `lib/backend/recording_remux.dart` — Dart FFI bindings to 22 libavformat/avio functions in `libmpv.so`; stream-copy demux→mux via the ffmpeg `fd:` protocol. Struct offsets pinned to n6.0 (LP64), guarded at runtime by `avformat_version()` major == 60 (ABI drift → abort, keep `.ts`).
  - `RecordingCaptureService.kt` — removed the dead `remuxToMp4`/`abort` (MediaExtractor/MediaMuxer) path and imports; capture now always finishes on the `.ts` and journals `"remux": true` when requested.
  - `MainActivity.kt` — added `remuxOpenRead` / `remuxCreateOutput` / `remuxFinalize` / `remuxDiscard` / `remuxDeleteTs` / `remuxCloseFd` on the `me.free4me.iptv/recording` channel, handing MediaStore fds to Dart.
  - `recording_status_journal.dart` — `drain()` collects re-mux-flagged `done` ids and invokes `RecordingRemux.process` after the DB is current.
  - `pubspec.yaml` — added `ffi: ^2.1.0`; version → 4.0.1+685.

## [v1.25.7+256] - 2026-06-04

**Per-source channel order toggle:** preserve provider order vs sort alphabetically.

### Fixed
- **fix256 — Per-source provider channel order toggle** — Providers like Z2U (barfik.org) ship channels in curated order using inline headers (e.g. `#### ABC ####` → ABC Alabama → ABC Alaska). After import, headers floated to the top (they sort first alphabetically), breaking the intended interleave. Now captures the provider's order (Xtream `num` field or M3U line sequence) in `channels.provider_order`, and adds a per-source 'Use provider channel order' toggle in the source edit dialog that switches between provider order and alphabetical (default). Browse views (Live / Movies / Series / All) sort per-source mode; existing sources unaffected (default alphabetical). Migration 20 adds `channels.provider_order INTEGER` and `sources.sort_mode TEXT`.

### Technical
- **fix256**: 12-part systematic fix across 8 files
  - Migration 20: `channels.provider_order` + `sources.sort_mode` columns (`lib/backend/db_factory.dart`)
  - Parser: `XtreamStream.providerNum` from `num` field (`lib/models/xtream_types.dart`)
  - Models: `Channel.providerOrder` + `Source.sortMode` (`lib/models/channel.dart`, `lib/models/source.dart`)
  - Import: `xtreamToChannel` sets `providerOrder`; both `insertChannel` (M3U) and `insertChannelsBulk` (Xtream CRITICAL) write `provider_order` (`lib/backend/xtream.dart`, `lib/backend/sql.dart`)
  - M3U: line-sequence counter passed to `getChannelFromLines` → `providerOrder` (`lib/backend/m3u.dart`)
  - Read: `rowToChannel` maps column 19; `rowToSource` maps column 11 (`lib/backend/sql.dart`)
  - Sort: browse `ORDER BY` mode-aware via correlated subquery on `sources.sort_mode` (`lib/backend/sql.dart`)
  - Persist: `updateSource` writes `sort_mode`; also fixes latent color-wipe bug (omitted color in edit) (`lib/backend/sql.dart`)
  - UI: toggle "Use provider channel order" in edit dialog; state management + color preservation (`lib/edit_dialog.dart`)
- `flutter analyze --no-fatal-infos` clean (2 pre-existing tolerated INFOs)

---

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
