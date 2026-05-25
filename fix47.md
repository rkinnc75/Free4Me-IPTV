# fix47.md — KGP plugin upgrade pass (v1.17.x)

Odd-number fix file (Mac session). Previous odd fix: fix45.

---

## Goal

Eliminate (or significantly reduce) the 8 KGP deprecation warnings that appear on
every build by upgrading the three direct dependencies whose new major versions are
known to use Flutter's built-in Kotlin instead of applying KGP manually.

---

## API audit results

### device_info_plus 12→13
**Surface in this codebase:**
- `DeviceInfoPlugin()` constructor
- `.androidInfo` → `AndroidDeviceInfo`; `.systemFeatures` → `List<String>`
- `.iosInfo` → `IosDeviceInfo`; `.model` → String; `.utsname.machine` → String

**Verdict:** Zero breaking changes for our usage. These fields are stable across
all 13.x releases. No app code changes required.

### package_info_plus 9→10
**Surface in this codebase:**
- `PackageInfo.fromPlatform()` — static async factory (4 call sites)
- `.version` — String property

**Verdict:** Zero breaking changes. The basic `PackageInfo` API has not changed
across any major version. No app code changes required.

### file_picker 10→11
**Surface in this codebase:**
- `FilePicker.platform.pickFiles()` — no-arg call (setup.dart)
- `FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'], withData: true)` — settings_io.dart
- `FilePicker.platform.saveFile(dialogTitle:, fileName:, bytes:)` — settings_io.dart export
- `FilePicker.platform.saveFile(dialogTitle:, fileName:, type:, allowedExtensions:, bytes:)` — settings_io.dart exportStringToFile
- `result.files.single.path` — nullable String
- `result.files.single.bytes` — nullable Uint8List

**Verdict:** Core APIs are stable. Expected: no code changes. The Mac build will
catch any breakage immediately.

**win32 split: ALL THREE PACKAGES BLOCKED (fix47 run, 2026-05-24).**

Three separate `flutter pub upgrade` runs confirmed the full picture:

| Package | New major | Requires | Blocked by |
|---|---|---|---|
| `device_info_plus` | ^13.0.0 | `win32 ^6.x` | `file_picker <12.0.0` needs `win32 ^5.x` |
| `file_picker` | ^11.0.0 / ^12.0.0 | `win32 ^5.x` (10/11) | conflicts with device_info_plus ^13 |
| `package_info_plus` | ^10.0.0 | `win32 ^6.x` | `device_info_plus ^12.3.0` needs `win32 ^5.x` |

There is **no partial upgrade path**. All three are in a circular win32 version
conflict. The ecosystem is split: old-major packages pin win32 ^5.x, new-major
packages pin win32 ^6.x.

All three constraints were reverted to their current stable majors with inline
comments in `pubspec.yaml` documenting the block.

**Unblock recipe (one pass, when file_picker 12.0.0 stable ships):**
```yaml
# pubspec.yaml — change all three at once:
device_info_plus: ^13.0.0
file_picker: ^12.0.0
package_info_plus: ^10.0.0
```
Then `flutter pub upgrade` + `flutter build apk` + commit lock + release.

---

## Changes made in sandbox

`pubspec.yaml` constraint bumps:
| Package | Before | After |
|---|---|---|
| `device_info_plus` | `^12.3.0` | `^13.0.0` |
| `file_picker` | `^10.2.0` | `^11.0.0` |
| `package_info_plus` | `^9.0.0` | `^10.0.0` |

No app Dart code was changed — the API audit confirmed our call sites are unaffected.

---

## Remaining KGP packages (not bumped — resolved via pub upgrade)

`audio_session`, `url_launcher_android`, `video_player_android`, `wakelock_plus`,
`workmanager_android` are either transitive deps or within their current `^`
constraint. `flutter pub upgrade` will pull the latest compatible patch/minor
versions. If those versions have migrated to built-in Kotlin the warnings will
disappear without constraint changes.

---

## Mac steps required

Run in this order:

```bash
cd /Users/builder/git/free4me-iptv
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="/Users/builder/tools/flutter/bin:$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"

flutter pub upgrade
flutter build apk --release 2>&1 | tee /tmp/fix47-build.txt
```

**If `flutter pub upgrade` fails with a version conflict** (likely win32):
- Open pubspec.yaml, revert `file_picker` to `^10.2.0`, save
- Re-run `flutter pub upgrade`

**If `flutter build apk` reports compilation errors:**
- Paste the error lines to the next Claude session — they'll identify exactly what API changed

**If the build succeeds:**
- Report whether the KGP warnings are gone, reduced, or unchanged
- Claude will then commit `pubspec.lock` + any code fixes + bump version + release

---

## `android.builtInKotlin` flag

`android/gradle.properties` currently has `android.builtInKotlin=false`.
Do NOT change this until after the build confirms all 8 KGP plugins are resolved.
Flipping to `true` while any plugin still applies KGP causes a Kotlin version
conflict at build time.
