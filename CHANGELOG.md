# Changelog

All notable changes to Free4Me-IPTV are documented here.
## [v4.1.15+711] - 2026-07-12

**TV GUI — genre stripe visibility (fix708 follow-up).** TV mode only; phone UI unchanged.

### Fixed
- **fix711 — Genre stripe moved to the top edge** — the on-now cell's genre colour tag (fix708) was a left-edge stripe, but on-now cells begin at ~"now", so the stripe landed in the thin sliver under the vertical now-line + its glow and was effectively invisible on-device. Moved it to a full-width 3px **top-edge** stripe, which the now-line never covers, so the genre colour reads clearly.

### Technical
- **fix711**: `tv_guide_view.dart` `_block` — the on-now genre `Positioned` changed from `left:0, top:0, bottom:0, width:3` (vertical left stripe) to `left:0, right:0, top:0, height:3` (horizontal top stripe). Still gated on `isNow`, clipped by the fix705 `Clip.antiAlias`, painted under the title. `test/fix708_genre_test.dart` updated to assert the top-edge geometry. Version → 4.1.15+711.

## [v4.1.14+709] - 2026-07-12

**EPG matching fix — guide empty on all channels (concurrency).** Backend; all platforms.

### Fixed
- **fix709 — Serialize the EPG channel-match phase** — the TV Guide could show "No guide data" on most/all channels even though the EPG had downloaded. Root cause: a multi-source EPG refresh runs sources concurrently (`maxConcurrent=2`), and two channel-match steps at once collided on the `db.sqlite` writer + the WAL **TRUNCATE** checkpoint (an exclusive lock); the SQLITE_BUSY retries exhausted, `matchChannels` threw, and the per-source `catch` swallowed it — leaving that source's channels silently unmatched. (A single-source refresh, with no concurrency, matched 35851/35851 on-device.) This is the recurring trigger behind "works after a manual refresh, empty again after the nightly auto-refresh."

### Technical
- **fix709**: `epg_service.dart` — an in-isolate chained-Future gate (`_matchGate` / `_serializeMatch`) serializes `matchChannels` so no two matches run at once; **downloads stay parallel** (they are already contention-tolerant — retried epg.sqlite writes + a PASSIVE db.sqlite checkpoint, line 378). Only the match's db.sqlite TRUNCATE checkpoint needed serializing. Covers all triggers (manual refresh, background 24h task, launch-if-stale) since they share `refreshAllSources`. In-isolate only, which is where the `maxConcurrent=2` concurrency lives; cross-isolate stays guarded by the app_meta refresh lock + SQLITE_BUSY retries. Gate releases in `finally` (a throwing match can't wedge it). `test/fix709_epg_serialize_match_test.dart` (4): wiring present + gate logic serializes (no overlap, FIFO) + throwing body doesn't wedge. Adversarially reviewed (concurrency-correctness + fixes-bug/regression lenses). Version → 4.1.14+709.

## [v4.1.13+708] - 2026-07-12

**TV GUI redesign — Phase 3 unit 3: guide genre tint.** TV mode only; phone UI unchanged.

### Added / Changed
- **fix708 — Genre colour stripe** — in the TV Guide, the on-now programme cell now shows a small left-edge colour stripe by genre (news / sport / movies / kids / music / docs, with a neutral fallback), so you can spot the kind of show at a glance. Colour is derived per-programme from the XMLTV category (a channel airs many genres through the day, so it's per on-now cell, not per channel). Only shows on channels that carry EPG data.

### Technical
- **fix708**: new `lib/tv/theme/genre.dart` — `normalizeGenre(String? category)` maps free-text XMLTV `Program.category` onto one of the 7 buckets keying `kGenreColors` (case-insensitive substring, most-specific-first, `general` fallback for null/unknown — never guesses a vivid colour); `genreEdgeColor()` returns the bucket's vivid colour. `tv_guide_view.dart` `_block` draws a 3px `Positioned` left-edge stripe on the on-now cell (`if (isNow)`), clipped by the existing `Clip.antiAlias`, painted under the title / over the fix705 progress fill; positioned child, so no layout/size/alignment change. Adversarially reviewed (SHIP; fixed a `'mma'`→`'mixed martial'` false-positive that hit "programma"/"grammar"). `test/fix708_genre_test.dart` (8): normalizer buckets + precedence + false-positive guard + total fallback + edge-colour + guide wiring. Version → 4.1.13+708.

## [v4.1.12+707] - 2026-07-12

**TV GUI redesign — chrome pass: button/dialog/gear focus rings.** TV mode only; phone UI unchanged.

### Added / Changed
- **fix707 — TV chrome focus ring** — the global TV focus ring on buttons, dialogs and the settings gear (Filled / Icon / Text / Outlined buttons) now uses the accent colour (white by default) instead of the old flat yellow, completing the accent-ring language across all TV chrome (tabs fix702, tiles fix703, rails fix704, and now buttons). Phone UI unchanged (all four are gated on `!hasTouchScreen`).

### Technical
- **fix707**: `lib/main.dart` — the 4 `ButtonStyle.side` focused resolvers `Colors.yellow`→`appAccentNotifier.value` (widths 4/3/3/3 kept). Non-const read at theme-build time: accent is white today (no picker UI), so it's visually the intended white ring; a future accent-preset unit adds live reactivity by rebuilding the theme on notifier change. `test/fix704_guide_focus_test.dart`'s "main.dart still yellow" guard retired (that migration is now done); `test/fix707_chrome_accent_test.dart` asserts no `Colors.yellow` + all 4 rings read the notifier + `!hasTouchScreen` gating kept. Version → 4.1.12+707.

## [v4.1.11+706] - 2026-07-12

**TV GUI redesign — Phase 3 unit 4: guide "no guide data" placeholders.** TV mode only; phone UI unchanged.

### Added / Changed
- **fix706 — Never a blank guide row** — channels with no EPG programmes in the window (24/7 loop / VOD-style feeds that carry no XMLTV — common in these bundles) previously rendered an empty grid row that looked broken. They now show a dim full-width **"No guide data"** placeholder. Populated rows are unchanged. (Reordered ahead of the genre-tint unit because it's the higher-value, lower-risk change and is verifiable in the common EPG-sparse state.)

### Technical
- **fix706**: `tv_guide_view.dart` — new `_emptyRowPlaceholder(width)` (a muted `surfaceContainerHighest`@0.35 full-width cell, left-aligned "No guide data", fontSize 11). Added to `_gridRow`'s `Stack` via `if (progs.isEmpty) _emptyRowPlaceholder(c.maxWidth)`. Purely additive — the real-cell `for`-loop and the NOW-line are unchanged, and the collection-if contributes nothing when `progs` is non-empty, so populated rows are byte-identical. No data layer. Version → 4.1.11+706.

## [v4.1.10+705] - 2026-07-12

**TV GUI redesign — Phase 3 unit 2: guide NOW emphasis.** TV mode only; phone UI unchanged.

### Added / Changed
- **fix705 — Guide NOW emphasis** — in the TV Guide: (1) the "now" vertical line now has a soft glow so the current moment reads at 10 feet (colour kept blue/`primary`, deliberately distinct from the white accent focus ring); (2) the on-now programme cell shows a progress-within-cell fill — the elapsed fraction of the show's runtime tints the left portion of the cell a little stronger, a built-in progress bar. Both derive purely from EPG programme times; no new data. HD/SD badges were considered but dropped (the `Program` model has no quality field; a title heuristic would be a separate concern). Guide layout, rail↔grid Y-alignment, :00/:30 snap, live preview, place-memory and the held-OK menu are unchanged.

### Technical
- **fix705**: `tv_guide_view.dart` — `_nowLine` gains a `BoxShadow` (blur = token `nowGlowRadius` 8, spread 0.5, colour `primary`). `_block` wraps the on-now cell content in a `Stack` with a `Positioned.fill(FractionallySizedBox(widthFactor: elapsedFrac))` fill behind the title; `elapsedFrac` guarded against zero/negative duration. `Material.clipBehavior` is `isNow ? Clip.antiAlias : Clip.none` — only on-now cells pay the clip (no per-cell clip layer across the dense grid, protecting scroll fps). Passive-grid `ExcludeFocus` (finding 75) + `onTap: _play(ch)` intact. Adversarially reviewed + on-device scroll-fps checked on the onn. Version → 4.1.10+705.

## [v4.1.9+704] - 2026-07-12

**TV GUI redesign — Phase 3, unit 1: rail focus rings (guide + browse + categories).** TV mode only; phone UI unchanged.

### Added / Changed
- **fix704 — Rail focus ring** — the highlighted rail item on every browsing surface — the TV Guide rail (channel / category / frozen channel column), the browse rail, and the Categories rail — now shows the accent focus ring (white by default), matching the tabs (fix702) and tiles (fix703), instead of the old flat yellow border. This unifies the whole browsing surface on one focus look. Guide layout, rail↔grid Y-alignment, :00/:30 timeline snap, 12/24h clock, dwell-gated live preview, place-memory, and the held-OK (fire-on-release) menu are all unchanged. (The TV button/dialog focus theme in Settings is a separate later pass and still shows the old style for now.)

### Technical
- **fix704**: the three copy-pasted `_FocusTile` rails — `tv_guide_view.dart`, `tv_browse_view.dart`, `tv_categories_view.dart` — ring `Colors.yellow`→`AccentScope.of(context)` (null-safe; falls back to white with no ancestor). Width 3 kept so row itemExtent chrome budgets are unchanged (guide 56px `_rowHeight`). Guide program cells (`_block`) are `ExcludeFocus`/passive and unaffected; guide rail-alignment, held-OK on-release model, and place-memory untouched. The 4 global TV button focus themes in `main.dart` (Filled/Icon/Text/Outlined, `!hasTouchScreen`) remain yellow — deferred to a dedicated chrome pass (needs live-accent reactivity + broad dialog verify). Reviewed adversarially (guide file). Version → 4.1.9+704.

## [v4.1.8+703] - 2026-07-12

**TV GUI redesign — Phase 2 (channel/poster tiles).** TV mode only; phone UI unchanged.

### Added / Changed
- **fix703 — Tile focus** — on TV, a focused channel/movie/series/category tile now shows the accent focus ring (matching the tabs, white by default) and lifts slightly, instead of the old flat yellow border. All the existing tile behavior is unchanged (source-color edge bar, favorite star, category checkbox, D-pad edge-back / arrow navigation, hold-OK menu). The phone UI is untouched.

### Technical
- **fix703**: `channel_tile.dart` — focused-tile ring `Colors.yellow`→`AccentScope.of(context)` (gated on `showSourceEdgeBar`, the TV-only signal; AccentScope sits inside the gated ternary so it is never evaluated on the phone build) + a 1.05× `AnimatedScale` focus lift wrapping the Card on the TV path (phone returns the bare Card). ChannelTile keeps its own FocusNode + specialized key handling (not delegated to TvFocusable, which would risk regressions across 5 screens). Version → 4.1.8+703.

## [v4.1.7+702] - 2026-07-11

**TV GUI redesign — Phase 0 foundation + Phase 1 (top tab bar).** TV mode only; the phone UI is unchanged.

### Added / Changed
- **fix701 — Design foundation (invisible)** — a single design-token tree (`F4Tokens`), a live user-selectable focus accent (`AccentScope`, default white), a shared motion vocabulary, and one focus primitive (`TvFocusable`: an accent focus ring that snaps in and fades out to kill the focus flash, a subtle lift, and the held-OK menu unified onto the safe fire-on-release model). Nothing visible yet — it's the plumbing the rest of the redesign builds on.
- **fix702 — Top tab bar** — the TV top tabs now use the new focus engine: a clean accent ring on the focused tab (replacing the flat yellow border) with a subtle lift; the selected tab keeps its section color. Held-OK still reaches the Live-TV diagnostic / History-clear actions, and a held OK on any other tab still just switches to it.

### Technical
- **fix701**: new `lib/tv/theme/{f4_tokens,accent_scope,f4_motion}.dart` + `lib/tv/focus/{tv_focusable,dpad_repeat_gate}.dart`; `main.dart` attaches `F4Tokens` to `ThemeData.extensions` + installs `AccentScope`. Inert; phone byte-identical.
- **fix702**: `tv_top_tab_bar.dart` `_TabButton` → `TvFocusable` (accent `ringChrome`, section-color pill kept, 600ms held-OK preserved). Version → 4.1.7+702.

## [v4.1.6+700] - 2026-07-11

**Recordings + playback fixes from owner-reported bugs.**

### Added / Changed
- **fix698 — Recording indicator** — the red REC dot now blinks noticeably (was too faint to see), and the Recordings screen refreshes itself while a recording is scheduled or running, so it flips from Scheduled → Recording → Done live without a manual refresh.
- **fix699 — Faster first channel open** — the player now waits for its video surface before starting the stream, avoiding a decoder re-init that could add several seconds to the first time you open a channel.
- **fix700 — Smoother live buffering (optional)** — a new **Live pre-buffer (seconds)** setting (default off) that, when turned on, rides through constant stutter on a slow provider or weak Wi-Fi (and when watching a channel you're also recording) by pausing briefly to build a cushion instead of rebuffering every second. Trades a small delay behind the live edge for fewer interruptions.

### Technical
- **fix698**: `recordings_view.dart` — `_BlinkingDot` 1.0↔0.15 / 450ms; `_RecordingsViewState` quiet 3s poll while any row is transient (cancelled in dispose).
- **fix699**: `mpv_engine.dart open()` — extra un-locked bounded `_waitForTextureId` before `_player.open()` (full-screen only) so mediacodec binds the final surface first (no `vo=null→gpu` restart).
- **fix700**: new `livePrebufferSecs` setting (default 0) → `cache-pause-initial`+`cache-pause-wait` on the mpv live branch (skipped under DVR); mirrors `vodPrebufferSecs` plumbing. Also mitigates watch-while-recording contention (a full playback-from-recording tee is infeasible — mpv can't tail a growing file). Version → 4.1.6+700.

## [v4.1.5+697] - 2026-07-11

**Recordings: completion alert + safe delete of an in-progress recording.**

### Added / Changed
- **fix697 — Recording completion notification (SR backlog item 2)** — when a scheduled recording finishes (or fails), the app now posts a system notification ("Recording complete" / "Recording failed"). It is native and works even when the app is backgrounded or closed — the case a scheduled recording actually finishes in. A matching in-app message also shows if the Recordings screen is open. User-initiated stops don't notify (you're already there).
- **fix697 — Deleting an in-progress recording no longer strands a file (SR backlog item 1)** — a still-recording row now carries its file location, so "Delete + remove file" is offered while recording, and choosing it cleanly removes the partial clip instead of leaving an orphaned file in your gallery.

### Technical
- **fix697**: `RecordingCaptureService.kt` — new `free4me_recording_done` notification channel + `postCompletion()` (id `48000+id`, survives `stopForeground`), fired on natural done/failed and suppressed on user cancel; `deleteOnCancel` + `EXTRA_DELETE_FILE` so the service deletes its own partial after the output stream closes (no open-fd race); output URI now persisted at `status=recording`. `MainActivity.kt` — one-time `POST_NOTIFICATIONS` request (API 33+); `stopCapture` passes `deleteFile`. Dart — `RecordingCapture.stop(deleteFile:)`, `_delete` routes a running-row remove through the native stop, `RecordingStatusJournal.drain()` returns terminal completions for the in-app SnackBar. Version → 4.1.5+697.

## [v4.1.1+693] - 2026-07-10

**Recordings list UX:** blinking record indicator, keep-or-remove-file delete, and a details view.

### Added / Changed
- **fix693 — Recordings-list interactions** — (1) The red record indicator now pulses while a recording is actively in progress (`_BlinkingDot`, fades between full and dim so layout/focus stay stable). (2) Deleting a recording that has a saved file now offers three choices — Cancel / Delete + remove file / Delete, keep file — removing the file via the existing MediaStore delete channel; recordings with no file keep the simple confirm. (3) Long-press (touch) or held-OK (D-pad, reusing the fix607 hold-timer pattern) on a row opens a details sheet showing resolution, duration, bitrate, format, size, and the saved path, read via a new `recordingFileInfo` channel method (MediaMetadataRetriever + MediaStore query).

### Technical
- **fix693**: `recordings_view.dart` (new `_BlinkingDot`, `_RecordingTile` with held-OK+long-press, `_DetailsSheet`; 3-way `_delete`; `_showDetails`), `MainActivity.kt` (`recordingFileInfo` on the recording channel); version → 4.1.1+693. Verified with real `flutter analyze` (Flutter 3.44.5) → "No issues found!".

## [v4.0.7+691] - 2026-07-10

**Correct duration + working seek bar** on converted recordings.

### Fixed
- **fix691 — Zero-base recording timestamps** — after fix690 gave clean audio, the converted MP4 reported a huge bogus duration (e.g. 8:46:42 for a 1-minute clip) and the seek bar was unusable. Live MPEG-TS packets carry the broadcast-clock PTS/DTS (a large value), which was copied straight into the MP4, leaving an ~8-hour start offset. The remux now captures the first packet's DTS (or PTS) as a single global reference and subtracts it from every packet's timestamps before muxing, so the recording starts at ~0. One offset is used for all streams to preserve A/V sync; `AV_NOPTS_VALUE` packets are left untouched. Verified against libavformat on a large-offset TS: start_time went from ~30000s to ~0 with duration intact and audio still clean.

### Technical
- **fix691**: `recording_remux.dart` — global `startTs` offset applied to `pkt->pts`@8 / `pkt->dts`@16 (shallow, already-verified offsets; no deep AVFormatContext field); version → 4.0.7+691. Verified with Dart 3.12.2 + repo `analysis_options` → "No issues found!".

## [v4.0.6+690] - 2026-07-10

**Converted recordings play everywhere:** the re-mux now writes a standards-compliant AAC track, so recordings play in the default Android video player, not only VLC.

### Fixed
- **fix690 — Apply `aac_adtstoasc` when muxing AAC into MP4** — recordings converted fine (fix685–689) and played in VLC, but the stock Android "Video Player" reported *audio codec not supported* (video was fine). Cause: live-TV AAC is ADTS-framed, and our pinned ffmpeg **n6.0** mp4 muxer does not synthesize a valid AudioSpecificConfig (`esds`) from ADTS on its own — it needs the `aac_adtstoasc` bitstream filter (the device `.so` even carries the *"use the audio bitstream filter 'aac_adtstoasc'"* message). Tolerant players (VLC) decode the malformed track; strict ones reject it. Now, for AAC→MP4, the filter is initialised before `write_header` (so the corrected `par_out`/extradata reaches the output stream) and audio packets are run through it. Verified end-to-end against libavformat: filtered output decodes cleanly with a valid `esds`. MKV path and video are unchanged; `[SRDBG]` diagnostics retained.

### Technical
- **fix690**: `recording_remux.dart` — new BSF typedefs (`av_bsf_get_by_name/alloc/init/send_packet/receive_packet/free`, all exported from the vnext `libmpv.so`) + `AVBSFContext` offsets (par_in@24, par_out@32, time_base_in@40, n6.0); send/receive loop with EAGAIN/EOF handling; version → 4.0.6+690. Verified with Dart 3.12.2 + repo `analysis_options` → "No issues found!".

## [v4.0.5+689] - 2026-07-10

**Recording conversion completes:** the last re-mux bug is fixed — `.ts` recordings now become playable `.mp4`/`.mkv` files.

### Fixed
- **fix689 — Pass AVRational to `av_packet_rescale_ts` by value** — fix688 got the re-mux to the packet loop, where fix687's diagnostics then showed `write_frame rc=-22 (after 0 frames)` for every recording. `av_packet_rescale_ts(pkt, AVRational src, AVRational dst)` takes its two time-base rationals **by value**, but the FFI typedef decomposed each `{num,den}` into separate int32 args — the wrong arm64 ABI, which corrupted every packet's pts/dts to `AV_NOPTS_VALUE` and made the first `av_interleaved_write_frame` fail with EINVAL. Verified against libavformat directly: the decomposed call yields `pts=INT64_MIN`, while a by-value `AVRational` rescales correctly, and the full remux of a real H.264+AAC `.ts` then produces a valid MP4. Added an `AVRational` FFI struct and pass both rationals by value.

### Technical
- **fix689**: `recording_remux.dart` — `final class AVRational extends Struct`, `av_packet_rescale_ts` typedef → by-value structs, call site populates reusable src/dst rationals; version → 4.0.5+689. fix687 `[SRDBG]` diagnostics retained. Verified with Dart 3.12.2 + repo `analysis_options` → "No issues found!".

## [v4.0.4+688] - 2026-07-10

**Recording conversion works:** the fix687 diagnostics pinpointed the failure — `.ts` recordings now convert to `.mp4`/`.mkv` as intended.

### Fixed
- **fix688 — Pass the fd to ffmpeg's `fd:` protocol as an option, not in the URL** — fix687's instrumentation showed every re-mux failing at `open_input(fd:N) rc=-22` (`AVERROR(EINVAL)`) for both MP4 and MKV. Verified against libavformat directly: ffmpeg n6.x's `fd:` protocol rejects a URL-embedded descriptor (`fd:N`) and requires the fd via the `fd` **AVDictionary option** with a bare `fd:` URL (stderr: *"Doesn't support pass file descriptor via URL, please set it via -fd"*). Input now uses `avformat_open_input("fd:", opts{fd})`; output moves from `avio_open` to `avio_open2("fd:", …, opts{fd})`. Both confirmed working (open succeeds; `avio_open2` returns 0). fix687's gated `[SRDBG]` diagnostics are retained.

### Technical
- **fix688**: `recording_remux.dart` — new typedefs `avio_open2`/`av_dict_set_int`/`av_dict_free` (all exported from the vnext `libmpv.so`), `_AvOpenInput` dict arg corrected to `AVDictionary**`, `avio_open` removed; version → 4.0.4+688. Verified with the project's Dart 3.12.2 + repo `analysis_options` → "No issues found!".

## [v4.0.3+687] - 2026-07-10

**Recording-conversion diagnostics:** the re-mux still failed on-device (v4.0.2: both MP4 and MKV failed with no visibility). This adds per-step instrumentation so the next attempt reports exactly which libavformat call failed.

### Changed
- **fix687 — Instrument the FFI re-mux** — `_RemuxNative.streamCopy` now returns a short `step rc=<AVERROR>` diagnostic instead of a bare bool, surfaced through the background isolate and logged via the existing gated `[SRDBG]` channel (e.g. `open_input rc=…`, `write_header(mp4) rc=…`, `avio_open rc=…`, `exception: …`). No change to the re-mux logic — pure visibility to locate the v4.0.2 failure. `_processOne` also logs a null `createOutput`.

### Technical
- **fix687**: `lib/backend/recording_remux.dart` — `streamCopy`→`String`, `_copyInIsolate`→`String`, failure tags at every avformat call site; version → 4.0.3+687. Verified with standalone `dart analyze` → "No issues found!".

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
