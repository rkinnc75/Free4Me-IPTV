# Code-review resolution — PROGRESS / RESUME doc

**This file is the resume lifeline.** If a session is interrupted (usage reset, context loss),
read this FIRST, then `docs/START_HERE.md`, then continue from "NEXT UP" below.
Keep it updated after every file (it is untracked, like the other review docs).

## What this is
Resolving `docs/IMPLEMENTATION_SPEC.md` (179 drift-proof specs from
`docs/INDEPENDENT_REVIEW_REPORT.md`, 181 findings). Scope for this run = **Waves 1–2**
(P0 + all P1 + every other finding living in those ~22 files). Device-verify batched to the end.

## Environment / commands
- Flutter: `export PATH="$PATH:$HOME/development/flutter/bin"` then `flutter analyze` / `flutter test`.
- Baseline: analyze clean, **289 tests green** as of last commit.
- onn (device-verify, batched at end): adb `10.0.168.194:5555`, pkg `me.free4me.iptv`.
  Procedures in `docs/DEVICE_TESTING.md`.
- To read a file's spec section:
  `awk '/^### \`lib\/backend\/m3u.dart\`/{f=1} f{print} /^### \`lib\//{if(f && !/m3u.dart/)exit}' docs/IMPLEMENTATION_SPEC.md`
  (or grep `#### <N>\.` for one finding block).

## Policy decisions (locked with the user)
- **Commits:** per-file, local, message lists finding IDs. NO fixNNN yet.
- **Version:** at the very END bump pubspec `2.2.54+643` → **`3.0.0+644`**, whats_new entry,
  sync version.json (`python3 scripts/update_version_json.py`), one runbook `runbooks/fix655.md`
  enumerating resolved finding IDs, final findings table.
- **Do NOT push/tag/release** until the user explicitly approves (they want to review first).
- **verify-first findings:** apply the ones the spec marks "safe regardless"; for behavior-changing
  ones whose premise is device/runtime-dependent, apply the unambiguous code part but DEFER the
  device-confirmation to the batched onn pass (task #22). If a premise can't hold, skip + note.
- **DO NOT TOUCH (refuted):** `sql.dart` ~994 (empty IN()), `settings_service.dart` ~547
  (reconcileFtsTriggers overlap). Only optional P3 hardening on the latter, no behavior change.
- Commits carry NO AI co-author trailer (repo convention + global rule).

## Drift-verify conclusion (done, clean — task #19 / workflow wc9ilzaz2)
Ran 23 read-only agents over the Wave 1–2 files vs current HEAD (post fix648–654):
**0 already-fixed, 0 anchors gone, 1 drifted-but-locatable (settings_io #96, from fix654 gzip),
no overlap with fix648–654.** Apply specs as written, relocate by anchor.
Cross-file targets confirmed absent (need creating): `Sql.sourceHasMediaType`,
`getChannelsPreserveForBackup`, app_meta `setAppMeta/getAppMeta`, `sweepOrphanedDvrDirs`,
`channelsGen`, `buildMigrations`, `pipSupported` getter.

---

## WAVE 1 — ✅ DONE (committed, analyze clean, tests green)
| Commit | File | Findings |
|---|---|---|
| ac8fa4d | app_logger.dart (+test) | 45, 40, 82 (credential redaction at source; clears log-side xmltv:60/epg:212/m3u:240) |
| d5b59c5 | settings_view.dart | P0-1; 2,3,4,7 (Back-abort P1s); 5/105,103,104 (reset/optimise); 6,8,10,11,12,14 |
| b6d36a4 | settings.dart + settings_service.dart | 106; 160,161(partial),162 |
| 20ea085 | settings_io.dart (+test) | 92,94,95,96,97 |

## DEFERRED (carry forward — revisit before final table)
- **9** (settings_view P3, verify-first): single-source refresh Cancel — cross-file cancel token.
- **13** (settings_view P3, verify-first): phone dump-export OOM + reachability — cross-file SettingsIo, security overlap w/ P0-1.
- **93** (settings_io P2, verify-first): backup-preserve scope — needs `Sql.getChannelsPreserveForBackup` (sql.dart, Wave 3); perf, premise device-dependent.
- **161-step2** (settings_service P3): broad try/catch wrapper around _readFromDb parse (kept the high-value ViewType hardening).
- **P0-1 unit test** (`test/export_bundle_credentials_test.dart`): deferred — needs a widget/DB seam; P0 code fix is in + static-verified.

---

## WAVE 2 — feature/crash files (18). Order + status.
Apply per-file: open once, all findings, bottom-of-file first, analyze+test, commit listing IDs.
Status: ⬜ pending / 🟡 in-progress / ✅ done / ⤵ deferred-within-file.

- ✅ **5. m3u.dart** — DONE (commit af42fca). 78 (deferred/gated wipe + allowMalformed), 79 (bulk insert), 80 (temp cleanup + stale sweep), 81 (stall→error), 83 (comma title), 84 (# guard). +test/m3u_getname_test.dart. [82 done in app_logger.] DEVICE-VERIFY LATER (batch): 78 (HTTP-200 HTML → catalog kept), 79 (bulk-insert timing on large playlist), 81 (real 60s stall). Note: <20% gate only fully effective for playlists that fit one batch; the 0-count gate always protects.
- ✅ **6. xmltv_parser.dart** — DONE (1f9c04f + 46 in c7f5daa): 47+48, 51, 49, 50, 52+53, and 46 (XmltvParseResult truncation). [45 in app_logger.] DEVICE-VERIFY LATER: 47 (heap plateau 150k feed), 50 (non-UTF-8 feed), 46 (real CDN stall → 'partial/timeout' logged, stale rows kept).
- ✅ **7. epg_service.dart** — DONE (c7f5daa): 46 (caller), 36 (FTS hoist), 37 (sql getLatestEpgRefresh last_error filter), 39 (per-source try/catch), 42 (isStale on-now), 44 (dead manualOverrides). **DEFERRED (cross-file, do next):** 38 + 43 = cross-isolate app_meta bridge — add Sql.setAppMeta/getAppMeta (sql.dart) + main.dart resumed-lifecycle poll of epg_last_completed_utc + refreshAllSources in-progress marker (epg_refresh_in_progress) in a try/finally around the loop (that finally is ALSO where 36's rebuild + 38's completion-ts + 43's marker-clear co-locate — currently 36's rebuild is a plain post-loop call; move into the finally when 43 lands). 41 = VF matcher index-reuse refactor (epg_matcher buildIndex/matchAgainst split + long-lived isolate) — LARGEST, do isolated. DEVICE-VERIFY: 36 (multi-source refresh time), 38/43 (cross-isolate delivery), 42 (no storm).
- ⬜ **7. epg_service.dart** — P1: 36 (per-source FTS rebuild→once-after-all), 37 (failed-download stamps fresh → sql.dart:3068 last_error filter), 38 (cross-isolate epgVersion → app_meta bridge, +main.dart); P2: 39 (abort-all→per-source try/catch), 41 (matcher re-index, VF, LARGEST — do isolated, touches epg_matcher); P3: 42 (isStale 3-day floor), 43 (refresh mutex→app_meta marker), 44 (dead override loop — DELETE, before 41). [40 done in app_logger.] **Coordinated:** 36+38+43 in one post-loop finally.
- 🟡 **8. player.dart** — SAFE BUNDLE DONE (commit 1347bdf): 16 (reconnect try/finally), 25 (key-repeat), 28 (resume-0 guard + _playbackStartedThisSession field), 24 (resume save on surf + didChangeAppLifecycleState), 30 (drop entry log). **STILL PENDING (focused player pass — VF/coordinated/2nd-file):** 15 (VOD no-failure, VF/PLAUSIBLE — confirm dead-VOD emits buffering/error on device first), 17+22+23 (_onCastTap coordinated rewrite, VF, cast hardware), 18+19 (hwdec restore / adopt promote — need NEW mpv_engine methods setHardwareDecode / promoteToFullScreen + make previewMode/dvrEligible mutable, VF Tegra), 20+21 (network-restore + _startPlayback generation-guard state machine — add _openGeneration + _awaitingNetwork; risky, do together), 26+35 (overlay D-pad gate: multiViewLayout==none — DECISION tied to fix653/fix654 single-cell rationale + fromMultiView flag; 27 minimize double-connection), 29 (adopt connectivity/_lastOpenAt — do with 20's _subscribeConnectivity extraction), 31 (grace timer cancel — uses _openGeneration from 21), 32 (seek virtual base, VF-safe), 33 (VOD dead skip buttons), 34 (overlay Cast button timer).
- ⬜ **9. db_factory.dart** — P1: 54 (migration-test gap, VF — pure refactor + new test), 55 (FK cascade→sql.dart explicit deletes), 57 (memoize failed EPG open); P2: 56 (fresh-install marker, VF → sql.dart); P3: 58 (heavy migration tail, VF),59 (down-migration guard),60 (DbFactory.db race — SAME idiom as 57),61 (self-heal debounce, VF). **57+60 = same memoize-with-failure-reset idiom.**
- ⬜ **10. xtream.dart** — P1: 62 (6-way main-isolate decode, VF, DEVICE-only accept, LARGEST — do last); P2: 63 (transient-fetch wipe → needs Sql.sourceHasMediaType), 64 (non-atomic reinsert — move updateSource after commit), 65 (HTML-as-200 → throw not []); P3: 66 (dump size cap 256KB), 67 (dead fetchXtreamMaxConnections — DELETE +edit_dialog+test), 68 (auth string/bool coercion), 69 (getEpisodes TypeError guard). 63+65 same pass.
- ⬜ **11. tv_guide_view.dart** — P1: 70 (double-Back exit → confirm_exit_scope notePopConsumed); P2: 71 (unguarded init → shared _error/_errorRetry),72 (swallowed query),73 (stale settings → +tv_search_view),74 (non-lazy rail→ListView.builder),75 (focusable grid→ExcludeFocus); P3: 76 (empty-cat focus, VF),77 (stale Favorites, VF → sql.dart channelsGen). Apply 71 first.
- ⬜ **12. multi_view_cell.dart** — P1: 85 (close-cell engine leak); P2: 86 (recovery Timer survives dispose),87 (EOF budget reset, VF),88 (budget replenish),89 (stale-start guard, VF),90 (watchdog disarm, VF),91 (unfocused-promote audio). Apply bottom-up 91→85. 88 before 87. 89+90 same listener (line ~604).
- ⬜ **13. overlay_player_widget.dart** — P1: 107 (cluster → edits in channel_tile.dart + player.dart, NOT this file: TV-gate mini-player entry points), 108 (D-pad escape hatch in THIS file, VF); P2: 109 (_swap dispose order, VF),110 (_swap blind nav.pop, VF). 109 before 110.
- ⬜ **14. mpv_engine.dart** — P1: 98 (live-DVR seek no-op → gate on _dvrActive, one-liner ~483); P2: 99 (lifecycle test, VF — +constructor seam),100+101 (orphan DVR sweep — ONE sweepOrphanedDvrDirs + main.dart import/call); P3: 102 (dead isLive param, VF). Do sweep(100) first.
- ⬜ **15. home.dart** — P1: 115 (Scan-button lockout try/finally), 116 (Scan-progress dispose crash — same _startScan block); P3: 117 (unguarded toggle setState — do first).
- ⬜ **16. tv_search_view.dart** — P1: non-virtualized shelves (:515→builder); P2: unguarded _run (:137), eager 1000 tiles (:159); P3: mic unreachable (:318). (Confirm finding IDs from spec section.)
- ⬜ **17. CastPlugin.kt** — P1: 118 (picker needs FragmentActivity — coordinated w/ MainActivity swap, VF); P3: premature success (:136, VF).
- ⬜ **18. MainActivity.kt** — P1: PiP crash (:258, VF); P2: isSupported ignores feature (:136, VF). Shared `pipSupported` getter (add once). Coordinated w/ CastPlugin FragmentActivity swap.
- ⬜ **19. multi_view_screen.dart** — P1: no lifecycle handling (:74); P2: duck permanent-mute (:131). Apply both.
- ⬜ **20. stalker_xmltv_cookie_auth.dart** — P1: dead cookie-auth EPG URL (:123). Apply.
- ⬜ **21. epg_channel_mapping.dart** — P1: load-all + no debounce (:53). Apply.
- ⬜ **22. test/fix572_export_purge_test.dart** — add credential-exclusion test fencing P0-1/P1-5 (or new test file). (Overlaps the deferred P0-1 unit test above.)

## NEXT UP
**Wave 2 file 9 = db_factory.dart** (P1: 55 FK-cascade→sql.dart deletes, 57 memoize failed EPG open,
54 migration-test VF; P2: 56 fresh-install marker VF→sql.dart; P3: 58 heavy-migration-tail VF, 59
down-migration guard, 60 DbFactory.db race [SAME memoize idiom as 57], 61 self-heal debounce VF).
57+60 = one shared memoize-with-failure-reset idiom. Then xtream (10), tv_guide_view (11),
multi_view_cell (12), overlay_player_widget (13), mpv_engine (14) [pairs w/ player 18/19], home (15),
tv_search_view (16), CastPlugin.kt (17), MainActivity.kt (18), multi_view_screen (19),
stalker_xmltv_cookie_auth (20), epg_channel_mapping (21), fix572 test (22). Plus the player.dart
focused pass (deferred set above) and the earlier deferred cross-file items.

--- OLD NEXT-UP (historical) ---
**Wave 2 file 8 = player.dart** (21 findings — the biggest/riskiest file; many VF; coordinated
_onCastTap rewrite 17+22+23, onDisconnect 15+16+20, _startPlayback in-flight 21+31; shared fields
_openGeneration + _playbackStartedThisSession; #18/#19 need mpv_engine 2nd file). Then db_factory (9),
xtream (10), tv_guide_view (11), multi_view_cell (12), overlay_player_widget (13), mpv_engine (14),
home (15), tv_search_view (16), CastPlugin.kt (17), MainActivity.kt (18), multi_view_screen (19),
stalker_xmltv_cookie_auth (20), epg_channel_mapping (21), fix572 test (22). Also OUTSTANDING deferred
cross-file: epg 38+43 (app_meta bridge + main.dart) and 41 (matcher) — see file 7 row.

Wave 2 progress: 4 of 18 files touched (m3u ✅, xmltv ✅, epg_service ✅, player 🟡 safe bundle).
v3.0.0 SHIPPED (fix655) = Wave 1 + m3u/xmltv/epg_service. player safe bundle (1347bdf) is committed
but NOT yet shipped — folds into the next 3.0.1 ship. Analyze clean, 292 tests green.
DEFERRED set: player {15,17,18,19,20,21,26,27,29,31,32,33,34,35}; epg 38/43/41; settings_view 9/13;
settings_io 93; settings_service 161-step2. 14 Wave-2 files not yet started (db_factory onward).

## SHIPPED
- **v3.0.0+644 (fix655)** — PARTIAL ship of the review (Wave 1 + Wave 2 files m3u/xmltv/epg_service),
  at the owner's request. Commit 3e3ae11; main + tag v3.0.0 pushed; CI Release run 28762139276.
  Owner directive: **NO on-device testing until the whole review is done** — do NOT install/smoke-test
  interim ships on the onn. ALL device-verify (the MANUAL/DEVICE + VF findings) is batched to the very
  end (task #22). For each ship, just confirm the CI build succeeds + the APK asset publishes.
  Remaining Wave 2 (player.dart onward) ships as **3.0.x** — bump 3.0.0+644 → 3.0.1+645 for the next
  batch (NOT a fresh major).

## FINAL STEPS (after Wave 2)
1. Batch device-verify the VF/MANUAL findings on the onn (`docs/DEVICE_TESTING.md`), record pass/fail.
2. Bump pubspec → `3.0.0+644`; whats_new entry; `python3 scripts/update_version_json.py`.
3. Write `runbooks/fix655.md` enumerating all resolved finding IDs + the deferred list.
4. Final table: finding → {fixed | needs-device-verify (result) | skipped+why}. Check items off in the work plan.
5. **Ask the user before pushing/tagging/releasing 3.0.0.**
