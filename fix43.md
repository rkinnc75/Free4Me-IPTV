# fix43.md — NDK version declaration (v1.17.2)

Odd-number fix file per standing rule. Previous fix: fix41.

---

## Context

The `jni` package (transitive via `media_kit`) declares a minimum NDK of 28.2.13676358.
The workflow previously installed NDK 27.0.12077973 and `android/app/build.gradle` had
no explicit `ndkVersion` declaration, so AGP defaulted to 27 and emitted a warning on
every build:

```
Your project is configured with Android NDK 27.0.12077973, but the following
plugin(s) depend on a different Android NDK version:
- jni requires Android NDK 28.2.13676358
Fix this issue by using the highest Android NDK version (they are backward
compatible). Add the following to android/app/build.gradle:
    android {
        ndkVersion = "28.2.13676358"
        ...
    }
```

Both NDK versions are already installed on the host Mac (confirmed in BUILD-ENV.md §3
NDK table). The fix is to explicitly declare NDK 28.2 in the project and install it in CI.

---

## Changes (v1.17.2)

### 1. `android/app/build.gradle`
Added `ndkVersion = "28.2.13676358"` to the `android {}` block immediately after
`compileSdk = 36`. This is the exact remediation the Flutter build output recommends.

### 2. `.github/workflows/release.yml`
- Updated `packages:` in the `Set up Android SDK + NDK` step from
  `ndk;27.0.12077973` → `ndk;28.2.13676358`.
- Updated the top-of-file toolchain comment to match.

### 3. `BUILD-ENV.md`
Updated section 14 open-issues note to reflect the NDK mismatch is now resolved.

---

## Deferred items → fix45

### KGP deprecation warnings (8 plugins)
Build transcript (BUILD-ENV.md §5a) shows:
```
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP):
audio_session, device_info_plus, file_picker, package_info_plus,
url_launcher_android, video_player_android, wakelock_plus, workmanager_android
Future versions of Flutter will fail to build if your app uses plugins that apply KGP.
```
Fixing requires major-version bumps with breaking API changes:
- `device_info_plus` 12.4.0 → 13.1.0
- `file_picker` 10.3.10 → 11.0.2
- `package_info_plus` 9.0.1 → 10.1.0
- `url_launcher_android`, `video_player_android`, `wakelock_plus`, `workmanager_android`
  via their parent direct deps

Each call site in the app code must be audited for API changes before bumping.
Warnings are not errors today; target fix45.

### sqlite3_flutter_libs EOL
`flutter pub get` reports `sqlite3_flutter_libs 0.5.42 (0.6.0+eol available)`.
The `+eol` tag signals this package version is end-of-life. We're on the
still-functional 0.5.42. Investigate the migration path (likely `sqlite3` package
direct or a successor) and plan upgrade in fix45.

### 23 packages with newer incompatible versions
All are major-version breaks beyond our `^` constraints. None are actionable without
API review. Carry to fix45.

---

## Verification
CI build for v1.17.2 should complete without the NDK version-mismatch warning.
The KGP and outdated-package warnings will still appear until fix45 ships.
