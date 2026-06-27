# Free4Me-IPTV — Backlog (TV Live-UI focus)

**Audited against live source at v2.0.65 (not assumed — grep-confirmed).**
Status markers added below; nothing in this file has been removed, only
annotated.

**Re-verified against v2.1.0 (2026-06-27):** items #5, #6, #7 are still OPEN as
marked; carry-over #1 (index rebuild) is now DONE (fix523). Full project-wide
status for ALL backlog items lives in `NEXT-SESSION.md`.

Items 5–7 are TV/live-view UX; they touch the guide screens
(`tv_guide_view.dart` and the rail), so they should be sequenced after the
542→545 guide stack and ordered against fix547's Categories type-row (both
already landed).

---

## #5 — Live TV: collapse category rail on category select — ❌ NOT BUILT

Confirmed: `tv_browse_view.dart`'s rail is a **fixed 210px width**
(`SizedBox(width: 210, child: _rail())`). No collapse/sliver/widen/re-expand
behavior exists.

**Behavior (unchanged from original spec):**
- In Live TV, choosing a category **shrinks the left category rail to a thin
  sliver** (barely visible) and **shifts the channel area left** to reclaim the
  space.
- **Widen channel cells slightly** so more of each channel name fits.
- **D-pad LEFT from the channel column** re-expands / reopens the category rail
  (focus returns to the rail).

**Build notes:**
- Animated rail width (collapsed sliver ↔ full). Keep a focus-traversal rule so
  LEFT at the channel column's left edge targets the rail instead of a no-op.
- Watch interaction with **fix539** (rail top item is "Favorites") and
  **fix553** (Categories type-row Live/Movies/Series — already landed). The
  collapse should not fight the type-row focus model.
- Preserve restored-focus: reopening the rail should land focus on the
  previously selected category, not the top.

## #6 — Auto-preview on dwell (3s) — ❌ NOT BUILT AS SPECIFIED

A **different, adjacent** feature already exists — do not confuse it with this
item: fix510's `TvHeroPreview` (`lib/tv/tv_hero_preview.dart`) is a
dwell-gated, MUTED preview, but it:
- lives in **`tv_guide_view.dart`** (the EPG guide), not Live TV channel
  browsing;
- uses **700ms (1100ms on low-RAM)** dwell, not the 3s specified here.

This backlog item — 3s dwell, **in Live TV channel browsing**, unmuted/preview
window per spec — is still open.

**Behavior:**
- When focus rests on a channel for **3 seconds**, start that stream in the
  **preview window**.
- **Teardown: keep the last preview until a NEW dwell starts** (decided). Do NOT
  tear down the instant focus leaves — the previous preview stays up until
  another channel has been dwelled on for 3s and replaces it.

**Build notes (2GB Onn ceiling — this is the risk):**
- Debounce timer keyed on focus; reset on focus move; fire at 3s.
- **One shared preview player instance**, reused across dwells (never spawn a
  new decoder per channel). Reuse the multi-view per-cell provider-connection
  pattern. Swap the source on the existing player rather than create/destroy.
- "Keep last preview" means the decoder stays warm between dwells — confirm
  this doesn't pin a second live decoder alongside the main player on the 2GB
  box. Measure RAM on the Onn before shipping (engine fallback / black-screen
  history).
- Cancel the pending timer on category-rail open and on menu open (#7).
- fix510's `TvHeroPreview` is a reasonable reference for the "one shared,
  reused player instance" pattern even though it's a different screen/timing —
  worth reading before building this.

## #7 — Long-press channel → context menu — ⚠️ PARTIALLY BUILT

Confirmed in `channel_tile.dart`: long-press (`_onLongPress`) already opens a
bottom-sheet menu with **Favorite toggle** (fix308/309), **category link**,
**mini-player**, and **remove-from-history**. Short-press still plays — the
coexistence behavior is already correct.

**Missing:** the **Multi-view** entry specified below. That's the only gap.

**Behavior:**
- **Long-press = menu; short-press = play (coexist)** (decided) — ✅ already
  true.
- Menu options: **Add to Favorites** ✅ already there. **Multi-view** ❌ missing
  — this is the remaining work for #7.

**Build notes:**
- Favorites toggle already exists and is wired (validated-favorites float in
  `BrowseOrder`) — no change needed there.
- Multi-view is **live-TV-only** per existing constraint — the new menu entry
  should only appear (or only enable) in the Live context.
- Center-press hold detection must not mis-fire the short-press play; tune the
  long-press threshold for the remote (existing long-press timing can likely be
  reused as-is since short/long already coexist correctly).

---

## Carry-over backlog (from prior ground zero)

- **#1 import-time index rebuild** — ✅ **DONE**: fix549 surfaced per-index
  progress/timing, and **fix523 landed the speed-up** (`PRAGMA temp_store=FILE`
  + `cache_size` in `sql.dart` before the recreate, ~9 min → ~3 min). Close
  unless further per-index tuning is wanted.
- **#2 groups unique-key migration** — ❌ NOT BUILT. `(name, source_id)` lacks
  `media_type`; same-named live+vod categories collapse (≤2 on field data). Low
  impact.
- **#3 empty-state hint on Live** when Favorites-default shows nothing ("No
  favorites yet…") — ❌ NOT BUILT. Minor UX.
- **#4 device-ID in export/backup filenames** — ✅ **DONE** (completed; do not
  re-add to pending — confirmed complete by Rich, previously mis-tracked and
  has now been removed from active memory).

---

## Sequencing reminder

Items 5–7 all touch live-view focus/rendering. The **542→549** stack
(black-screen fix, Live TV behavior, Categories type-row) is already landed.
Build 5 → 6 → 7 in that order (5 changes the layout 6 previews into; 7's menu
must cancel 6's dwell timer once 6 exists).

## Also pending (not originally in this file — tracked in memory)

- **TV playback controls missing entirely.** Hitting the center of the D-pad
  during full-screen TV playback should bring up transport controls
  (play/pause, seek bar, etc.) — same as phone mode. Currently nothing appears.
- **Export/backup files have no rotation/cap**, can fill device storage (this
  forced an Onn data-clear on 2026-06-26).
