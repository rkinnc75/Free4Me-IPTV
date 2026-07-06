# START HERE — resolving the independent code review

You are resolving a full independent code review of this Flutter IPTV app
(`open_tv`, applicationId `me.free4me.iptv`). Three documents in `docs/` drive the
work; read them in this order and follow them exactly.

## The three files

1. **`docs/INDEPENDENT_REVIEW_REPORT.md`** — *WHAT and WHY.* 181 findings (1 P0,
   ~26 P1, 74 P2, 69 P3), ranked, with a **Fix-order work plan** (file-batch waves)
   and a **Verification results** section. Read the top + the work plan; use the
   finding bodies for context. It records each finding's **verification status**
   (CONFIRMED / PLAUSIBLE / REFUTED) — respect it.
2. **`docs/IMPLEMENTATION_SPEC.md`** — *HOW.* A drift-proof spec for every
   actionable finding: **Anchor** (symbol + grep token), **Current code** (verbatim
   snippet), **Fix** (the one chosen edit), **Blast radius**, **Acceptance**. Its
   top has a HAND-OFF PROMPT with the authoritative rules. **This file is your
   primary worklist.**
3. **`docs/DEVICE_TESTING.md`** — *VERIFY ON HARDWARE.* Exact `adb` procedures
   (keyevents, logcat greps, `meminfo`/`gfxinfo`, network toggle, build type) for
   every perf/native/device-dependent finding. If you have a device on `adb`, use it.

## How to work

- Go **file by file** in the order `docs/IMPLEMENTATION_SPEC.md` lists files (P0
  first, then P1-dense, then P2-only, then P3 cleanup). Open each file **once**,
  apply **all** its specs in one sitting, never reopen it. Within a file, apply
  edits **bottom-of-file first** (follow that file's *File notes*).
- **Locate** every edit by its **Anchor + Current-code snippet** (grep/match),
  **never by the printed line number** — line numbers are stale and drift as you edit.
- **Cross-file clusters** — keep each on ONE branch, don't split:
  1. **Credential redaction** = `lib/backend/app_logger.dart` +
     `lib/backend/settings_io.dart`. Fixing redaction at the source in
     `app_logger.dart` also clears the log-side leaks specced under
     `xmltv_parser.dart` / `epg_service.dart` / `m3u.dart`, so do `app_logger` FIRST.
  2. **Optimise/Reset** = `lib/settings_view.dart` + `lib/models/settings.dart` +
     `lib/backend/settings_service.dart`.
  3. **P0-1** — primary fix in `lib/settings_view.dart`; optional scrub at the write
     site in `lib/backend/xtream.dart`.

## Verify each fix

- After each file: `~/development/flutter/bin/flutter analyze` (stay at 0 issues)
  and `~/development/flutter/bin/flutter test` (stay green).
- Honor each spec's **Acceptance** gate: if it names a test, add/run it; if it says
  **MANUAL/DEVICE**, open `docs/DEVICE_TESTING.md`, **reproduce the bug on the
  current code first**, apply the fix, then confirm the pass criterion on the device;
  if it says **STATIC**, do the grep/inspection.
- Specs marked **VERIFY FIRST** are runtime-dependent — confirm the premise before
  changing behavior; if it doesn't hold, skip and note it.

## Do NOT touch (refuted by adversarial verification — changing them breaks correct code)

- **`lib/backend/sql.dart`** `search()` empty `IN ()` / `mediaTypes!` (~line 994):
  empty `IN ()` is valid always-false SQL on the bundled sqlite3; the null-deref path
  is unreachable.
- **`lib/backend/settings_service.dart`** `reconcileFtsTriggers` mid-refresh (~line
  547): the concurrent overlap is unreachable (refresh runs behind a blocking modal;
  the workmanager isolate refreshes EPG, not channels). Only the optional P3
  hardening (early-return when suspended) is allowed, and it must not change behavior.

## Output

- Commit per file/wave; the message lists the finding IDs fixed. Do **not**
  push/tag/release.
- Produce a final table: finding → {fixed | needs-device-verification (result) |
  skipped + why}.
- Only edit `docs/*.md` to check items off in the work plan.

---

*Pipeline: the review (`INDEPENDENT_REVIEW_REPORT.md`) → the exact fixes
(`IMPLEMENTATION_SPEC.md`, 179 drift-proof specs) → on-device verification
(`DEVICE_TESTING.md`, 59 adb procedures). All generated read-only from the working
tree; nothing committed.*
