# fix22.md — Reset Settings: To Defaults + Optimise For This Device

> Two new entries in the **Backup & Restore** section of Settings: one
> that restores hardcoded defaults from `Settings()`, and one that
> computes the best values for the current device using `DeviceMemory`,
> `DeviceDetector`, and the current `MultiViewLayout`. Both prompt
> before applying. Neither touches sources, credentials, multi-view
> cell assignments, or the active layout.

---

## Motivation

After ~25 fix iterations and several user-tunable sliders for cache,
demuxer, retry timing, and TV-specific behaviour, settings can drift
into a state that's worse than either the defaults or what the device
can actually handle. Two recovery paths:

- **Reset to defaults** — when the user has been experimenting and just
  wants a clean baseline.
- **Optimise for this device** — when the user wants the best values
  for their RAM, TV-vs-phone classification, and chosen MultiView
  layout, computed from `DeviceMemory` and `DeviceDetector`.

This piggy-backs on `DeviceMemory`'s existing per-RAM defaults (fix17)
and the TV detection logic (fix1/fix13). No new device detection.

---

## Scope: what gets reset and what doesn't

Some Settings fields are user preferences worth resetting, others are
session state that would be destructive to clear. Both new actions
preserve the latter group.

| Field | Reset to defaults | Optimise | Preserve untouched |
|---|---|---|---|
| `defaultView` | ✓ | — | — |
| `refreshOnStart` | ✓ | — | — |
| `showLivestreams` / `showMovies` / `showSeries` | ✓ | — | — |
| `lowLatency` | ✓ | ✓ (see below) | — |
| `forceTVMode` | ✓ | — | — |
| `hwDecode` | ✓ | ✓ | — |
| `preWarmOnFocus` | ✓ | ✓ | — |
| `forcedEngine` | ✓ | ✓ (auto) | — |
| `debugLogging` | — | — | ✓ (user explicitly toggled this for a reason) |
| All EPG settings | ✓ | — | — |
| Stream scanner settings | ✓ | ✓ | — |
| All cache/demuxer/timing settings | ✓ | ✓ | — |
| `multiViewLayout` | — | — | ✓ (active session state) |
| `multiViewCells1x2` / `multiViewCells2x2` | — | — | ✓ (channel assignments) |

Sources and credentials are stored in a separate table and never
touched by either action.

---

## Fix 22.1 — Add `defaults()` named constructor and `optimisedFor()` factory

**File:** `lib/models/settings.dart`

Add these two factory methods to the `Settings` class, immediately
after the existing constructor:

```dart
  /// Returns a fresh Settings instance with all fields at their hardcoded
  /// defaults, EXCEPT fields that represent live session state which the
  /// caller should preserve across a reset:
  ///   - debugLogging (user toggled deliberately; don't surprise them)
  ///   - multiViewLayout and the two cell-assignment strings
  ///
  /// Call sites in the reset flow should copy those fields back from the
  /// current Settings instance before saving. This factory is the single
  /// source of truth for what "default" means.
  factory Settings.defaults() => Settings();

  /// Computes recommended values for the current device. Reads
  /// [DeviceMemory] for RAM-aware buffer sizes and accepts an [isTV]
  /// flag plus the current [layout] so multi-view-specific tuning can
  /// be applied. Preserves the same session-state fields as
  /// [Settings.defaults].
  ///
  /// Inputs:
  /// - [isTV] from `DeviceDetector.isTV()` — typically true on
  ///   Shield/Onn 4K/Fire TV, false on phones/tablets.
  /// - [layout] current multi-view selection. 2×2 reduces per-cell
  ///   budgets to leave RAM headroom for four concurrent decoders.
  ///
  /// DeviceMemory.init() must have run before calling this.
  factory Settings.optimisedFor({
    required bool isTV,
    required MultiViewLayout layout,
  }) {
    final s = Settings();

    // ── Buffer / demuxer ───────────────────────────────────────────
    // DeviceMemory already provides per-RAM defaults. For 2×2 multi-view
    // we further trim the mini-demuxer because four cells will run
    // concurrently; for 1×2 the standard mini default has enough room.
    s.bufferSizeMB = DeviceMemory.defaultBufferSizeMb;
    s.liveDemuxerMaxMB = DeviceMemory.defaultLiveDemuxerMb;
    s.vodDemuxerMaxMB = DeviceMemory.defaultLiveDemuxerMb + 64;
    s.miniDemuxerMaxMB = switch (layout) {
      MultiViewLayout.twoByTwo =>
          (DeviceMemory.defaultMiniDemuxerMb * 0.75).round().clamp(16, 256),
      _ => DeviceMemory.defaultMiniDemuxerMb,
    };

    // ── Cache seconds ──────────────────────────────────────────────
    // Live read-ahead chosen so the buffer absorbs a 30 s edge-cycle
    // gracefully. TVs typically have wired networks and benefit from
    // a longer read-ahead; phones move between Wi-Fi cells so we cap
    // a little lower to keep recovery snappy.
    s.liveCacheSecs = isTV ? 45 : 30;
    s.vodCacheSecs = 60;

    // ── Retry / reconnect timing ───────────────────────────────────
    // openTimeoutSecs needs to be longer on TVs (slower mediacodec
    // init on Tegra/older chipsets); shorter on phones.
    s.openTimeoutSecs = isTV ? 20 : 12;
    s.bufferingWatchdogSecs = isTV ? 15 : 10;
    s.stableThresholdSecs = 15;     // matches fix7/fix17 stable-counter window
    s.startupGraceMs = isTV ? 1500 : 800;  // slower probe on TVs
    s.streamCompletedDelayMs = 2000;       // unchanged from default

    // ── Hardware decode ────────────────────────────────────────────
    // Always enabled by default. The MpvEngine code already routes TV
    // hardware to mediacodec-copy (fix13). Software decode for preview
    // mode is handled inside _applyMpvOptions; we don't expose that here.
    s.hwDecode = true;

    // ── Pre-warm ───────────────────────────────────────────────────
    // TVs benefit from prewarm (D-pad-driven navigation produces clear
    // focus intent); phones less so because touch-driven scrolling
    // sweeps focus rapidly across tiles.
    s.preWarmOnFocus = isTV;

    // ── Stream scanner ─────────────────────────────────────────────
    // Faster phones can scan more streams in the same time; TVs get
    // a more conservative count.
    s.streamScanMaxCount = isTV ? 15 : 20;
    s.streamScanTimeoutSecs = isTV ? 10 : 8;

    // ── Engine selection ───────────────────────────────────────────
    s.forcedEngine = EngineType.auto;

    // ── Low-latency mode ───────────────────────────────────────────
    // OFF by default. Low-latency mode disables demuxer back-bytes and
    // tightens cache, which on shaky providers produces more
    // disconnects than it prevents. Users who want it can flip it
    // back on manually.
    s.lowLatency = false;

    return s;
  }
```

The factory uses the static getters from `DeviceMemory`, which are
already RAM-aware. Make sure `DeviceMemory.init()` has been called
before invoking `Settings.optimisedFor`; the app already does this in
`main.dart`.

Add the required imports at the top of `lib/models/settings.dart` if
not already present:

```dart
import 'package:open_tv/backend/device_memory.dart';
```

`MultiViewLayout` and `EngineType` are already imported (lines 1, 3).

---

## Fix 22.2 — Wire the two actions into Settings UI

**File:** `lib/settings_view.dart`

Add a new `_sectionHeader("Reset")` section between the existing
"Backup & Restore" and "App" sections (around line 1763 — right after
the "Import settings from file" `ListTile` and the `Divider()` that
follows it).

**Insert before line 1766 (the existing `_sectionHeader("App")` line):**

```dart
                  // ── Reset ─────────────────────────────────────────────────
                  _sectionHeader("Reset"),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text("Reset settings to defaults"),
                    subtitle: const Text(
                      "Restore the hardcoded defaults. Preserves sources, "
                      "debug-logging toggle, and any active multi-view "
                      "channel layout.",
                    ),
                    onTap: () => _confirmAndResetSettings(
                      title: 'Reset to defaults?',
                      body: 'This restores every tunable setting to its '
                          'hardcoded default. Your sources, credentials, '
                          'debug-logging toggle, and multi-view channel '
                          'assignments are preserved.\n\n'
                          'Some changes (buffer size) take effect on the '
                          'next app launch.',
                      builder: () => Settings.defaults(),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.auto_fix_high),
                    title: const Text("Optimise for this device"),
                    subtitle: const Text(
                      "Calculate the best values for your device's RAM, "
                      "form factor, and current multi-view layout.",
                    ),
                    onTap: () async {
                      final isTV = await DeviceDetector.isTV();
                      if (!mounted) return;
                      _confirmAndResetSettings(
                        title: 'Optimise for this device?',
                        body: 'This computes recommended values for your '
                            'device based on:\n\n'
                            '  • Detected RAM: ${DeviceMemory.totalMb} MB\n'
                            '  • Form factor: ${isTV ? "TV" : "phone/tablet"}\n'
                            '  • Multi-view layout: '
                            '${_layoutLabel(settings.multiViewLayout)}\n\n'
                            'Your sources, credentials, debug-logging '
                            'toggle, and multi-view channel assignments '
                            'are preserved.\n\n'
                            'Some changes (buffer size) take effect on '
                            'the next app launch.',
                        builder: () => Settings.optimisedFor(
                          isTV: isTV,
                          layout: settings.multiViewLayout,
                        ),
                      );
                    },
                  ),

                  const Divider(),
```

Add two helper methods on the `_SettingsViewState` class (anywhere
near `updateSettings()`):

```dart
  /// Human-readable label for a [MultiViewLayout] value, used in the
  /// optimise-settings confirmation dialog.
  String _layoutLabel(MultiViewLayout l) => switch (l) {
        MultiViewLayout.none => 'Off',
        MultiViewLayout.oneByTwo => '1×2',
        MultiViewLayout.twoByTwo => '2×2',
      };

  /// Shared confirmation + apply flow for both reset actions. [builder]
  /// produces the fresh Settings instance; this method takes care of
  /// preserving session-state fields (debug logging, multi-view layout
  /// and cell assignments) and persisting the result.
  Future<void> _confirmAndResetSettings({
    required String title,
    required String body,
    required Settings Function() builder,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Build the fresh Settings, then copy back session-state fields
    // that the user wouldn't expect a "reset" to clobber.
    final fresh = builder()
      ..debugLogging = settings.debugLogging
      ..multiViewLayout = settings.multiViewLayout
      ..multiViewCells1x2 = settings.multiViewCells1x2
      ..multiViewCells2x2 = settings.multiViewCells2x2;

    setState(() => settings = fresh);
    await updateSettings();

    if (!mounted) return;
    AppLog.info('Settings: reset applied — $title');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Settings updated. Restart the app for buffer-size changes '
          'to take full effect.',
        ),
      ),
    );
  }
```

Add the required imports at the top of `lib/settings_view.dart` if not
already present:

```dart
import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/multi_view_layout.dart';
// AppLog and Settings are already imported in this file.
```

---

## Fix 22.3 — `setEnabled` check on debug logging (precaution)

Because `_confirmAndResetSettings` preserves `debugLogging` rather than
resetting it, no `AppLog.setEnabled()` call is needed in the reset
flow. The flag's value doesn't change.

If the user picks "Reset to defaults" while debug logging is ON, the
log will continue capturing the reset event itself (the
`AppLog.info('Settings: reset applied — …')` line above). This is
intentional — it provides a paper trail when diagnosing user reports.

---

## Optimise-mode value table

For reference / QA, here are the values `Settings.optimisedFor`
produces for each combination. RAM tiers are the DeviceMemory tiers.

| Field | Phone, 2 GB | Phone, 4 GB | Phone, 8 GB | TV, 3 GB (Onn 4K) | TV, 8 GB (Shield Pro) |
|---|---|---|---|---|---|
| `bufferSizeMB` | 64 | 128 | 192 | 64 | 192 |
| `liveDemuxerMaxMB` | 100 | 150 | 200 | 100 | 200 |
| `vodDemuxerMaxMB` | 164 | 214 | 264 | 164 | 264 |
| `miniDemuxerMaxMB` (1×2) | 24 | 32 | 48 | 24 | 48 |
| `miniDemuxerMaxMB` (2×2) | 18 | 24 | 36 | 18 | 36 |
| `liveCacheSecs` | 30 | 30 | 30 | 45 | 45 |
| `vodCacheSecs` | 60 | 60 | 60 | 60 | 60 |
| `openTimeoutSecs` | 12 | 12 | 12 | 20 | 20 |
| `bufferingWatchdogSecs` | 10 | 10 | 10 | 15 | 15 |
| `stableThresholdSecs` | 15 | 15 | 15 | 15 | 15 |
| `startupGraceMs` | 800 | 800 | 800 | 1500 | 1500 |
| `streamCompletedDelayMs` | 2000 | 2000 | 2000 | 2000 | 2000 |
| `hwDecode` | ON | ON | ON | ON | ON |
| `preWarmOnFocus` | OFF | OFF | OFF | ON | ON |
| `streamScanMaxCount` | 20 | 20 | 20 | 15 | 15 |
| `streamScanTimeoutSecs` | 8 | 8 | 8 | 10 | 10 |
| `lowLatency` | OFF | OFF | OFF | OFF | OFF |
| `forcedEngine` | auto | auto | auto | auto | auto |

---

## Test plan

1. Apply fix22 (the two factory methods + the UI section + the helper
   methods).
2. Manually edit a few settings to obviously-wrong values
   (`liveCacheSecs = 1`, `bufferSizeMB = 16`, `lowLatency = ON`).
3. Open Settings → scroll to "Reset" section → tap "Reset settings to
   defaults". Confirm dialog → tap Apply.
   - **Expected:** all values restored to `Settings()` defaults except
     `debugLogging`, `multiViewLayout`, and the two cell-assignment
     strings.
   - Snackbar: "Settings updated. Restart the app for buffer-size
     changes to take full effect."
   - Log: `Settings: reset applied — Reset to defaults?`
   - Log: `Settings: saved`
4. Edit settings again to wrong values.
5. Tap "Optimise for this device". The confirmation should show:
   - Detected RAM (matches `DeviceMemory.totalMb`)
   - Form factor (TV or phone/tablet from `DeviceDetector`)
   - Multi-view layout (matches current setting, including the
     human-readable label)
6. Tap Apply.
   - **Expected:** values match the appropriate column in the table
     above.
7. Test the multi-view-layout sensitivity: with layout=oneByTwo, note
   `miniDemuxerMaxMB`. Change to twoByTwo, re-run Optimise. Confirm
   `miniDemuxerMaxMB` drops to ~75 % of the 1×2 value.
8. With debug logging ON, run Reset. Confirm debug logging stays ON.
   With debug logging OFF, run Reset. Confirm debug logging stays OFF.
9. Run Optimise on a known-TV device (Shield/Onn 4K) and confirm
   `startupGraceMs=1500`, `preWarmOnFocus=true`,
   `openTimeoutSecs=20`. Run on a phone and confirm the opposites.

---

## Notes for the implementer

- `Settings()` already has all defaults baked into the constructor — no
  duplication required in `Settings.defaults`.
- `Settings.optimisedFor` deliberately writes a value to **every**
  tunable field even when the value matches the default. This means a
  user who's previously edited `vodCacheSecs` to 999 gets it reset to
  60 by Optimise, not silently left at 999. The factory is meant to
  produce a fully-specified configuration, not a diff.
- The `SnackBar` mentioning "Restart the app for buffer-size changes
  to take full effect" is honest: `bufferSizeMB` is read into
  `mk.PlayerConfiguration` at engine construction (line 33 of
  `mpv_engine.dart`) and a running engine won't pick up the new value.
  All other settings take effect on the next channel open.
- No SQL schema changes are needed. The reset writes through
  `SettingsService.updateSettings(settings)`, which already persists
  every column.
- The text "Optimise" uses the British spelling to match the rest of
  the codebase (e.g. "centred" in `multi_view_cell.dart`); switch to
  "Optimize" if you prefer the American form.
