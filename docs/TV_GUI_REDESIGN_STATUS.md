# TV GUI Redesign — Implementation Status (spec vs. code)

Definitive cross-reference of `docs/TV_GUI_REDESIGN.md` against what actually
shipped, as of **v4.1.27** (2026-07-12). Legend: ✅ Done · 🟡 Partial ·
⬜ Deferred/not built · 🚫 Deliberately not adopted (§7).

The **spine is in and device-verified**: Peer4's accent focus-ring language 100%
across every TV surface, the Peer2 three-bar player OSD, the Peer4 EPG guide
enrichment (verified on real EPG data), and glass menus/dialogs. What remains is
secondary polish + a few scoped-down / owner-gated items.

## §3 Foundation (Phase 0)
| Spec | Status | Where |
|---|---|---|
| F4Tokens / AccentScope / F4Motion / F4Elevation / TvFocusable / DpadRepeatGate | ✅ | fix701 (inert foundation) |
| Held-OK fire-on-release (our win, kept) | ✅ kept | unchanged |
| §3.5 `F4GuideFocusState` (formalized saveable guide focus) | ⬜ | deprioritized (higher-risk/low-reward) |

## §4.1 Shell + tabs + background
| Spec | Status | Where |
|---|---|---|
| Tab bar → TvFocusable accent ring + 1.05× scale/lift, section-color pill kept | ✅ | fix702 |
| Crossfade route transitions (no slide) | ⬜ | not wired (default swap) |
| Scrim driven by F4Scrim, accent-neutral | ⬜ | still raster bg |
| OLED-black toggle | ⬜ | `backgroundOled` token exists; no settings toggle |

## §4.2 Browse + tiles + categories
| Spec | Status | Where |
|---|---|---|
| ChannelTile focus → TvFocusable (1.05× scale + ring + lift) | ✅ | fix703 |
| Guide/browse/categories rail rings → accent | ✅ | fix704 |
| `F4Grid` token extraction (kill 3-file magic numbers) | 🟡 | token defined; grids not confirmed migrated to it |
| Skeleton shimmer `PlaceholderCard` | 🟡 | a paging skeleton exists in browse; not the specced tile-grid skeleton |
| Branded-gradient art fallback (never a blank rectangle) | ⬜ | not confirmed wired in `channel_tile` |

## §4.3 EPG guide grid (Peer4 flagship) — device-verified on real EPG (v4.1.27)
| Spec | Status | Where |
|---|---|---|
| Genre color / on-now stripe | ✅ | fix708 + fix711 (top-edge) |
| NOW-line glow | ✅ | fix705 |
| Progress-within-cell fill | ✅ | fix705 |
| Empty-row "No guide data" placeholder | ✅ | fix706 |
| Typographic micro-ramp (11/10/9/8sp) | ⬜ | still uniform 11sp |
| Branded typographic-logo tint fallback | ⬜ | not confirmed |

## §4.4 / 4.5 Recordings + Search
| Spec | Status | Where |
|---|---|---|
| Recordings row accent ring | ✅ | fix718 |
| Search shelves (On now / Coming up / Channels / Movies / Series) | ✅ | earlier v2.0.x TV-mode work + EPG FTS |

## §4.6 Player OSD — Peer2 three-bar (heaviest Peer2 element)
| Spec | Status | Where |
|---|---|---|
| Info Bar (logo / name / now / progress) | ✅ | fix714 |
| Channel Bar (surf-context strip, centered on tuned ch) | ✅ | fix716 |
| Actions Bar — focus-lift buttons | ✅ | fix715 |
| Actions Bar — track/speed popups (0.25–2.0), sleep-timer, long-press trigger | 🟡→⬜ | **owner chose Option B** (short-OK reveal, look-only); fuller bar intentionally not built |
| Layout-driven stacking (bars push, no coord math) | ✅ | fix714/716 Column |
| Zap shutter (latency-mask fade) | ⬜ | `shutter` motion token only; no player impl |

## §4.7 Settings + accent picker
| Spec | Status | Where |
|---|---|---|
| Accent-color picker (feeds the single accent local) | ✅ | fix719 (White + Sky Blue/Amber/Magenta/Green) |
| Settings button/gear focus → accent | ✅ | fix707 |

## §4.10 Quick-action / context menus
| Spec | Status | Where |
|---|---|---|
| Bottom-sheet + dialog glass tokens | ✅ | fix720 (sheets) + fix721 (dialogs) |
| **New data-driven `ContextMenu`** (`List<ContextAction>`) | ⬜ | **judgment call:** restyled the existing fix586 bottom-sheet menu instead of rebuilding it data-driven — same function, not the specced structure |
| **New `QuickActionMenu`** (held-OK tile overlay, Up/Down trap, `ignoreNextEnter`) | ⬜ | not built (the existing held-OK menu covers the function) |

## §4.11 Remaining TV screens
| Spec | Status | Where |
|---|---|---|
| Multi-view focus ring → accent | ✅ | fix722 |
| What's-new modal glass | ✅ | inherits fix721 `dialogTheme` (it's an AlertDialog) |
| Pre-existing dialogs glass (edit/select/color-picker/correction/confirm-delete) | 🟡 | AlertDialog-based ones inherit fix721; custom-Container ones not confirmed |
| Setup / first-run screen tokenize | ⬜ | not done |
| Channel picker tokenize | ⬜ | not done |

## Cross-cutting
| Spec | Status | Where |
|---|---|---|
| Inter font bundle (10-foot type scale) | ⬜ | not bundled; still system font |

## §7 Deliberately NOT adopted (by design — correct)
- 🚫 Peer2 separate hardware `SurfaceView` (we render libmpv into a Flutter `Texture`; 0 PlatformViews).
- 🚫 Peer4 hero-over-rails home composition (would replace our tab shell).
- 🚫 Peer2 `LoadControl` / OkHttp warm-socket zap tuning (engine/network track, not GUI).

## Also fixed during the redesign run (not GUI, but shipped)
- EPG match/refresh concurrency bug — fix709 + fix712 + fix717 (guide was empty on every channel; **verified fixed end-to-end** on the onn: 0 `database is locked`, guide repopulated).
- Re-match/refresh aborting when leaving Settings — fix723.
- CI pub-cache speedup — fix721 (both workflows).

## Open, ranked by value (for owner direction)
1. **Inter font bundle + guide micro-ramp** — highest *visual* fidelity gap; makes the type match the spec's 10-foot scale. (Inter adds a few hundred KB/ABI.)
2. **Fuller Actions Bar** (track/speed popups, sleep-timer) — reverses the Option-B scope-down if wanted.
3. **Data-driven ContextMenu/QuickActionMenu** — rebuild vs. the current restyle.
4. **Shell crossfade + OLED toggle + scrim** — §4.1 polish.
5. **Setup / channel-picker tokenization**, tile skeleton/gradient fallback, F4GuideFocusState — remaining §4.2/§4.11/§3.5 tail.
