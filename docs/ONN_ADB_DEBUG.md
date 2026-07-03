# onn 4K Plus — ADB connection + on-device debugging runbook

How to connect to the test box (onn 4K Plus Streaming, the primary verify
device) over the LAN and debug a RELEASE build of the app. Written for any
coder (desktop or phone) who needs to reproduce the same debug loop.

## 1. The device

| Fact | Value |
|---|---|
| Device | onn 4K Plus Streaming (Google TV) |
| adb identity | `product:coffey model:onn__4K_Plus_Streaming device:coffey` |
| LAN address | `10.0.168.194:5555` (DHCP — if unreachable, re-check the IP in the TV's Settings → Network, or on the router) |
| App package | `me.free4me.iptv` |
| RAM | ~2 GB (`DeviceMemory: totalMb=1925` in the app log) |
| Screen | 1920×1080 (app UI is capped at 1080p on this box) |

## 2. Get adb

- **Desktop (macOS/Linux):** Android platform-tools (`brew install
  android-platform-tools`, or the SDK's `platform-tools/` directory —
  e.g. `~/Library/Android/sdk/platform-tools` on macOS).
- **Phone (Termux):** `pkg install android-tools` gives a full `adb`.
  The phone must be on the same Wi-Fi/LAN as the box.

## 3. Connect

```sh
adb connect 10.0.168.194:5555
adb devices -l         # expect: 10.0.168.194:5555 device product:coffey ...
```

- **First connection from a new machine:** the TV shows an "Allow USB
  debugging?" RSA-key prompt. Someone must physically tick **Always allow
  from this computer** and accept it on the TV — until then the device
  shows as `unauthorized`.
- **`connection refused` / nothing listening:** network debugging got
  disabled or the box rebooted out of tcpip mode. On the TV: Settings →
  System → About → click *Android TV OS build* 7× to unlock Developer
  options, then Developer options → enable **USB debugging** / network
  debugging. (Or, with a USB cable once: `adb tcpip 5555`.)
- **Stale/hung connection** (box slept, Wi-Fi blip): `adb disconnect
  10.0.168.194:5555 && adb connect 10.0.168.194:5555`.
- If more than one device/emulator is attached, pass
  `-s 10.0.168.194:5555` on **every** adb command. The examples below
  include it.

## 4. What you CAN'T do (release build)

The installed app is a release build — **not debuggable**:

- `adb shell run-as me.free4me.iptv ...` fails (`package not debuggable`).
  → **No direct access to db.sqlite / epg.sqlite. No on-device sqlite3
  against the app's data.** All DB conclusions come from the app's own
  logging (below).
- No Flutter DevTools / attach. Verification is logcat + screenshots +
  synthetic input only.

## 5. Logging — the main debug channel

`AppLog` writes to logcat under the **`flutter`** tag as
`[timestamp] [LEVEL] message`:

```sh
adb -s 10.0.168.194:5555 logcat -c                 # clear buffer before a test
adb -s 10.0.168.194:5555 logcat -d | grep "flutter :"       # dump what happened
timeout 60 adb -s 10.0.168.194:5555 logcat | grep "flutter :"  # live capture
```

High-signal greps:

| Grep | What it tells you |
|---|---|
| `App started` | version/build actually running + search method |
| `SLOW SQL` | any query >2 s, with the SQL text |
| `fix418 PLAN` | the EXPLAIN QUERY PLAN for the slow query above it — ground truth for index usage |
| `Sql.search` | browse/search timings (`branch=... rows=N sql=Nms`) |
| `ensureBrowseIndexesPresent` | fix628 index self-heal. **Silence = healthy** (all 16 canonical channels indexes present). `rebuilding N missing` = an interrupted refresh dropped indexes |
| `EPG:` / `EpgRematch` / `EpgDb` | EPG download/match/staleness activity |
| `database is locked` / `code 5` | cross-isolate epg.sqlite contention (fix625 retries should absorb it) |
| `error\|exception` | anything unhandled |

Notes:
- Source/EPG hosts + credentials are **redacted** in the log (fix626) —
  `<Emjay_EPG_HOST>` etc. That's expected, not a bug.
- `EpgDb: programmes=N` at startup takes ~25 s on a ~1.7M-row guide
  (a count(*) diagnostic). Known, harmless.

## 6. Common operations

```sh
# What version is installed?
adb -s 10.0.168.194:5555 shell dumpsys package me.free4me.iptv | grep -E "versionName|versionCode"

# Install a CI build (download the arm64 APK from the GitHub release first)
adb -s 10.0.168.194:5555 install -r Free4Me-IPTV-X.Y.Z-arm64.apk

# Cold-start cycle (fresh logs)
adb -s 10.0.168.194:5555 logcat -c
adb -s 10.0.168.194:5555 shell am force-stop me.free4me.iptv
adb -s 10.0.168.194:5555 shell monkey -p me.free4me.iptv -c android.intent.category.LAUNCHER 1

# Screenshot (screen is 1920x1080)
adb -s 10.0.168.194:5555 exec-out screencap -p > screen.png

# Drive the UI like a remote
adb -s 10.0.168.194:5555 shell input keyevent KEYCODE_DPAD_UP     # DOWN/LEFT/RIGHT
adb -s 10.0.168.194:5555 shell input keyevent KEYCODE_DPAD_CENTER # OK/select
adb -s 10.0.168.194:5555 shell input keyevent KEYCODE_BACK
adb -s 10.0.168.194:5555 shell input tap X Y   # direct tap, real 1920x1080 coords

# Is the app alive? (pid changes = it crashed/restarted)
adb -s 10.0.168.194:5555 shell pidof me.free4me.iptv
```

UI-driving tips: focus highlights are often invisible in screenshots — when
D-pad position is uncertain, take a screenshot after each step or use
`input tap` on the element's coordinates instead. TV remotes cannot
long-press (`onLongPress` never fires); the channel menu uses the held-OK
detector (fix586).

## 7. Measurement gotchas (avoid false alarms)

- **Measure at rest.** The first launch after an upgrade runs migrations +
  cold caches: expect one-off `SLOW SQL` 3–9 s bursts. Relaunch and
  re-measure before calling something a regression.
- **Don't measure during a refresh/re-match.** `withDroppedBrowseIndexes`
  intentionally drops the channels indexes mid-refresh; browse is slower by
  design until the rebuild.
- **KNOWN BUG (deferred, unnumbered — still present as of v2.2.47):**
  leaving the Settings screen
  while "Re-match all channels" or a source refresh is running ABORTS the
  operation partway (stale setState on the disposed progress dialog,
  `settings_view.dart:1326`). The app survives. Don't navigate away
  mid-operation during a test — and don't mistake the abort for a fix
  regression.
- Healthy baselines (v2.2.40, this box): grouped Live-category browse
  `sql=2-26ms`; ungrouped/All browse a few hundred ms warm; a page of
  browse results is `rows=36` (page size — NOT the table count).
- The box is a real user device: when done, leave the app in a sane state
  (launched or cleanly backed out), don't leave it force-stopped.

## 8. Verify checklist for a new build (the standard loop)

1. `adb install -r` the CI APK → `dumpsys` shows the new versionCode.
2. `logcat -c` → force-stop → launch → confirm `App started — version=...`
   and NO unexpected `[ERROR]`/exception in the first 60 s.
3. Confirm `ensureBrowseIndexesPresent` is silent (or completes its rebuild).
4. Exercise the changed area; grep `SLOW SQL` + `fix418 PLAN` to confirm
   the intended index/plan.
5. Screenshot the affected screens (guide grid populated, no error toasts).
6. Re-launch once more and re-check timings warm.
