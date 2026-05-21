# fix16.md — PIP Cooldown Loop + Shield ExoPlayer Source Error

---

## Issue 1 — Cooldown fires incorrectly on PIP swap

### The real problem

The cooldown should **never apply to a PIP swap**. When the user taps ⇄
to swap channels, the mini-player channel is actively streaming and proven
live — blocking it with a cooldown makes no sense.

What actually happens during a swap (`_swap()` in `overlay_player_widget.dart`):

```
1. consumeOverlay() — takes the mini-player channel (e.g. DAZN, working fine)
2. _nav.pop()       — closes the full-screen player (eSports, which hit max
                       reconnects and has an entry in _recentGiveUps)
3. _nav.push(Player(channel: DAZN))  ← NEW Player widget for DAZN
4. startOverlay(eSports)             ← eSports goes to mini
```

Step 3 creates a fresh `Player` widget for DAZN. Its `initAsync()` runs the
cooldown check: `_recentGiveUps[DAZN.id]`. If DAZN previously hit max
reconnects in this session (even though it's currently streaming fine in the
overlay), the cooldown fires and blocks it.

Worse: step 4 puts eSports in the overlay. eSports is in `_recentGiveUps`
but the overlay player (`OverlayPlayerController`) has NO cooldown check —
it calls `engine.open()` directly. So eSports plays fine in mini but the
promoted DAZN is blocked. The user sees the cooldown message on what was
just a working stream.

### Fix — clear cooldown before swap push

The overlay's successful playback **proves** the stream is live. Before
pushing the new full-screen Player, clear that channel's cooldown entry.
Add a static method to `Player` to expose this:

#### `lib/player.dart` — add static clearCooldown method

```dart
/// Clears any give-up cooldown for [channelId].
/// Called before a PIP swap promotes an overlay channel to full-screen,
/// since the overlay's active playback proves the stream is live.
static void clearCooldown(int? channelId) {
  if (channelId != null) _recentGiveUps.remove(channelId);
}
```

#### `lib/player/overlay_player_widget.dart` — call it in _swap()

```dart
Future<void> _swap() async {
  await _ctrl.muteMain();

  final snapshot = await _ctrl.consumeOverlay();
  if (snapshot == null) return;

  final mainCh = _ctrl.mainChannel;
  final mainSettings = _ctrl.mainSettings;
  final mainSource = _ctrl.mainSource;

  // The overlay channel is actively streaming — its cooldown (if any) is
  // stale. Clear it so the new full-screen Player opens without delay.
  Player.clearCooldown(snapshot.ch.id);   // ← ADD THIS

  if (mainCh != null) _nav.pop();

  _nav.push(
    MaterialPageRoute(
      builder: (_) => Player(
        channel: snapshot.ch,
        settings: snapshot.s,
        source: snapshot.src,
      ),
    ),
  );

  if (mainCh != null && mainSettings != null) {
    await _ctrl.startOverlay(mainCh, mainSettings, mainSource);
  }
}
```

This is the complete fix. No changes to `initAsync()`, no PIP state tracking,
no dismiss buttons needed. The cooldown is cleared at the source — before the
widget is even created — so `initAsync()` never sees a stale entry for a
channel that's actively streaming.

### Also fix: add dismiss button for non-swap cooldowns

For the case where a user manually navigates back to a genuinely dead
channel (not via swap), the cooldown message should still have an exit:

```dart
// In the _bufferingState overlay in player.dart build():
if (_bufferingState != null)
  Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(_bufferingState!),
      if (_bufferingState!.contains('please wait'))
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Go Back'),
        ),
    ],
  ),
```

---

## Issue 2 — Two alternating messages

With the swap fix above, this resolves automatically. The promoted channel
no longer hits the cooldown, so only one message is ever shown at a time.

---

## Issue 3 — Shield: ExoPlayer "Source Error" on .ts stream

### What the Shield log shows

```
[INFO] Player: engine=EngineType.exoplayer channel="US: EPIX HD"
[WARN] Player: open() failed (1/6) — PlatformException(VideoError,
       Video player had error u0.i: Source error, null, null)
```

ExoPlayer is selected for `"US: EPIX HD"` and fails immediately on every
attempt with a generic `Source error`. The channel almost certainly uses
MPEG-TS (`.ts`) — ExoPlayer can play some `.ts` content but has known
failures with certain IPTV-style MPEG-TS streams (non-standard bitrates,
missing PMT, or streams that start mid-packet).

### Why ExoPlayer is being selected on Shield

The `engine_picker.dart` heuristic:
```dart
if (u.contains('.m3u8') || u.contains('.mpd') || u.endsWith('.mp4')) {
  return EngineType.exoplayer;
}
return EngineType.libmpv;  // ← .ts → libmpv
```

`.ts` correctly falls through to libmpv. So ExoPlayer is being selected
via one of:
1. **Channel-level override** — user or import set `engineOverride = exoplayer`
2. **Global override** — `settings.forcedEngine = exoplayer`
3. **Source-level default** — the source has `defaultEngine = exoplayer`

On the Shield, the `isTV()` check for `mediacodec-copy` (fix13) is not yet
applied (fix13 hasn't been pushed). The Shield's ExoPlayer is also
encountering its own surface binding issue — `Source error` is ExoPlayer's
catchall for playback initialisation failure, which on Shield/Android TV can
mean the surface isn't ready.

### Fix

**Immediate:** In the ExoEngine `catch` block, when `Source error` is
received, fall back to libmpv rather than retrying ExoPlayer 6 times:

```dart
// In exo_engine.dart or in player.dart's catch block:
if (err.contains('Source error') && _engineType == EngineType.exoplayer) {
  AppLog.warn(
    'Player: ExoPlayer source error — falling back to libmpv'
    ' channel="${widget.channel.name}"',
  );
  // Switch engine to libmpv and restart
  await _engine.dispose();
  _engineType = EngineType.libmpv;
  _engine = _createEngine(EngineType.libmpv);
  await _engine.initialize();
  await _startPlayback(null);
  return;
}
```

**Structural:** Add `EngineType.exoplayer` → `EngineType.libmpv` fallback
as a general pattern: if ExoPlayer fails on attempt 1 with a non-network
error (Source error, codec error), switch to libmpv rather than retrying
the same failing engine 5 more times. This benefits Shield, Fire TV, and
any device where ExoPlayer's codec support is limited.

---

## Summary

| Issue | Root cause | Fix |
|---|---|---|
| PIP swap blocked by stale cooldown | Swap creates new Player widget which hits `_recentGiveUps` for channel actively streaming in overlay | `Player.clearCooldown()` before swap push |
| Two alternating messages | Resolved by swap fix — promoted channel no longer hits cooldown | Same fix |
| Shield ExoPlayer source error | ExoPlayer selected for .ts stream it can't handle; retried 6× | Fall back to libmpv on Source error at attempt 1 |

## Files to edit

- `lib/player.dart` — add static `clearCooldown()` method; add dismiss button to cooldown overlay
- `lib/player/overlay_player_widget.dart` — call `Player.clearCooldown()` in `_swap()` before push
- `lib/player.dart` or `lib/player/exo_engine.dart` — ExoPlayer→libmpv fallback

## Model

Sonnet 4.6 (state guard additions, PIP-aware dismissal, engine fallback)
