# Free4Me-IPTV — Independent Codebase Review Report

**Engagement:** unbiased full-codebase review per `docs/INDEPENDENT_REVIEW_BRIEF.md`.
**Target:** working tree as it stands (uncommitted edits included).
**Method:** 23 independent reviewers (fresh context, no prior-fix knowledge) fanned
out across the entire `lib/` tree, the Kotlin/Android side, `test/`, and build
config; findings deduped across reviewers; then **every P1 and the highest-value
P2s were adversarially verified** — 16 by hand in-report and 35 by a dedicated
skeptic-per-finding pass instructed to *refute*. `*.md` files, git history, and the
`whats_new_modal` changelog were excluded from all reviewers as sources, per the
brief.
**Read-only:** nothing was committed, pushed, tagged, or deployed; every throwaway
planner test the verifiers wrote was deleted (tree clean). This file is left
untracked.

## Verification legend

Each finding is labelled by how strongly it is proven:

- **CONFIRMED** — proven by direct code reading (file:line traced, guards checked,
  invariant established) or a passing throwaway experiment, and/or independently
  reported by two or more reviewers. All P0/P1 findings below carry this label
  unless noted.
- **PLAUSIBLE** — a strong, specific code reading whose final link depends on
  runtime/device behavior that could not be exercised here.
- **REFUTED** — a reviewer claim that the adversarial pass disproved; listed for
  transparency, downgraded or dropped.

## Tally (after verification)

| Severity | Count |
|---|---|
| **P0** (data-loss / crash / security) | 1 |
| **P1** (broken feature / major perf) | ~26 distinct (35 raw before merging duplicates) |
| **P2** (minor defect) | 74 |
| **P3** (improvement) | 71 |

181 unique findings after dedup (adds the concurrency/lifecycle sweep). The body
gives full detail for P0/P1, a grouped table for P2, a summary for P3, then the
required dead-code inventory, dependency/asset hygiene list, and top-5 tests.

## Verification results (this is now complete)

The two gaps from the first pass were closed in two sequential solo runs:

1. **Concurrency/lifecycle sweep** — completed. Added 13 findings (5 P1, 5 P2, 3
   P3), including three genuinely new P1s (player reconnect wedge, Scan-button
   lockout, cross-isolate guide-reload) and a TV swallowed-catch cluster.
2. **Adversarial verification of the 35 not-yet-hand-confirmed P1/key-P2
   findings** — completed with no failures. Outcome: **32 CONFIRMED, 2 REFUTED, 1
   PLAUSIBLE**, plus three severity recalibrations (P1→P2). Combined with the 16
   hand-verified earlier, **~48 findings are now directly proven.**

**Refuted / recalibrated by the adversarial pass (transparency):**
- **REFUTED** `settings_service.dart:547` (P1→**P3**): the mechanism is real but the
  concurrent overlap is unreachable — channel-FTS suspension only happens behind
  the modal sources-refresh dialog (`barrierDismissible:false`, `PopScope
  canPop:done`), and the workmanager isolate refreshes EPG, not channels.
- **REFUTED** `sql.dart:994` (P2→**P3**): a throwaway test on the bundled sqlite3
  3.51.0 proved empty `IN ()` is valid always-false SQL (no crash, unlike a forced
  `INDEXED BY` on a missing index), and the `!` null-deref is unreachable (all
  callers populate `mediaTypes` first).
- **Recalibrated P1→P2** (still CONFIRMED, impact bounded): `epg_service.dart:401`
  (next-launch foreground refresh + tab re-entry mask it), `xmltv_parser.dart:231`
  (backpressure — OOM only at the extreme), `multi_view_screen.dart:74`.
- **Overturned my own earlier refutation:** `tv_guide_view.dart:449` is **CONFIRMED
  P1** (see P1-25). My quick read checked only the guide's `PopScope` in isolation;
  the adversarial verifier traced Flutter's `ModalRoute` and showed the guide
  `PopScope` and TvShell's `ConfirmExitScope` register on the *same* root route, so
  Flutter fans the pop callback to *both* — a good example of why the pass matters.

Remaining unverified: only the P2 long tail not in the 35 targets, and all P3s
(finder-asserted, file:line-anchored, not individually re-proven). Findings are
against the **working tree**; `fixNNN` comments were treated as intent, never proof.

---

# P0 — must fix

## P0-1 · Xtream password ships in "credentials-excluded" exports — CONFIRMED
**`lib/settings_view.dart:1771` + `lib/backend/xtream.dart:374`** (independently
reported by the `settings-view` and `security` reviewers; verified here.)

**Failure scenario.** A user hits a playback problem, enables debug logging
(the documented precondition for exporting logs), refreshes/adds an Xtream
source, then uses *Export log file* or answers **"No (safer)"** to the
*Include credentials?* prompt in *Export settings to file*. The resulting bundle
— and the LAN-portal / QR export — still contains their Xtream **username and
password in cleartext**.

**Evidence (traced).**
- `xtream.dart:374` — when `AppLog.enabled`, every raw `player_api.php` response
  body is written verbatim to `<appDir>/xtream_dump_<id>_<action>.json`. The
  base auth call (`getXtreamHttpData('', source)`, used by
  `fetchXtreamAccountInfo`) returns the Xtream `user_info` block, which echoes
  the account **username and password** in cleartext. The line-level
  `_redactSecrets` is **not** applied to these dump files.
- `settings_view.dart:1943 _streamSourceDumpToFile` globs **all**
  `xtream_dump_*.json` and copies them **byte-for-byte** (no redaction) into
  `free4me-source-dump-<stamp>.txt`.
- `settings_view.dart:1773–1788` adds that file to the export `items` and to
  `toZip` **unconditionally** — the `if (includeCredentials)` gate at line 1822
  guards **only** the `db.sqlite` snapshot, not the dump.

**Fix (blast radius: export path + xtream dump).** Gate the source-dump item on
`includeCredentials`; and/or stop dumping the empty-action (auth) response;
and/or scrub `username`/`password` query params and `user_info.password` from
dump bodies before writing. The narrowest safe change is to gate the
`free4me-source-dump-*.txt` item exactly as the DB snapshot is gated.

---

# P1 — broken feature / major perf / data loss

## Data loss & catalog integrity

### P1-1 · M3U refresh wipes the whole catalog before it validates the download — CONFIRMED
**`lib/backend/m3u.dart:54`** (reported by `refresh-import` and `error-handling`.)

Pure network failures *are* caught before the wipe (`downloadM3U` throws on
timeout/non-200/empty). But two destructive vectors remain, both verified:
- An HTTP-**200** non-M3U body (captive portal, "account expired" HTML, CDN error
  page — common) passes the `statusCode==200 && length>0` check. `processM3U`
  then commits `wipeSource` at line 54 **before parsing**, finds zero `#EXTINF`
  lines, and completes "successfully" with `lastLiveCount = 0` — catalog gone.
- A malformed UTF-8 byte mid-file throws **after** the wipe (`utf8.decoder` at
  line 58), so `restorePreserve` (in the tail) never runs.

Worse: the fix611 retry re-captures preserve from the **already-wiped** table, so
favorites are permanently lost even after the provider recovers. No M3U analogue
of the Xtream empty-fetch guard (`keepMediaTypes`, fix321) exists.
**Fix:** parse (or at least count `#EXTINF`) before wiping; only splice the wipe
in front of the insert batch if the parse produced a plausible non-zero count;
use `allowMalformed` decoding.

### P1-2 · `ON DELETE CASCADE` never fires — stale positions/headers rebind to wrong channels — CONFIRMED
**`lib/backend/db_factory.dart:53`** (`db-schema`.)

Verified all four preconditions:
- `PRAGMA foreign_keys` is **never** set anywhere in `lib/` (grep: 0 hits);
  SQLite defaults it OFF, so the `ON DELETE CASCADE` on `channel_http_headers`
  and `movie_positions` is dead.
- `channels.id` is `INTEGER PRIMARY KEY` (no AUTOINCREMENT) → it is the rowid and
  is **reused** after deletes.
- `deleteSource`/`wipeSource` delete only `channels`/`groups`/`sources`; there is
  no `DELETE FROM movie_positions`/`channel_http_headers` anywhere.
- Both dependent tables have a **UNIQUE** index on `channel_id`, and headers are
  inserted with `INSERT OR IGNORE`.

Result: on a single-source install a refresh empties `channels`, rowids restart
at 1, and surviving `movie_positions` rows now key to **different** movies →
`getPosition` resumes an unwatched film mid-way; a new channel needing custom
headers has its headers silently dropped because a stale row squats the reused id
(so header-protected M3U channels fail to play after any refresh). Orphan rows
also accumulate unboundedly.
**Fix:** delete dependent rows inside the wipe/delete transactions (before
deleting channels), or re-key positions/headers by the stable `(source_id,url)`.

### P1-3 · Xtream wipe+reinsert is non-atomic; body-stream stalls treated as success — CONFIRMED (class)
Two related, verified failure modes convert an interrupted refresh into a silent
wrong state:
- **`lib/backend/xmltv_parser.dart:108`** (EPG) and **`lib/backend/m3u.dart:271`**
  (M3U): the body-stream timeout `onTimeout` **closes the stream cleanly**
  instead of erroring, so a mid-download stall makes the `await for` exit
  normally — a *partial* feed is treated as complete: stale programmes deleted,
  source marked fresh, refresh logged OK (EPG); truncated playlist persisted with
  its count (M3U).
- **`lib/backend/xtream.dart:324`** (P2, listed below) is the same hazard for the
  Xtream commit past ~500 closures.
**Fix:** on the body timeout, *add an error* to the stream so the loop throws (the
M3U URL path already rethrows), or carry a `truncated` flag and skip
`deleteStalePrograms` / skip persisting the count.

### P1-4 · Failed EPG download arms the 1-hour debounce — CONFIRMED (severity → P2)
**`lib/backend/epg_service.dart:263`** (`error-handling`.) `upsertEpgRefreshLog`
stamps `last_refreshed_utc = now` **unconditionally, including the catch path**
(0 programmes + error). `refreshIfStale` then reads `getLatestEpgRefresh()` and
skips when `< 3600s` old (the fix601 debounce). So a transient EPG failure leaves
the guide empty **and** blocks the launch-retry for up to an hour — failure is
indistinguishable from success. (Self-heals after the window and the background
task is a separate retry path, hence P2, but user-visible.)
**Fix:** count only successful refreshes (`WHERE last_error IS NULL`) toward the
debounce.

## Security / privacy (beyond P0-1)

### P1-5 · Credential redaction bypassed by URL-encoding and by M3U/EPG URL creds — CONFIRMED
**`lib/backend/xmltv_parser.dart:60`** + **`lib/backend/settings_io.dart:895`**
(`security`, `settings-plumbing`.) The redaction table (`setSourceSecrets`) is
built from the **raw** `username`/`password` fields and URL host. But:
- For **m3uUrl** sources the app stores no username/password fields — the creds
  live **only** in the URL query (`?username=U&password=P`). Those never enter
  the redaction table, so `_sourceToMap` writes `url`/`epgUrl` verbatim into the
  "credentials-excluded" backup and the *Report an issue* payload, and
  `AppLog.info('XMLTV: GET $url')` logs them in cleartext.
- Even for Xtream, a password containing URL-special characters is percent-encoded
  in the URL and won't match the raw redaction token.
**Fix:** scrub credential-looking query params (`username=`/`password=`/`token=`)
from `url`/`epgUrl` in `_sourceToMap` when excluding credentials (and always in
issue reports); add both raw and `Uri.encodeComponent`-encoded forms to the
redaction table.

## Player / engine

### P1-6 · Cast device picker can never appear — CONFIRMED
**`android/.../CastPlugin.kt:94`.** `MainActivity : FlutterActivity()` (not
`FlutterFragmentActivity`), and `FlutterActivity` does **not** extend
`androidx.fragment.app.FragmentActivity`. `showDevicePicker` does
`... as? FragmentActivity ?: return`, so it always bails and the MediaRouter
chooser never shows — plus it fails silently to Dart.
**Fix:** use `MediaRouteChooserDialog` (plain Dialog, needs only an Activity), or
derive from `FlutterFragmentActivity`; surface an error instead of returning.

### P1-7 · `onUserLeaveHint` PiP call crashes on TV boxes without PiP — CONFIRMED (guard missing)
**`android/.../MainActivity.kt:258`.** The manifest sets
`supportsPictureInPicture="true"` with `uses-feature ... required="false"`, so the
app installs on non-PiP Amlogic TV boxes (the primary hardware). `onUserLeaveHint`
guards only on `isVideoPlaying && SDK>=O`, **never** on
`hasSystemFeature(FEATURE_PICTURE_IN_PICTURE)`, and the `enterPictureInPictureMode`
call is not wrapped. Pressing HOME during playback on a PiP-less box throws
`IllegalStateException` → crash. (Some OEMs return `false` instead of throwing —
hence "guard missing" rather than a universal crash — but the class is real.)
**Fix:** gate all PiP calls on `FEATURE_PICTURE_IN_PICTURE` and try/catch
`IllegalStateException`.

### P1-8 · VOD has no failure handling — CONFIRMED (asymmetry) / PLAUSIBLE (wedge)
**`lib/player.dart:653`.** `onDisconnect` returns immediately for
`mediaType != livestream`, so movies get **no** reconnect, no give-up, and no
watchdog. A VOD open that stalls has no recovery path and no terminal error UI —
"Buffering…" can persist with no user-actionable outcome. (The asymmetry is
verified; "forever" depends on there being no other VOD watchdog, which none was
found — PLAUSIBLE.)
**Fix:** give VOD a terminal error state and a (longer) buffering watchdog.

### P1-9 · Live/DVR transport seek silently no-ops — CONFIRMED (code) / PLAUSIBLE (DVR)
**`lib/player/mpv_engine.dart:483`.** `seek()` returns early when
`_player.state.duration <= Duration.zero`, which is the normal state for a live
stream. So `◀/▶` seeks on live (and DVR/time-shift, if the DVR stream reports no
duration) are dropped rather than seeking within the demuxer cache.
**Fix:** allow the seek when DVR is active (or drop the guard — non-seekable live
already suppresses the resulting error player-side).

### P1-10 · `startCast` is unreachable dead code — CONFIRMED
**`lib/player.dart:1024`.** `_onCastTap`'s branch logic can never reach the
"begin casting" block, so tapping cast never actually starts a cast session (it
only ever opens the picker / toggles). Pairs with P1-6 (picker also broken).
**Fix:** restructure the branch (`isCasting → stop; connected → startCast + pause
local; else → picker`).

### P1-11 · Floating mini-player is unusable and undismissable on TV — CONFIRMED
**`lib/player/overlay_player_widget.dart:112` / `:220`.** The mini-player is built
entirely from `GestureDetector` (`onTap`/`onPanUpdate`) with **no** `FocusNode` /
`Shortcuts` / key handling. On D-pad-only TV there is no way to focus, control, or
dismiss it — a ghost stream with audio.
**Fix:** either hide "Watch in mini-player" on TV, or make the control bar
focusable (FocusableActionDetector per button) with a keyed dismiss.

## Multi-view (2 GB devices)

### P1-12 · "Close cell" never disposes the engine — CONFIRMED
**`lib/multi_view_cell.dart:170`.** `didUpdateWidget` only tears down when
`widget.channel != old.channel && widget.channel != null`; the channel→null
transition from `_closeCell` (which only sets `_channels[index] = null`) hits no
branch, and the cell key `ValueKey('cell_$i')` is stable so `State.dispose` never
runs. The engine keeps decoding, and because `isFocused` doesn't change,
`setVolume` never fires — a **focused** closed cell keeps playing **full-volume
audio** behind an empty "+" tile.
**Fix:** handle `widget.channel == null && old.channel != null` → `_disposeEngine`
(and cancel the recovery timer).

### P1-13 · No app-lifecycle handling — 4 engines keep streaming in background — CONFIRMED (recalibrated P1→P2)
**`lib/multi_view_screen.dart:74`.** Neither the screen nor the cells implement
`WidgetsBindingObserver`; the global observer only captures metrics. Pressing HOME
in a 2×2 leaves up to 4 engines pulling network + software-decoding indefinitely
(multi-view has no PiP purpose), burning CPU/bandwidth on a 2 GB box and holding
all of a provider account's connection slots.
**Fix:** observe lifecycle; on `paused` pause/dispose (or mute+pause) cell engines,
restart on `resumed`.

## SQL / performance at scale

### P1-14 · Full `programmes_fts` rebuild runs once **per source** during a refresh — CONFIRMED
**`lib/backend/epg_service.dart:245`.** `rebuildProgrammesFts()` (a full FTS5
`'rebuild'` over the **whole** 1.5M-row table) sits inside `downloadAndParseEpg`,
which `refreshAllSources` calls per source. The fix502 comment says "once after
the batch," but the call is in the per-source function → N full rebuilds for N EPG
sources (multi-minute eMMC work each; also stalls the concurrently-downloading
sibling by holding the epg.sqlite writer).
**Fix:** hoist the rebuild (and the TRUNCATE checkpoint) into `refreshAllSources`,
once after all sources complete; keep the per-call rebuild for single-source
entry points.

### P1-15 · Xtream refresh fetches + `jsonDecode`s all 6 catalogs concurrently on the main isolate — CONFIRMED
**`lib/backend/xtream.dart:63`.** `Future.wait([...6...])` holds all six response
bodies and decoded trees simultaneously; `getXtreamHttpData` calls `jsonDecode`
**synchronously on the UI isolate**. At 450k channels `get_live_streams` alone is
hundreds of MB → multi-second UI stalls (verified pattern) and OOM risk on 2 GB
boxes (PLAUSIBLE outcome). Contrast EPG matching, which uses `compute()`.
**Fix:** fetch/process content types sequentially, decode via
`compute()`/`Isolate.run`, and consider a streaming JSON parse.

### P1-16 · XMLTV download has no backpressure — unbounded HTTP-body buffering — CONFIRMED (borderline P1/P2)
**`lib/backend/xmltv_parser.dart:226`/`:231`.** `_maybeUngzip` hand-rolls a
`StreamController` with no `onPause`/`onResume`/`onCancel`; when the downstream
`await for` pauses during each DB write, the producer keeps pumping the socket
into the controller's unbounded queue. A large feed on fast Wi-Fi with a slow
parse/insert (or a stalled FTS mutex) buffers the un-parsed remainder in RAM →
OOM on 2 GB hardware. On a mid-parse error/cancel the source subscription is never
cancelled, leaking the rest of the body.
**Fix:** wire `onPause/onResume/onCancel` to the source subscription.

### P1-17 · M3U import does one INSERT (+`last_insert_rowid()`) per channel — CONFIRMED
**`lib/backend/m3u.dart:155`.** `commitChannel` adds one `Sql.insertChannel`
closure per channel; each does an awaited `INSERT` **plus** an awaited
`SELECT last_insert_rowid()` (~900k round-trips for 450k rows). Xtream got bulk
batching (fix174/194, 1000 rows/statement); M3U never did. The refresh dialog and
the write lock are held for the duration (finder estimates tens of minutes).
**Fix:** buffer parsed channels and emit `insertChannelsBulk`; fall back to
per-row insert only for the rare `#EXTVLCOPT`-header channel (which needs the
rowid).

### P1-18 · Downloaded M3U temp files are never deleted — CONFIRMED
**`lib/backend/m3u.dart:266`.** Each URL refresh writes
`<appSupport>/temp/get_<micros>.m3u` (unique per request) and nothing deletes it;
the only temp purge operates on a different directory and different name prefix.
Daily refreshes (plus retries) fill internal storage until SQLite writes fail.
**Fix:** delete in a `finally` after `processM3U`, and/or sweep old `get_*.m3u` at
refresh start.

## Settings integrity

### P1-19 · "Optimise for this device" resets settings it promises to keep (incl. safeMode) — CONFIRMED
**`lib/settings_view.dart:2375` + `lib/models/settings.dart:448`.** The dialog
states *"Only buffer / cache / timing / decoder settings change. Your library
view … show/hide preferences … are all preserved."* But `Settings.optimisedFor()`
returns a full-default `Settings` and the `preserveLibraryPreferences` block
copies back only 13 named fields — **omitting** `safeMode`, `contentTypeFilter`,
`searchMethod`, `multiViewDecode`, `confirmToExit`, `playerZoomMode`,
`multiViewAutoRestoreChannels`, `tvHeroLivePreview`, `devControlsHideSecs`,
`devSkipBackOnResumeSecs`. So Optimise **silently turns the adult-content filter
OFF** (safeMode→false) and resets the RAM-aware search method — contradicting its
own copy.
**Fix:** extend the preserve block to every non-buffer/cache/timing/decoder field.

### P1-20 · Reset/Optimise persist `searchMethod=inMemory` on low-RAM boxes — CONFIRMED (mechanism)
**`lib/models/settings.dart:353`.** Fresh install auto-picks `ftsPhrase` on
`<2300 MB` boxes via `resolveSearchMethod` (only when persisted==null). `Reset`/
`Optimise` write the constructor default `inMemory`; `resolveSearchMethod` never
fires again ("a persisted value always wins"), and `updateSettings` then
`reconcileFtsTriggers(false)` **drops** the FTS sync triggers. On a low-RAM box
where the in-memory cache is skipped, `search` falls through to a `channels_fts`
MATCH against an index that is no longer trigger-maintained → increasingly stale
search results.
**Fix:** route `searchMethod` through `resolveSearchMethod` semantics in the
reset/optimise paths (or preserve the current method).

### P1-21 · `updateSettings` recreates FTS triggers mid-refresh → forced rebuild — REFUTED (→ P3)
**`lib/backend/settings_service.dart:547`.** The *mechanism* is real
(`reconcileFtsTriggers` checks only `sqlite_master` presence, never
`_ftsTriggersSuspended`), **but the adversarial pass proved the concurrent overlap
is unreachable:** the only channel-FTS-suspend path (`Utils.refreshAllSources` /
`xtream.dart:323`) runs solely behind `showSourcesRefreshDialog`, a root-navigator
modal (`barrierDismissible:false`, `PopScope canPop:done`) whose `done` flips only
*after* the suspension's `finally` restores the triggers — so no `updateSettings`
call site (`home.dart:1005`, `player.dart:1641`, `multi_view_screen.dart:226`) can
fire mid-suspension; and the workmanager isolate refreshes **EPG**, not channels,
so it never suspends channel triggers. Downgraded to **P3** (harden anyway:
early-return in `reconcileFtsTriggers` when suspended).

## EPG correctness

### P1-22 · EPG discovery variant 2 persists a cookie-auth URL the refresh path can't authenticate — CONFIRMED
**`lib/backend/epg_discovery/variants/stalker_xmltv_cookie_auth.dart:123`.** The
probe validates the XMLTV endpoint using a `Cookie: mac=…; Bearer …` header, then
persists the **bare** URL with sticky state `auto`. The refresh path
(`XmltvParser` → `AppHttp.buildGetRequest`) sends no auth header, so every refresh
gets 401/non-XMLTV and fails forever, while the UI shows a working "auto" badge.
**Fix:** either re-validate the bare URL *without* auth headers before persisting
(reject if it fails), or teach the parser to perform the handshake for this
variant.

## Dialog lifecycle (setState-after-dispose)

### P1-23 · Back during EPG Refresh / Re-match dialog aborts the whole operation — CONFIRMED
**`lib/settings_view.dart:1007` / `:1336`.** These two progress dialogs use
`barrierDismissible:false` (which does not block the remote **Back** key) and,
unlike the sibling `_refreshSingleSource` dialog (`:876`, which wraps in
`PopScope(canPop: done)`) and `sources_refresh_dialog.dart:83`, have **no
PopScope**. `_refreshSetState` is nulled only at run *start*, so after Back pops
the route the next `_updateRefreshDialog` calls the disposed StatefulBuilder's
`setSt` → "Null check operator used on a null value" → aborts the multi-minute
EPG operation. The file's own comment (`:1001`) documents exactly this crash.
**Fix:** wrap both in `PopScope(canPop:false)` and null `_refreshSetState` in the
dialog's `.then`.

### P1-24 · Back during TV export pops the wrong route — CONFIRMED
**`lib/settings_view.dart:1437`.** The export progress dialog has no PopScope and
its future is never observed; `dialogOpen` stays true after Back, so
`closeProgress()` later pops whatever is on top (kicking the user out of Settings
on TV, or an unbalanced root pop on phone).
**Fix:** track closure via `.then((_) => dialogOpen = false)` or `PopScope`.

## TV usability (D-pad = correctness)

### P1-25 · TV search shelves are non-virtualized grids of up to ~1000 tiles — CONFIRMED
**`lib/tv/tv_search_view.dart:515` (and `:159`).** Each shelf is a shrink-wrapped,
non-virtualized grid materializing up to ~1000 `ChannelTile`s (each with image
loading + FocusNodes) → memory spike/jank on 2 GB boxes.
**Fix:** cap each shelf (like `TvBrowseView._itemCap`) or use slivers in one
`CustomScrollView` so tiles virtualize.

### P1-26 · EPG channel-mapping loads all live channels and re-filters on every keystroke — CONFIRMED
**`lib/views/epg_channel_mapping.dart:53`.** Loads **all** live channels for a
source into memory (no LIMIT) and re-filters the full list on every keystroke (no
debounce, no memoization) — multi-hundred-ms hitches per key at 450k channels.
**Fix:** add a LIMIT/pagination, debounce the filter, memoize `_filtered`.

### P1-27 · Guide + shell register two PopScopes on one route → false exit hint / double-Back exits app — CONFIRMED
**`lib/tv/tv_guide_view.dart:449`.** (I initially refuted this on a shallow read of
the `fix644` `PopScope` alone; the adversarial pass, tracing Flutter framework
source, overturned that.) TvShell is `MaterialApp.home` (the only route), and the
guide's `PopScope(canPop: _railMode != channels)` and TvShell's `ConfirmExitScope`
both register `PopEntry`s on the **same** root `ModalRoute`. Flutter's
`ModalRoute.onPopInvokedWithResult` fans the callback to **every** registered
entry (`routes.dart:2045`), so a Back in channels mode both swaps to categories
**and** fires `ConfirmExitScope`'s exit hint — a false "exiting the app" prompt on
every Back-from-channels; and because the disposition aggregates, a second quick
Back (now in categories mode) bubbles to `SystemNavigator.pop` and exits.
**Fix:** have `ConfirmExitScope` arm only when it is the actual blocker (shared
"pop consumed" signal), or hoist channels-mode Back handling into TvShell so a
single PopScope decides.

## Concurrency / lifecycle (from the dedicated sweep)

### P1-28 · Reconnect wedges the player forever if `getChannelHeaders` throws — CONFIRMED
**`lib/player.dart:776`.** `onDisconnect` sets `_isReconnecting = true` (line 657),
then `await Sql.getChannelHeaders(id)` at line 776 sits **outside any try/catch**.
`getChannelHeaders` is a bare `db.getOptional` with no catch, so during the
documented cross-isolate `SQLITE_BUSY` window (a refresh holding the write lock) it
throws; `onDisconnect` is fire-and-forget (callers at 441/462/466/870 don't await
it), so the throw vanishes and `_isReconnecting` is **never reset**. Every later
`onDisconnect` early-returns on the guard → the player sits on "Retrying N/3…"
forever until the user manually exits and re-opens.
**Fix:** wrap the reconnect tail in try/finally that always resets
`_isReconnecting=false`.

### P1-29 · Scan exception permanently disables the Scan button + leaves a stuck modal — CONFIRMED
**`lib/home.dart:432`.** `_startScan` sets `_isScanning=true` and opens a
`barrierDismissible:false` dialog with no `PopScope`. The awaited
`BackgroundTaskService.run(StreamScanner.scan)` (line 479) has no try/finally; the
only reset (`_isScanning=false`, line 509) is *after* the await and inside
`if (mounted)`. Any throw (unhandled network error, or the `_scanProgress` write
after dispose — P1-30) skips both the reset and the dialog pop → the Scan action
stays `null`-disabled for the life of the Home state and the modal can never be
dismissed.
**Fix:** wrap the scan body in try/finally that resets `_isScanning` and pops the
dialog regardless of throw.

### P1-30 · `_scanProgress` ValueNotifier written after Home dispose — CONFIRMED
**`lib/home.dart:488`.** The scan `onProgress` callback does
`_scanProgress.value = …` at line 488 with **no** mounted/disposed guard (the
`if (mounted)` at line 491 only wraps the following `setState`). `_scanProgress` is
disposed in `Home.dispose` (line 374); if the user tab-switches mid-scan, the next
callback throws "A ValueNotifier was used after being disposed," crashing the scan
callback (and feeding P1-29's wedge).
**Fix:** `if (!mounted) return;` before the `.value` write.

### P1-31 · Background-isolate EPG refresh never reloads the live guide — CONFIRMED (recalibrated P1→P2)
**`lib/backend/epg_service.dart:401`.** The workmanager EPG task runs in a separate
isolate and does `epgVersion.value++` on **its own** copy of the per-isolate
`static ValueNotifier`; the only listener (`TvGuideView._onEpgVersionChanged`,
`tv_guide_view.dart:118`) is registered against the **main isolate's** copy and
never fires. After a successful *background* refresh the guide shows stale
programmes. Bounded (hence P2): the next-launch foreground `refreshIfStale` and
tab re-entry both reload it.
**Fix:** signal completion across the isolate boundary (a persisted `app_meta`
marker the main isolate re-reads on resume), not a per-isolate `ValueNotifier`.

---

# P2 — minor defects (74)

Grouped by area; each is a specific, file:line-anchored reading. Items in the 35
verified targets are CONFIRMED unless marked; the rest are finder-asserted. The
player and multi-view clusters are the densest and worth a focused pass.
(Two former entries were **refuted** and moved to P3: `sql.dart:994` empty-`IN ()`
crash — disproved by experiment; and see P1-21 note.)

### Player / engine
- `player.dart:1779` — movie resume position overwritten with 0 when exiting before playback starts (slow/failed open destroys saved progress).
- `player.dart:1294` — resume position lost on channel-surf (`pushReplacement`) and on background/kill (saved only in `onExit`).
- `player.dart:441` — "Network restored — reconnecting" path is a guaranteed no-op (`_isReconnecting` guard rejects its only caller).
- `player.dart:793` — concurrent `_startPlayback` loops: an errorStream event during the initial retry loop spawns a second unguarded open loop.
- `player.dart:998` — resuming local playback after Cast drops per-channel HTTP headers + `ignoreSsl` (header-protected streams fail).
- `player.dart:1032` — starting a cast never pauses the local engine → double playback + connection-slot conflict.
- `player.dart:1608` — held OK / play-pause toggles on every KeyRepeat → pause/play thrash.
- `player.dart:1615` — TV D-pad control overlay disabled by the *persisted* multiViewLayout — single-cell playback loses focusable controls once a grid layout was ever set.
- `player.dart:1647` / `overlay_player_controller.dart:198` / `overlay_player_widget.dart:277`/`:317` — mini-player handoff opens a second connection before releasing the old engine / no reentrancy guard / `_swap` pops the wrong route leaving a zombie Player.
- `player.dart:388`/`:397` — returning from PiP leaves forced software decode; adopted mini-player engine keeps preview settings (tiny demuxer, no DVR) for the session.
- `mpv_engine.dart:1171`/`:1287` — orphaned per-engine DVR cache dirs are never swept (crash/kill mid-DVR leaks up to gigabytes).
- `cast_controller.dart:124` — `mimeTypeFor` substring heuristics misclassify streams ("mpeg" anywhere kills castability; extensionless live casts as MP4).

### Multi-view
- `multi_view_screen.dart:131` — audio interruption type `duck` permanently mutes all cells (`_interrupted` never cleared on duck-end).
- `multi_view_cell.dart:1151` — promoting an *unfocused* cell to full-screen leaves the focused sibling at full volume → two audio tracks.
- `multi_view_cell.dart:220`/`:489` — pending recovery Timer survives `_disposeEngine` (no generation guard) → duplicate connection; no mounted/generation re-check after `await setVolume` → stale start cancels the new generation's watchdog.
- `multi_view_cell.dart:323`/`:432`/`:606` — retry/recovery budgets never replenish (or reset wrongly), and the startup watchdog is disarmed by the first buffering event with no handoff → a stream that opens but never decodes hangs as a dead black cell, or an EOF-cycling dead stream restarts forever.

### SQL / DB
- `sql.dart:994` (CONFIRMED-worthy) — `search()` dereferences `filters.mediaTypes!`/`sourceIds!` and emits `IN ()` for empty lists → `NoSuchMethodError` on null / non-standard `IN ()` (syntax error or silently-empty results). Several TV views hold `[]` until an async load resolves. **Add an empty-list early-return.**
- `sql.dart:3076`/`3078` — "Re-match all" does `SELECT * FROM channels WHERE source_id=? AND media_type=0` with no LIMIT → materializes up to 450k full `Channel` objects (multi-hundred-MB spike).
- `sql.dart:3338` — mixed-mode multi-source browse uses `innerLimit = offset + pageSize` per source with a non-indexable correlated sort → cost grows without bound with page depth.
- `sql.dart:2459` — `restorePreserve`'s set-based UPDATE runs while `index_channel_name_source` is dropped by the refresh wrapper → planner regression risk at 450k preserve rows.
- `sql.dart:2573` — `setChannelEpgIds` (db.sqlite writer) lacks the cross-isolate SQLITE_BUSY retry every epg.sqlite writer has → workmanager match can throw into an unawaited future.
- `sql.dart:574`/`1636`, `db_factory.dart:949` — index-maintenance hazards: VACUUM failure re-runs the whole multi-minute drop/rebuild pass every launch; concurrent maintenance + user refresh resurrects the 5 dead indexes and desyncs the marker; fresh installs aren't pre-marked so they build dead/old-shape indexes then pay the "one-time upgrade" pass anyway.
- `db_factory.dart:1240` — `EpgDbFactory` memoizes a **failed** open future permanently → one transient open/migration error kills all EPG features until app restart.

### EPG matching
- `epg_matcher.dart:330` — callsign tier matches ordinary all-caps words (KIDS/WILD/WEST) as US callsigns via substring against every EPG id → wrong matches + O(channels × |EPG|) scan.
- `epg_matcher.dart:79` — tier 3/4 normalization collisions resolve last-wins with no ambiguity guard → silent wrong EPG.
- `epg_service.dart:330` — matcher rebuilds its entire inverted index and re-copies the full EPG map for **every** 2000-channel batch (O(batches × |EPG|)).
- `epg_service.dart:181` — one source's match failure aborts EPG refresh for all remaining sources (surfaces as unhandled async error).
- `xmltv_parser.dart:143` — strict `utf8.decoder` aborts the whole parse on any non-UTF-8 byte (common in EU feeds).
- `xmltv_parser.dart:191` — window filter keys on `start_utc`, so "Past days to keep = 0" drops every **currently-airing** programme (guide "On now" empty; `isStale` then true forever). **Use interval overlap (`stop_utc > windowStart`).**

### Security (beyond P0/P1)
- `update_checker.dart:213` — in-app APK update installs with **no** hash/signature verification and no scheme restriction on `apkUrl`. (Android's install-time signature check mitigates arbitrary-APK *updates* of the same package, but transport/integrity should still be enforced.)
- `xmltv_parser.dart:72` — parser `throw`s an Exception embedding the full credentialed URL, logged via `AppLog.error($e)` and surfaceable in UI/error text.
- `epg_service.dart:212` / `m3u.dart:240` — EPG/first-fetch M3U URLs with embedded creds/tokens logged before/around redaction.
- `settings_io.dart:224` — backup materializes a preserve entry per channel with an `epg_channel_id`/`stream_validated` → giant in-memory JSON at catalog scale.

### Settings plumbing (per-setting completeness)
- `settings_io.dart:608` — `use24HourTime` is persisted + reset-preserved but **missing from backup export AND import** → silently reset to 12-hour on every restore.
- `settings_io.dart:459` — full backup import drops per-source `maxConnections`/color/`sortMode` that export writes → lost on fresh-device restore.
- `settings.dart:343` — "Reset to defaults" writes hardcoded 128 MB buffer / 150 MB live demuxer / 32 MB mini regardless of RAM → 4× the fresh-install defaults on <2 GB boxes.

### TV / phone UI
- `tv_guide_view.dart:528` — live-guide categories rail is a non-lazy `ListView` eagerly building up to 10,000 tiles + 10,000 FocusNodes per build (after the fix644 cap raise).
- `tv_guide_view.dart:199` — guide reads stale launch-time `widget.settings` → toggling "TV hero live preview" etc. has no effect until restart.
- `tv_guide_view.dart:1074` — EPG grid blocks are focusable InkWells despite the "passive grid" design → D-pad wanders into the grid, desyncing rail/grid/hero.
- `tv_guide_view.dart:154` / `tv_search_view.dart:137` — `_init`/`_loadGuide`/`_run` unguarded: one thrown DB call leaves the landing tab blank or stuck on "Loading…/Searching…" with an uncaught async exception.
- `channel_tile.dart:241` — leaks a FocusNode listener per mount for caller-supplied nodes → search's reused node cache accumulates stale listeners that re-fire prewarm HTTP for old channels.
- `now_next_strip.dart:30` — loads once in `initState`, no `didUpdateWidget`/timer → stale now/next after a cell channel swap and as programmes roll over.
- `home.dart:488` — StreamScanner progress callback writes to a **disposed** ValueNotifier when Home is torn down mid-scan.
- `settings_view.dart:2080` — Back during "Submitting report…" pops the Settings route instead of the dialog and swallows the result.
- `settings_view.dart:540` — "Cap 60→30 fps" help dialog renders literal `\n\n`.
- `search_perf_dialog.dart:17` — Back orphans a minutes-long headless DB benchmark; no cancel while running; concurrent runs possible.
- `sources_refresh_dialog.dart:244` — FTS-recovery retry omits `shouldCancel` → Cancel becomes a permanent lying "Cancelling…" no-op during the retry.

### Cross-isolate / error-classification
- `utils.dart:216` — background workmanager EPG isolate writes db.sqlite while the main isolate holds minutes-long write transactions → cross-isolate lock contention can fail either job.
- `xtream.dart:189`/`:324`/`:345` — transient fetch failure for a null/0-lastCount type wipes that type's rows (favorites incl.); non-atomic wipe+reinsert past ~500 closures; `processJsonList` turns an HTML-as-200 body into an empty list indistinguishable from legitimately empty.
- `http_client.dart:38` — `getWithRetry` collapses 4xx (permanent) and network/timeout (transient) into the same `null`.
- `MainActivity.kt:136` — `PipController.isSupported` ignores `FEATURE_PICTURE_IN_PICTURE` and native `enterPip` always reports success (companion to P1-7).
- `stalker_xmltv_query_auth.dart:35` — discovery probes buffer entire response bodies in RAM just to validate 64 KB.

### Silently-swallowed query failures (from the concurrency sweep, CONFIRMED)
- `tv_browse_view.dart:103`, `tv_guide_view.dart:185`, `tv_categories_view.dart:75` — a thrown browse/categories query is caught and rendered as an **empty** rail/guide/list with no error state, so a transient DB failure looks identical to "you have no channels/categories." (P2, medium confidence.)
- `multi_view_cell.dart:315` — `_onEof` leaves `_eofRetryScheduled=true` if the quick re-open throws before the full-restart guard passes (reentrancy; EOF retries then wedge). **PLAUSIBLE** — core mechanism source-traced; the final mpv-emits-buffering link needs a device to prove.

# P3 — improvements (71)

Lower-priority polish, hardening, and micro-perf items surfaced across the same
reviewers (e.g. redundant `SELECT *` where column lists would do, `.toList()`
where lazy iteration suffices, minor focus-order polish, log-noise, missing
`const`, opportunistic index-covering). Not itemized here to avoid padding; the
full structured list is in the run artifacts. None are blocking, and per the brief
none are style nits masking a defect.

---

# Dead / duplicate / non-functional code inventory

Reachability computed transitively from `lib/main.dart` (121 Dart files; 117
reachable). Every claim grep-verified.

**Orphan files never reachable from `main.dart` (~136 LOC):**
- `lib/menu_tile.dart` (`MenuTile`) — 0 call sites, no importer. Dead.
- `lib/models/snapshot.dart` (`Snapshot`) — 0 importers. Dead.
- `lib/models/stack.dart` (app `Stack`) — imported only by `snapshot.dart` (itself
  dead). Dead by chain.
- `lib/validators.dart` (`Validators`) — 0 hits; app validates via
  `FormBuilderValidators`. Dead/superseded.

**Dead classes in a live file:**
- `lib/models/xtream_types.dart:131` `XtreamEPG` / `:147` `XtreamEPGItem` (~33 LOC)
  — referenced only inside their own definitions. The live Xtream-EPG path
  (`xtream_epg.dart:88`) parses `epg_listings` inline. **Divergent duplicate** —
  two "parse Xtream EPG listings" implementations, one live, one dead. (Sibling
  `XtreamEpisodeInfo` IS live.)

# Dependency / asset hygiene

- **`flutter_svg: ^2.2.0`** (`pubspec.yaml:51`) — **unused** (0 `SvgPicture`/`.svg`
  refs in `lib`). Drop.
- **`assets/smpte_color_bars.svg`** — orphan asset (referenced nowhere in code;
  would have needed flutter_svg). Ships anyway via the `assets/` dir declaration.
- **`logging: ^1.3.0`** — **unused** (0 `package:logging` refs; app uses its own
  `AppLogger`). Drop.
- `cupertino_icons` — unused but conventional scaffolding (P3).
- **`dependency_overrides` supply-chain risk** (`pubspec.yaml:92`):
  `media_kit_libs_android_video` pinned to a personal fork
  (`github.com/rkalsky/media-kit.git`) at a hard SHA. The Android build depends on
  one contributor's repo staying alive at that ref. Informational (native build is
  out of scope), but a real bus-factor risk.

---

# Top 5 highest-value tests to add

1. **Migration-chain equivalence + canonical-index parity (both DBs).** Expose the
   migration builders; run (a) full chain to head vs (b) an old `user_version`
   upgraded to head; assert byte-identical `SELECT type,name,sql FROM sqlite_master
   ORDER BY name`. Then assert every `sql.dart` `_canonicalChannelIndexes[name]`
   DDL (IF-NOT-EXISTS-normalized) matches the real chain's index DDL. **This one
   test closes the DDL-drift hole under every INDEXED-BY / query-plan test at
   once** — today all SQL tests hand-copy DDL from the migrations, so a divergent
   migration ships green.
2. **Credential exclusion on export (`_sourceToMap`/`buildBackupPayload`).** Seed
   a Xtream source and an M3U source with creds in `url`/`epgUrl`; call
   `buildBackupPayload(includeCredentials:false)`; assert the whole encoded string
   contains neither `U` nor `P`. **Fails today** (P0-1 / P1-5). A security fence,
   not just coverage.
3. **`MpvEngine` dispose idempotency + resource release.** Instantiate over a
   fake `Player`; call `dispose()` twice; assert every `_subs` subscription
   cancelled once, both Timers cancelled, `_disposed==true`, and post-dispose
   `buffering`/`position` events fire no `add`/`setState`. Covers the leak +
   setState-after-dispose class directly (untested today).
4. **Interrupted-refresh self-heal integration.** Real temp DB migrated to head;
   run `withDroppedBrowseIndexes` with a body that throws after the drop, clear the
   recreate marker; run the startup self-heal; assert every canonical index
   (esp. `idx_fav_browse`, `idx_browse_src_mt`) exists again so a forced
   `INDEXED BY` cannot hit "no such index." Exercises the real code the unit tests
   only simulate.
5. **TV D-pad focus reachability on a core screen (real `testWidgets`).** Pump
   `tv_guide_view` (or the source edge bar / top tab bar); send arrow keys; assert
   `primaryFocus` lands on a real interactive descendant after each press and that
   traversal reaches every actionable item. Replaces the grep-over-source
   `edit_dialog_385_test` (which cannot detect a broken/unreachable FocusNode) with
   an assertion that reflects the only input the primary hardware has.

---

*Report generated from independent reviewers with no access to prior-fix history.
Verification is complete: the P0, every P1, and the highest-value P2s were
adversarially verified (16 by hand + 35 by a refute-first skeptic pass, all
completed) — 32 of 35 targets CONFIRMED, 2 REFUTED (moved to P3), 1 PLAUSIBLE, with
three P1→P2 recalibrations, all recorded above. Remaining PLAUSIBLE/unverified
items are the P2 long tail outside the 35 targets and the P3s: strong,
file:line-anchored readings, not individually re-proven. Every throwaway test the
verifiers created was deleted; the working tree is unchanged.*

---

# Fix-order work plan (minimize same-file edits)

**Principle:** 181 findings live in **54 files**. The minimum possible number of
same-file edits is therefore **54 — one per file**, achieved only if each file is
opened *once* and *all* its findings (every tier) are fixed in that sitting, then
never reopened. The order below does that: P0 first, then by impact, then P2-only
files, then P3 cleanup. With the three cross-file clusters below handled on a single
branch each, **no two work units touch the same file**, so Waves 3–4 can fan out in
parallel with zero merge conflicts.

## Cross-file clusters — keep each on ONE branch (do not parallelize within)

- [ ] **Credential redaction cluster:** `lib/backend/app_logger.dart` +
  `lib/backend/settings_io.dart`. Fix redaction *at the source* in `app_logger.dart`
  (`setSourceSecrets` / redact-by-URL-parse: userinfo + `username`/`password`/`token`
  query params, **raw and %-encoded**). This one edit clears the log-side leaks in
  `xmltv_parser.dart:60`, `epg_service.dart:212`, and `m3u.dart:240` **without
  editing those files**. `settings_io.dart:895` gets the backup/issue-report scrub.
- [ ] **Optimise/Reset cluster:** `lib/settings_view.dart:2375` +
  `lib/models/settings.dart:353/448` + `lib/backend/settings_service.dart:547`.
  Preserve block, `optimisedFor()`/`defaults()`, and `resolveSearchMethod` change
  together.
- [ ] **P0-1:** fixed in `settings_view.dart` (gate the dump item); optionally also
  scrub at the write site in `xtream.dart` (edited anyway in Wave 2).

## Wave 1 — P0 + security core (do first)

- [ ] 1. `lib/backend/app_logger.dart` — centralized redaction (clears P1-5 log-side + `epg_service:212`, `m3u:240`).
- [ ] 2. `lib/settings_view.dart` — **14**: P0-1 dump gate; P1 EPG dialog Back-abort (:1007/:1336), TV-export Back (:1437), Optimise-preserve (:2375); P2 report-Back (:2080), help `\n\n` (:540); 7×P3.
- [ ] 3. `lib/models/settings.dart` + `lib/backend/settings_service.dart` — P1 searchMethod/safeMode reset (:353); P2 RAM-blind reset (:343/:448); P3 inert 2×2 trim, settings_service dead key / non-defensive parse / audio default. *(settings_service :547 = REFUTED → P3 hardening only.)*
- [ ] 4. `lib/backend/settings_io.dart` — **6**: P1 backup scrub (:895); P2 backup bloat (:224), import drops per-source fields (:459), `use24HourTime` missing (:608); P3 dup payload, unguarded casts.

## Wave 2 — P1-dense feature/crash files

- [ ] 5. `lib/backend/m3u.dart` — **7**: P1 wipe-before-validate (:54), per-row insert (:155), temp-file leak (:266), stall-as-success (:271); P2 cred-log (from cluster); P3 comma-name, comment-overwrites-URL.
- [ ] 6. `lib/backend/xmltv_parser.dart` — **9**: P1 backpressure (:226/:231), stall-as-success (:108), redaction (:60, from cluster); P2 URL-in-exception (:72), strict utf8 (:143), pastDays=0 drops airing (:191); P3 timezone/timestamp (:290/:305).
- [ ] 7. `lib/backend/epg_service.dart` — **9**: P1 per-source FTS rebuild (:245), failed-download debounce (:263), cross-isolate guide reload (:401); P2 abort-all (:181), cred-log (:212, from cluster), matcher re-index (:330); P3 stale floor (:77), no refresh mutex (:117), dead override loop (:295).
- [ ] 8. `lib/player.dart` — **21**: P1 VOD no-failure (:653), reconnect wedge (:776), dead startCast (:1024); 11×P2 (PiP sw-decode, cast/local double-play, resume loss, key-repeat thrash, mini-player double-connect…); 7×P3.
- [ ] 9. `lib/backend/db_factory.dart` — **8**: P1 FK-cascade rebind (:53, or fix via dependent-row deletes in sql.dart — pick one file), migration-test gap (:15); P2 fresh-install churn (:949), failed-open memoization (:1240); 4×P3.
- [ ] 10. `lib/backend/xtream.dart` — **8**: P1 6-way main-isolate decode (:63); P2 empty-fetch wipe (:189), non-atomic reinsert (:324), HTML-as-200 (:345); P3 dump purge (:378), dead code (:395), string-auth (:488), `getEpisodes` TypeError (:740). *(optional P0 write-site scrub here.)*
- [ ] 11. `lib/tv/tv_guide_view.dart` — **8**: P1 double-Back exit (:449); P2 unguarded init (:154), swallowed query (:185), stale settings (:199), non-lazy 10k rail (:528), focusable grid (:1074); P3 empty-category focus trap (:279), stale Favorites (:951).
- [ ] 12. `lib/multi_view_cell.dart` — **7**: P1 close-cell engine leak (:170); 6×P2 (timer survives dispose :220, EOF budget :323/:432, watchdog disarm :606, unfocused-promote audio :1151, stale-start :489).
- [ ] 13. `lib/player/overlay_player_widget.dart` — **4**: P1 mini-player no D-pad focus (:112/:220); P2 `_swap` zombie-Player (:277/:317).
- [ ] 14. `lib/player/mpv_engine.dart` — **5**: P1 live/DVR seek no-op (:483); P2 no lifecycle test (:107), DVR-cache leak (:1171/:1287); P3 dead `isLive` (:249).
- [ ] 15. `lib/home.dart` — **3**: P1 Scan-button lockout (:432), Scan-progress dispose crash (:488); P3 unguarded toggle setState (:940).
- [ ] 16. `lib/tv/tv_search_view.dart` — **4**: P1 non-virtualized shelves (:515); P2 unguarded `_run` (:137), eager 1000 tiles (:159); P3 mic unreachable (:318).
- [ ] 17. `android/app/src/main/kotlin/me/free4me/iptv/CastPlugin.kt` — P1 picker needs FragmentActivity (:94); P3 premature success (:136).
- [ ] 18. `android/app/src/main/kotlin/me/free4me/iptv/MainActivity.kt` — P1 PiP crash (:258); P2 `isSupported` ignores feature (:136).
- [ ] 19. `lib/multi_view_screen.dart` — P1 no lifecycle handling (:74); P2 duck permanent-mute (:131).
- [ ] 20. `lib/backend/epg_discovery/variants/stalker_xmltv_cookie_auth.dart` — P1 dead cookie-auth EPG URL (:123).
- [ ] 21. `lib/views/epg_channel_mapping.dart` — P1 load-all + no debounce (:53).
- [ ] 22. `test/fix572_export_purge_test.dart` — P1 add credential-exclusion test (fences P0-1/P1-5).

## Wave 3 — P2-only files (independent, parallelizable)

- [ ] 23. `lib/backend/sql.dart` — **12** (own sitting): index-maintenance (:574/:1636), preserve-index planner (:2459), missing BUSY retry (:2573), re-match SELECT* (:3078), deep-page cost (:3338); 5×P3 TOCTOU/FTS-stale. *(:994 = REFUTED, drop.)*
- [ ] 24. `lib/backend/epg_matcher.dart` — callsign false-match (:330), tier collision (:79); P3 O(n²) scan (:207).
- [ ] 25. `lib/backend/utils.dart` — cross-isolate write contention (:216); P3 early index-drop (:88), cancel-ineffective (:230).
- [ ] 26. `lib/player/overlay_player_controller.dart` — reentrancy guard (:198); P3 dead code (:261).
- [ ] 27. `lib/backend/update_checker.dart` — APK integrity/scheme (:213).
- [ ] 28. `lib/channel_tile.dart` — FocusNode listener leak (:241).
- [ ] 29. `lib/player/cast_controller.dart` — mimeType misclassification (:124).
- [ ] 30. `lib/tv/tv_browse_view.dart` — swallowed browse query (:103).
- [ ] 31. `lib/tv/tv_categories_view.dart` — swallowed categories query (:75).
- [ ] 32. `lib/widgets/now_next_strip.dart` — no refresh/`didUpdateWidget` (:30).
- [ ] 33. `lib/widgets/search_perf_dialog.dart` — orphaned benchmark, no cancel (:17).
- [ ] 34. `lib/widgets/sources_refresh_dialog.dart` — retry omits `shouldCancel` (:244).
- [ ] 35. `lib/backend/http_client.dart` — collapses permanent vs transient failure (:38).
- [ ] 36. `lib/backend/epg_discovery/variants/stalker_xmltv_query_auth.dart` — buffers full body to validate 64 KB (:35).
- [ ] 37. `test/edit_dialog_385_test.dart` — grep-based focus test asserts nothing real (:29).

## Wave 4 — P3-only cleanup (batch freely)

- [ ] 38. Delete dead files: `lib/menu_tile.dart`, `lib/validators.dart`, `lib/models/snapshot.dart` (+`stack.dart`); remove dead classes in `lib/models/xtream_types.dart` (:131) and dead `lib/backend/xtream_epg.dart` (:66).
- [ ] 39. `pubspec.yaml` — drop unused `flutter_svg` (+orphan `smpte_color_bars.svg`) and `logging`.
- [ ] 40. One-liners: `lib/setup.dart` (:118/:251), `lib/edit_dialog.dart` (:490), `lib/backend/conn_timing.dart` (:41), `lib/backend/epg_discovery/epg_validator.dart` (:32), `lib/tv/tv_shell.dart` (:307), `lib/player/player_key_action.dart` (:42), `lib/widgets/dpad_text_field.dart` (:25), `lib/whats_new_modal.dart` (:2612), `android/app/src/main/AndroidManifest.xml` (:14), `lib/backend/search_perf_test.dart` (:189), `test/export_zip_test.dart` (:8).

**Summary:** 54 sittings, each file opened once. Waves 1–2 (≤22 files) clear the P0
and every P1. Waves 3–4 are mutually independent — safe to fan out across a team or
across parallel agents with no file conflicts.
