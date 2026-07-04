# Free4Me-IPTV — Independent Codebase Review Brief

You are being engaged as an **independent reviewer** of this codebase. Your
mandate: find real issues on your own — correctness bugs, performance
problems at the app's actual data scale, race conditions, resource leaks,
error-handling gaps, security exposures, duplicate or dead or non-functional
code, and meaningful improvement opportunities. You have NOT been told what
has been fixed before or what anyone suspects is broken, and that is
deliberate: your value is a fresh, unanchored reading of the code as it
stands today.

## Independence rules (read first)

- **Form findings from the code itself.** Do not use `runbooks/`,
  `docs/` prose, `VERIFY_*.md`, root-level `fixNNN.md` files, commit
  messages, or the `whats_new_modal.dart` changelog as sources of findings —
  they contain prior analysis and would bias you. You may glance at them at
  most to understand *intent* after you have formed your own reading.
- Code comments carry `fixNNN` markers. Treat them as historical
  breadcrumbs explaining intent, never as proof that something works.
- **Verify every claim against the code** (file:line). If you can prove it
  with a small test (see "Verifying claims"), do so. Label each finding
  CONFIRMED (provable) or PLAUSIBLE (strong reading, unproven).
- Read-only engagement: do not commit, push, tag, release, or change any
  device or external state. Deliverable is a report.

## What the app is

A Flutter IPTV client (Dart 3, Flutter stable ~3.44), package
`me.free4me.iptv`, internal package name `open_tv` (it began as a fork of an
open-source IPTV app and has diverged heavily). It plays live TV, movies,
and series from user-configured providers (Xtream-codes API and M3U
playlists), with:

- an XMLTV-based EPG/program guide,
- full-text and substring channel search,
- a TV-native ("10-foot", D-pad-driven) UI alongside the phone/touch UI,
- multi-view (2x2 / 1x2 grid of simultaneous live streams),
- a floating mini-player, Chromecast output, Android picture-in-picture,
- source/EPG background refresh pipelines, settings backup/restore,
  LAN export, in-app update download, diagnostic log capture/upload.

## Scale and constraints — calibrate every judgment to these

- **Catalog scale is extreme:** users run ~5 providers at 150k–450k channels
  each — **over 1 million rows in `channels`**, and **>1.5 million rows** in
  the EPG `programmes` table. Any query, loop, cache, or rebuild you review
  must be judged at that scale, not at demo scale.
- **Primary TV hardware is weak:** ~2 GB RAM Android TV boxes (Amlogic
  class). Memory spikes, temp B-tree sorts, jank, and unbounded lists are
  real failures, not theoretical ones.
- **TV input is D-pad only.** No touch, no hover, and remotes cannot
  long-press reliably. Focus traversal is a functional requirement: a widget
  that cannot receive focus is unusable on TV.
- Streams are of highly variable quality (slow origins, dead URLs, exotic
  codecs/containers). Error paths are hot paths.
- Sources carry **credentials embedded in URLs** (usernames/passwords).
  The app writes logs, exports diagnostics bundles, and backs up settings —
  scrutinize every sink for credential leakage.

## Tech stack (treat as given, review the usage not the choice)

- **Playback:** `media_kit` + libmpv. The Android native libmpv is a custom
  build wired through `dependency_overrides` in `pubspec.yaml` (a git
  fork). The Dart-side engine wrapper is the review surface; the native
  build itself is out of scope.
- **Persistence:** `sqlite_async` — per database: ONE write connection plus
  a read pool. There are TWO SQLite databases with separate migration
  chains (main catalog DB and EPG DB), both defined in
  `lib/backend/db_factory.dart`. FTS5 (trigram tokenizer) virtual tables
  exist for search in both databases.
- **Background work:** `workmanager` (headless **separate isolate** — it
  gets its own database connections; statics are per-isolate) and
  `flutter_foreground_task` (long operations surviving app backgrounding).
- Also in use: Chromecast/PiP platform channels, `http`, `xml` (XMLTV
  parsing of very large feeds), `qr_flutter`, `archive` (export bundles).

## Repository map (start here)

| Area | Files | Notes |
|---|---|---|
| Query layer | `lib/backend/sql.dart` | The largest and most consequential file: all catalog queries, search dispatch (FTS / LIKE / in-memory), category logic, refresh-time index management. Review closely at scale. |
| DB schema/migrations | `lib/backend/db_factory.dart` | Two `SqliteMigrations` chains (main + EPG). Fresh installs run the whole chain; upgrades run the tail. |
| EPG | `lib/backend/epg_service.dart`, `lib/backend/xmltv_parser.dart` | Download → parse (streaming, very large XML) → match channels → write programmes. Foreground and background entry points. |
| Sources/refresh | `lib/backend/utils.dart` + related backend files | Provider import pipelines (Xtream/M3U), bulk inserts, category rebuild. |
| Settings | `lib/models/settings.dart`, `lib/backend/settings_service.dart`, `lib/backend/settings_io.dart`, `lib/settings_view.dart` | A setting is plumbed through ~5 layers (model field/ctor/reset, storage key, load/save, backup export/import, UI). Check completeness per setting. |
| Player | `lib/player.dart`, `lib/player/*` (`mpv_engine.dart`, `player_engine.dart`, overlay/cast/pip controllers, `debug_stats_overlay.dart`) | Full-screen playback, key handling, overlays, engine lifecycle, reconnect logic. |
| Multi-view | `lib/multi_view_screen.dart`, `lib/multi_view_cell.dart` | Grid of concurrent engines on 2 GB devices. |
| TV UI | `lib/tv/*` (`tv_shell.dart`, `tv_guide_view.dart`, `tv_browse_view.dart`, `tv_categories_view.dart`) | IndexedStack shell (tabs stay alive), guide grid, browse grids, focus management. |
| Phone UI | `lib/home.dart`, `lib/channel_tile.dart`, misc views | |
| Search cache | `lib/backend/channel_search_cache.dart` | Optional in-memory index; interacts with low-RAM gating. |
| Logging | `lib/backend/app_logger.dart` | Also feeds the user-facing diagnostic export. |
| Tests | `test/` | Sparse relative to app size — note what has coverage and what critically lacks it. |
| CI/release | `.github/workflows/`, `scripts/` | Tag-push → APK build. Out of scope except where scripts encode assumptions the code breaks. |

## Suggested review dimensions

1. **SQL correctness & performance at 1M+ rows** — query/index alignment,
   full scans on hot paths, temp B-tree sorts, `INDEXED BY` usage (note: a
   forced `INDEXED BY` on a missing index is a *hard runtime error* — check
   how every use is guarded and how indexes can come to be missing),
   transaction scope, migration correctness for both fresh installs and
   upgrades, FTS trigger/rebuild consistency.
2. **Concurrency & lifecycle** — cross-isolate DB contention; `setState`
   after dispose in long async flows and dialogs; Timer / StreamSubscription
   / FocusNode / engine teardown; reentrancy of refresh pipelines; what
   happens when the user navigates away mid-operation or the process dies
   mid-write.
3. **Player/engine** — engine create/adopt/dispose paths, reconnect and
   error classification, seek behavior across live/DVR/VOD, multi-view
   resource management on 2 GB devices.
4. **TV usability as correctness** — every interactive element reachable by
   D-pad; focus traps; key handling that swallows or double-handles events
   (e.g. Back semantics).
5. **Security/privacy** — credentials in logs, exports, backups, QR/LAN
   export, crash text; TLS handling; the update-download path.
6. **Dead/duplicate/non-functional code** — unused widgets/methods/deps,
   settings that no longer do anything, divergent copies of similar logic
   that have drifted, unreachable branches.
7. **Error handling philosophy** — swallowed exceptions, empty `catch`
   blocks that convert failures into silent wrong states.
8. **Test gaps** — which of the riskiest behaviors above have zero coverage
   and what the highest-value new tests would be.

## Verifying claims

- Toolchain: `~/development/flutter/bin/flutter` (repo baseline: `flutter
  analyze` reports 0 issues; `flutter test` fully green — reproduce before
  and after any experiment).
- `flutter pub get` needs network (git-hosted dependency override).
- SQL claims: the existing tests show a pattern of proving planner/index
  behavior against an in-memory `sqlite3` database — prefer that over
  speculation for any query-plan finding.
- No device is required. If one is available: app logs appear in `adb
  logcat` under the `flutter` tag; release builds are not debuggable (no
  `run-as`, no direct DB pulls).

## Report format

Rank findings most-severe first. For each:

- **Title** (one line) + severity (P0 data-loss/crash/security, P1 broken
  feature/major perf, P2 minor defect, P3 improvement).
- **Location** — file:line (clickable paths).
- **Failure scenario** — concrete inputs/state → wrong outcome, at the data
  scale described above.
- **Evidence** — the code reading or test that proves it; CONFIRMED vs
  PLAUSIBLE.
- **Proposed fix** — sketch, with blast radius (what else the change
  touches).

Close the report with: a dead/duplicate-code inventory, a dependency/asset
hygiene list, and the top 5 highest-value tests you would add. Do not pad
with style nits or subjective refactors unless they conceal a real defect.
