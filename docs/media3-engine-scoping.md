# Scoping: Media3/ExoPlayer as default engine, libmpv as fallback (backlog #24)

**Status:** Scoped — recommendation below. Not approved for build.
**Date:** 2026-06-27
**Method:** 9-agent scoping workflow (5 investigators → ADR synthesis → 3 adversarial critics), claims spot-verified against the tree.

---

## TL;DR recommendation

**Do not make Media3 the blanket default.** The motivation (the onn 4K Plus plays
flawlessly under a reference app's zero-copy Media3 HW decode, while we route libmpv
to *software* on that box) is real — but "Media3 default, libmpv fallback" is the
most expensive way to chase it and reverses the fix350 consolidation for a benefit
that, on inspection, **cannot retire libmpv** (so the maintenance/licensing win never
arrives — Media3 is purely additive forever).

Pursue in this order, each with a hard gate:

1. **Phase 0 (hours): test the knob we already ship.** `forceHardware` (fix505)
   already exists and flips the onn to `mediacodec-copy`. A/B it on the onn under
   the *current* custom libmpv + `framedrop=decoder`. If it is acceptable, #24's
   motivation largely dissolves **today** with zero architecture change.
2. **Phase 1 (days): root-cause the onn software routing.** The "low-RAM → software"
   decision predates both the custom LGPL build (505 decoders) and the
   `framedrop=decoder` win (0 VO drops). Re-test whether libmpv can HW-decode the onn
   acceptably now. **Caveat (critic-confirmed): zero-copy may be unreachable under our
   texture renderer** — see "The render-path catch" — so set the exit bar at
   "smooth + 0 VO drops + no desync," not "matches Media3 zero-copy."
3. **Phase 2 (parallel, days): measure the compatibility tail.** Run the live channel
   set against a bare Media3 1.6.1 build and count **sustained-playback** failures
   (not prepare-at-t0) on real IPTV TS. This number gates any Media3 work — but treat
   it as a moving target (stream quality churns weekly).
4. **Only if Phase 1 fails AND Phase 2 is favorable:** build a Media3 engine behind
   the interface and ship it as **Option C — scoped per-format/per-device routing**
   (Android-only override; libmpv default for everything exotic and all other
   platforms), with **playback-failure-triggered fallback (never URL-heuristic
   routing)** and the FFmpeg audio extension built up front. **Blanket Option A is not
   a phase** unless C proves the tail is negligible.

The engine *seam* supports a second engine; the *evidence* does not yet justify
demoting libmpv, and the cheaper levers (Phase 0/1) are unexhausted.

---

## Motivation

A reference app using **AndroidX Media3 1.6.1** (ExoPlayer's current home) does
zero-copy `MediaCodec → Surface` hardware decode and plays smoothly on the onn 4K
Plus (~1.9 GB RAM, Amlogic + Mali-G310). free4me routes libmpv to **software** decode
on that exact box by design (`lib/player/hwdec_routing.dart`: low-RAM, non-Tegra TV →
`hwdec=no`, because `mediacodec-copy` desynced A/V and surface-mode `mediacodec`
failed silently under libmpv). On a live 1080p60 stream libmpv on the onn is CPU-bound
software decode; the reference app is efficient hardware decode. The onn pain is
genuine.

## History — why ExoPlayer was removed (and what that does/doesn't imply)

- **fix350** (commit `4040ce4`, 2026-06-11, v1.28.0; net −2,717/+44 lines) removed
  ExoPlayer for **maintenance/architecture** reasons, *not* an IPTV failure.
  `runbooks/fix350.md`: *"Two engines meant every buffering/EOF/watchdog fix had to be
  reasoned twice and the paths kept diverging… libmpv already plays every format…
  go exclusive with libmpv."*
- The removed engine was the high-level **`video_player`** package wrapping ExoPlayer
  (no track selection; texture-path black-screen / first-frame / letterbox bugs in
  fix332/334/340) — **not** raw Media3 with a zero-copy Surface like the reference app.
  So `exo_engine.dart` is **not** reusable; a new Media3 engine is genuinely new code.
- ExoPlayer was **never the live-IPTV default**: the original `EnginePicker` (git
  `f7bf2f2`, v1.8.0) routed `.m3u8/.mpd/.mp4` → ExoPlayer and **MPEG-TS/RTMP live →
  libmpv**. libmpv and ExoPlayer shipped *together*; libmpv was not adopted to rescue
  an ExoPlayer IPTV failure.

**Critical correction (adversarial review):** "no recorded ExoPlayer-IPTV bug" is
**survivorship bias, not evidence of safety** — ExoPlayer was deliberately kept *off*
the malformed-TS path from day one. The proposal would newly route core IPTV TS to
Media3, i.e. exactly the streams we have **never** tested ExoPlayer against here.

What re-adding Media3 *would* reintroduce is the **dual-engine maintenance burden
fix350 eliminated** — and that reason still fully applies; the libmpv-only recovery
logic (fix316 fallback, fix341/342/345/346 multi-view recovery, reconnect/watchdog)
has only matured since.

## The architectural reality (verified in-tree, 2026-06-27)

- **The render stack is 100% texture-based.** `grep -rn 'PlatformView\|AndroidView'
  lib/` → **0 hits**. We render via `media_kit_video` Textures. A Media3
  `PlayerView`/`SurfaceView` is a **PlatformView** — a different composition path
  (Hybrid/Virtual Composition) with documented z-order / transparency / scroll-jank
  limits on Android. **Every** widget that composites *over* video today (overlay
  controls, scrims, the drag mini-player, the 4-cell multi-view grid, full-screen↔mini
  transitions (fix116), TV D-pad focus rings) must be re-validated over a PlatformView.
  This is the **dominant** integration risk, not a line item.
- **The "engine seam" is leakier than it looks.** The `PlayerEngine` abstract
  interface (`lib/player/player_engine.dart`) exists, but **46 `MpvEngine` references
  across 11 files** bypass it (`grep -rn MpvEngine lib/`). The mini-player handoff
  (`OverlayPlayerController`), `DebugStatsOverlay`, `setZoomMode`, `detachForSwap`,
  multi-view cells, and TV hero preview are typed to the *concrete* `MpvEngine`. These
  must be lifted to the interface first, or Media3 silently loses handoff/zoom/diagnostics.
- **No engine-swap mechanism exists.** `_isExoSourceError`/`_swapEngine` (fix316) →
  **0 remnants**; `player.dart` only *reopens the same engine*. A Media3→libmpv
  fallback trigger must be built from scratch.
- **A routing column already exists** (deliberately kept by fix350): `channels.engine_override`
  and `sources.default_engine` — present in schema but deprecated/unread.

## Capability matrix (what changes, engine vs engine)

| Area | Media3 1.6.1 | libmpv (current) | Verdict |
|---|---|---|---|
| **HW decode on onn** | zero-copy Surface; reference app verified | software by design (routing) | **Media3 win** — the whole motivation |
| Clean HLS/DASH (incl. Xtream `/live/N.m3u8`) | native, strong | native | parity; Media3's safe zone |
| **Live MPEG-TS over HTTP (core IPTV)** | TS extractor is materially **stricter**; stalls on missing AUDs, bad start codes, fixed Content-Length live (ExoPlayer #2671/#7177/#8090/#9859) | FFmpeg demuxer tolerates broken PAT/PMT, discontinuities | **libmpv** — the core risk; magnitude unmeasured & unbounded-by-design |
| **MP2 / AC-3 / E-AC-3 audio in TS** | needs NDK-compiled Media3 FFmpeg ext (not on Maven) | built in | **libmpv** — *common, not exotic* in EU/reseller IPTV; without the ext, **video plays, no audio** → a Phase-2/3 **blocker**, not Phase-5 |
| RTMP/RTMPS / MMS / raw UDP-RTP | **no** | 37 protocols | **libmpv-only** |
| VOD MKV / AVI | MKV partial, AVI weak | full (343 demuxers) | **libmpv** |
| Live DVR / timeshift-to-disk (fix357) | no built-in; custom CacheDataSource | `cache-on-disk` + `force-seekable` + disk-guard | **libmpv**; big new impl or force-route |
| Mini-player handoff (fix116) | Surface re-parenting (new code) | live-instance adopt/detach | `OverlayPlayerController` is MpvEngine-typed; risk of ~10 s reopen stall |
| Multi-view (4 cells) | concurrent MediaCodec, device instance-limited on low-RAM | per-cell preview engines | low-RAM boxes may hit instance ceilings exactly where multi-view runs |
| Debug stats (hwdec-current/avsync/cache) | partial (no avsync / cache equivalents) | ~15 raw mpv props | switching default **blinds** the Shield/onn investigations |
| Custom lavfi filters incl. `fps=30` cap | none | only libmpv (the reason for the custom .so) | Android-default-Media3 makes the custom build reachable only via fallback |
| **Cross-platform** | **Android only** | sole engine on iOS/macOS/Linux/Windows/web | "Media3 default" is necessarily an **Android-only override** |
| HTTP headers / TLS-verify, track selection, reconnect classifier | reimplementable, but **new code** (error classifier matches mpv *strings* today) | shipped | silent regression risk (fail-fast violation) if not rebuilt |
| License | Apache-2.0 | custom LGPLv3 | **win only if libmpv is dropped — which the rows above prove can never happen** |

**Therefore (critic-confirmed): libmpv can never be dropped** — it is the sole engine
on 5 of 6 platforms and the only path for RTMP/MMS/UDP/MKV/AVI/exotic-audio/malformed-TS/DVR/the
fps filter. Media3 is **strictly additive** complexity, with **no** offsetting
simplification or licensing win. This is the single biggest strike against Options A/C.

## Options

| | Option | Effort | Net |
|---|---|---|---|
| **A** | **Media3 default + libmpv fallback** (the proposal) | **HIGH** — new PlatformView engine + FFmpeg-ext + fallback machinery + lift 46 couplings + per-device QA. ~8–13 eng-weeks *before* multi-view/PiP/handoff/DVR. | Reverses fix350; defaults onto the unmeasured strict-TS tail; libmpv stays anyway. **Not recommended.** |
| **B** | **Keep libmpv, enable HW decode on the onn** | LOW–MED (routing experiment + ADB sweep). | Preserves single-engine. **Caveat:** `forceHardware` already returns `mediacodec-copy` (the path said to desync) and zero-copy surface-mode can't bind under a texture renderer → may be **architecturally capped**. Still the first thing to try. |
| **C** | **Per-format/per-device routing** (Media3 for clean HLS/TS on capable HW; libmpv for the rest + all other platforms) | HIGH+ (A + a routing tree & test matrix). | Confines Media3 to its safe zone, **but** TS *compliance* is only knowable by *playing* it → "route clean TS to Media3" is not implementable as a pre-rule; reduces to try-Media3-fallback-on-failure. Still dual-engine forever. |
| **D** | **Status quo + surface existing HW controls** | LOW (settings + docs; hours). | Safe interim; lets the onn user try `forceHardware`/`framedrop=decoder` today. Not a true default fix. |

## What the adversarial review changed

1. **Coupling is ~46 refs / 11 files, not 4** → Phase-4 "lift the couplings" is
   materially larger (handoff, multi-view, TV hero preview all re-typed).
2. **The render model changes** (texture → PlatformView) → the highest-uncertainty
   work; a spike must prove the overlay/mini-player/multi-view stack composites over a
   PlatformView before anything else.
3. **`forceHardware` already does `mediacodec-copy`** → Option B isn't a free win; it
   may be re-running a config that already failed unless a *new* mechanism is named.
   Zero-copy is likely unreachable under the texture renderer.
4. **Compatibility tail is unbounded-by-design** → a "measured 3% failure" rots as
   sources churn; any Media3 default must use **playback-failure fallback**, not a
   measured-fraction gate or URL heuristic.
5. **MP2/AC-3 audio is common in IPTV TS** → the FFmpeg extension is a **blocker** (a
   no-ext spike "works" only on the tester's HW-passthrough device, then loses audio
   in the field).
6. **Test-coverage inversion** → if Media3 is default, the mature libmpv recovery path
   becomes the *least-exercised* path precisely on the hardest streams that only reach
   it via fallback.

## Phased plan (with hard gates)

- **Phase 0 — hours:** A/B the existing `forceHardware` toggle on the onn under the
  custom build. **Gate:** acceptable → close #24 as "use existing knob" + document.
- **Phase 1 — days:** root-cause `hwdec_routing.dart`'s onn software routing; try
  `mediacodec`/`mediacodec-copy`/corrected surface under the custom build via the ADB
  CI dry-run loop. **Gate:** smooth + 0 VO drops + no desync → ship, close #24.
- **Phase 2 — parallel, days:** ADB-measure the live channel set against a bare Media3
  1.6.1 build; metric = **sustained playback incl. reconnect/discontinuity**, not
  prepare-at-t0. Confirm no user-facing failure was ever attributed to ExoPlayer.
- **Phase 3 — ~1 wk, only if 1 fails & 2 favorable:** single-device Media3 spike
  behind `PlayerEngine` — **must include** a malformed-TS/exotic-codec corpus, **one
  multi-view probe, one handoff probe**, and the **FFmpeg audio ext**. A clean-HLS-only
  spike is non-evidence for the default question.
- **Phase 4 — multi-wk:** lift the 46 couplings to the interface (re-type
  `OverlayPlayerController`, promote zoom + a generic stats map, make handoff
  engine-agnostic); build the runtime swap + prepare-timeout **and** mid-stream-stall
  fallback; map `PlaybackException` into the error classifier.
- **Phase 5:** ship as **Option C** scoped routing (Android-only; libmpv default for
  exotic/malformed/DVR and all non-Android), using the kept `engine_override`/
  `default_engine` columns; per-device QA on onn + Shield/Tegra. **Blanket Option A is
  explicitly not a phase.**

## Open questions (decision-dominating)

1. What fraction of *this* user base's IPTV sources are non-compliant TS that Media3
   rejects but libmpv tolerates? (Unbounded-by-design; measure but don't trust as stable.)
2. Can libmpv HW-decode the onn acceptably now under the custom build + `framedrop=decoder`?
   (Phase 0/1 — may dissolve #24.) Is zero-copy even reachable under a texture renderer?
3. Was any user-facing IPTV failure *ever* attributed to ExoPlayer? (Runbooks say no.)
4. Fallback contract: prepare-timeout *and* mid-stream-stall? playback-failure trigger
   (preserves tolerance, adds latency) vs URL heuristic (misroutes malformed-but-clean-looking TS)?
5. DVR on a Media3 path: force-route to libmpv, disable, or new CacheDataSource?
6. Flutter path: `video_player` (needs PiP + multi-instance fix), `better_player_plus`
   (pins Media3 1.10, heavy), or a custom in-repo PlatformView?
7. Will the Media3 FFmpeg ext (AC-3/E-AC-3/DTS) be built/shipped? If not, what's the
   audio-coverage gap on the real fleet?
8. Do low-RAM boxes survive N concurrent Media3 MediaCodec instances for multi-view?

## References

- `runbooks/fix350.md` (ExoPlayer removal rationale), commit `4040ce4`; `EnginePicker`
  origin `f7bf2f2`.
- `lib/player/player_engine.dart`, `lib/player/mpv_engine.dart`, `lib/player/hwdec_routing.dart`,
  `lib/player/overlay_player_controller.dart`, `lib/player.dart`.
- `lib/backend/sql.dart` / `db_factory.dart` (deprecated `engine_override` / `default_engine`).
- `docs/CUSTOM_LIBMPV.md`, memory `free4me-onn-framedrop-decoder`, `free4me-onn-render-cap`,
  `shield-blackscreen-investigation`.
