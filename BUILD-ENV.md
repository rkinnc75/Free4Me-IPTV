# Free4Me-IPTV Build Environment

This file documents the exact local environment used by `bash scripts/build_and_release.sh` on the Mac. Audience: a downstream agent writing `.github/workflows/release.yml` for a sandboxed Linux runner.

Captured: 2026-05-23
Last successful release on this host: v1.15.7 (commit d500acc).
APK produced by the build run captured below: `build/app/outputs/flutter-apk/app-release.apk`, size 106,804,470 bytes.

---

## 1. Toolchain versions (verbatim)

### `flutter --version`

```
Flutter 3.44.0 - channel stable - https://github.com/flutter/flutter.git
Framework - revision 559ffa3f75 (7 days ago) - 2026-05-15 14:13:13 -0700
Engine - hash fcf463a2242790d1fdcd9d044f533080f5022e18 (revision 4c525dac5e) (7 days ago) - 2026-05-15 19:00:04.000Z
Tools - Dart 3.12.0 - DevTools 2.57.0
```

Resolved binary: `/Users/builder/tools/flutter/bin/flutter` (manual install, not Homebrew). Channel `stable`.

### `dart --version`

```
Dart SDK version: 3.12.0 (stable) (Fri May 8 01:51:14 2026 -0700) on "macos_arm64"
```

Resolved binary: `/Users/builder/tools/flutter/bin/dart` (the Dart bundled with Flutter). No standalone Dart SDK.

### `java -version` and `which java`

```
openjdk version "21.0.6" 2025-01-21
OpenJDK Runtime Environment (build 21.0.6+-13368085-b895.109)
OpenJDK 64-Bit Server VM (build 21.0.6+-13368085-b895.109, mixed mode)
```

```
which java -> /Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java
```

**JDK distribution: JetBrains Runtime (JBR) 21.0.6** — the JDK bundled with Android Studio. Not Temurin, not Oracle, not Zulu. JBR is OpenJDK 21 with JetBrains patches; Temurin 21 is the closest GitHub-Actions-friendly substitute.

### Gradle wrapper - `cd android && ./gradlew --version`

```
Gradle 8.14
Build time:    2025-04-25 09:29:08 UTC
Revision:      34c560e3be961658a6fbcd7170ec2443a228b109
Kotlin:        2.0.21
Groovy:        3.0.24
Ant:           Apache Ant(TM) version 1.10.15 compiled on August 25 2024
Launcher JVM:  21.0.6 (JetBrains s.r.o. 21.0.6+-13368085-b895.109)
Daemon JVM:    /Applications/Android Studio.app/Contents/jbr/Contents/Home (no JDK specified, using current Java home)
OS:            Mac OS X 26.3.1 aarch64
```

Wrapper distribution from `android/gradle/wrapper/gradle-wrapper.properties`:

```
distributionUrl=https\://services.gradle.org/distributions/gradle-8.14-all.zip
```

> Caveat: if `JAVA_HOME` is not set when invoking `./gradlew`, an old daemon previously launched under macOS system Java 8 (`/Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents/Home`) can be reused. With `JAVA_HOME` correctly pointing at JBR 21, the wrapper picks up Java 21 as shown above. Always set `JAVA_HOME` in CI.

### Android Gradle Plugin and Kotlin from `android/settings.gradle`

```groovy
plugins {
    id "dev.flutter.flutter-plugin-loader" version "1.0.0"
    id "com.android.application" version "8.13.2" apply false
    id "org.jetbrains.kotlin.android" version "2.2.20" apply false
}
```

So: **AGP 8.13.2**, **Kotlin 2.2.20** (declaration), **Kotlin 2.0.21** (Gradle's embedded build-language). Repos referenced by `pluginManagement.repositories`: `google()`, `mavenCentral()`, `gradlePluginPortal()`.

`android/build.gradle` adds `google()` and `mavenCentral()` to `allprojects.repositories`. No private Maven, no JitPack.

### Android SDK packages

`$ANDROID_HOME/cmdline-tools` is **not present** on this machine — Android Studio installed the SDK without the optional command-line tools, so `sdkmanager --list_installed` is unavailable. The SDK was instead populated by Android Studio's UI. Effective state by directory listing of `$ANDROID_HOME = /Users/builder/Library/Android/sdk`:

| SDK component | Versions present |
|---|---|
| `platforms/` | `android-33`, `android-35`, `android-36` |
| `build-tools/` | `35.0.0`, `35.0.1`, `36.0.0` |
| `ndk/` | `27.0.12077973`, `28.2.13676358` |
| `cmake/` | (single subdir) |
| `platform-tools/` | (present) |
| `emulator/` | (present, irrelevant for CI) |

The project's `android/app/build.gradle` declares `compileSdk = 36`, which selects `platforms/android-36` and `build-tools/36.0.0`. `ndkVersion` is **not** explicitly declared, so AGP 8.13.2 default (`27.0.12077973`) is used. The build emits a warning that the `jni` plugin asks for `28.2.13676358`; build still succeeds.

### Build script's effective Flutter SDK path

`scripts/build_and_release.sh` line 53 prepends `/Users/builder/tools/flutter/bin` to `PATH` before invoking `flutter build apk`. It does **not** set `JAVA_HOME` or `ANDROID_HOME` itself; those come from the parent shell's environment.

---

## 2. Environment variables

### Fresh login shell baseline

`/bin/bash -lc 'env | sort'` already exports the following relevant vars (from the user's shell init):

```
ANDROID_HOME=/Users/builder/Library/Android/sdk
ANDROID_SDK_ROOT=/Users/builder/Library/Android/sdk
JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home
PATH=...:/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin:/Users/builder/tools/flutter/bin:...
```

So the user's shell is already pre-staged with everything needed. The release script only adds `/Users/builder/tools/flutter/bin` to `PATH` defensively.

### Vars actually required by a successful run

Captured immediately before invoking the build:

```
ANDROID_HOME=/Users/builder/Library/Android/sdk
ANDROID_SDK_ROOT=/Users/builder/Library/Android/sdk
JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home
PATH=/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin:/Users/builder/tools/flutter/bin:<rest of PATH>
```

### Diff vs. fresh shell

There is **no env diff** at the point the script runs — the user's shell already has the vars set. The script-level export at line 53 (`export PATH="$PATH:/Users/builder/tools/flutter/bin"`) is redundant on this host but harmless.

### Minimum env required by CI

For a sandboxed Linux runner the workflow must explicitly set:

| Var | Value (Linux equivalent) | Source |
|---|---|---|
| `JAVA_HOME` | output of `actions/setup-java` Temurin 21 step | required by Gradle daemon |
| `ANDROID_HOME` | output of `android-actions/setup-android` (typically `/usr/local/lib/android/sdk`) | required by AGP |
| `ANDROID_SDK_ROOT` | same as `ANDROID_HOME` | legacy alias still read by some tools |
| `PATH` | must include Flutter SDK `bin/` and `$JAVA_HOME/bin` | both need to be PATH-resolvable |

`local.properties` is gitignored (`android/.gitignore` line 6) — the CI workflow must either generate one before `flutter build` or pass `--android-sdk` / use `ANDROID_HOME` env (AGP picks up `ANDROID_HOME` if `local.properties:sdk.dir` is absent).

---

## 3. Pre-build codegen

**There is no codegen step.** Verified by:

- `pubspec.yaml` `dev_dependencies` only contains `flutter_test` and `flutter_lints` — no `build_runner`, no `freezed`, no `json_serializable`, no `intl_utils`.
- `pubspec.lock` does not contain `build_runner` (full grep confirmed empty).
- No `build.yaml`, no `l10n.yaml` at repo root.
- No `lib/l10n/` directory.
- No `*.g.dart` or `*.freezed.dart` files in `lib/`.
- No `tool/` directory at repo root.
- Only `scripts/build_and_release.sh` exists in `scripts/`.

The full pre-build sequence used by the script is:

```
flutter pub get           (implicit on first build, no separate command in script)
flutter build apk --release
```

Nothing else needs to run for the APK to be functionally identical to the shipped artifact.

`flutter build apk` itself will:

1. Resolve and download Pub dependencies (cached at `~/.pub-cache/`).
2. Generate Flutter native plugin glue (.flutter-plugins-dependencies, .dart_tool/).
3. Invoke Gradle `assembleRelease` task in `android/`.
4. Tree-shake icon fonts (`MaterialIcons-Regular.otf` is reduced 99.5%).
5. Produce a fat APK at `build/app/outputs/flutter-apk/app-release.apk` (single APK, all four ABIs bundled — see Section 6).

---

## 4. Signing

The release APK is **debug-signed**. Confirmed in `android/app/build.gradle`:

```groovy
buildTypes {
    release {
        // TODO: Add your own signing config for the release build.
        // Signing with the debug keys for now, so `flutter run --release` works.
        signingConfig = signingConfigs.debug
    }
}
```

There is no release keystore in the repo:

- `android/app/*.keystore` — none.
- `android/app/*.jks` — none.
- `android/key.properties` — does not exist.
- No alternate signing config in any branch (`git branch -a` not exhaustively checked, but the script does not reference any).

The default debug keystore used is `~/.android/debug.keystore` (auto-generated by Android Studio on first install). Fingerprint:

```
Keystore type: PKCS12
Keystore provider: SunJSSE

Alias name: androiddebugkey
Creation date: May 14, 2025
Entry type: PrivateKeyEntry
Owner: C=US, O=Android, CN=Android Debug
Issuer: C=US, O=Android, CN=Android Debug
Serial number: 1
Valid from: Wed May 14 12:16:35 EDT 2025 until: Fri May 07 12:16:35 EDT 2055

SHA1:   E6:D0:73:16:DE:B6:4C:E6:C2:AF:51:EC:C2:D1:46:DF:E2:6D:C3:CB
SHA256: EE:69:26:45:F1:EA:A0:DF:FB:DD:62:19:3A:EB:13:AF:8F:B3:86:53:82:93:67:B3:D9:CD:14:83:F6:4C:4D:A1
Signature algorithm name: SHA256withRSA
Subject Public Key Algorithm: 2048-bit RSA key
```

**Critical for CI continuity:** Android signs APKs with whatever debug keystore the build environment generates; this fingerprint will **not** match a CI-generated debug keystore, and the Play installer will reject side-by-side updates if the user has the local-built APK and then installs a CI-built APK signed with a different debug key. Two ways to handle:

1. **Commit the host's `~/.android/debug.keystore` as a CI secret** (decode in workflow, place at `~/.android/debug.keystore` before `flutter build apk`). Existing user installs continue to update cleanly.
2. **Switch to a release keystore now**, generated and stored as a secret. This is the cleaner long-term path; existing user installs would need a one-time uninstall/reinstall.

The default Android debug keystore password is `android` for both the store and the key alias `androiddebugkey`.

---

## 5. Verbatim build transcript

> **Why partial:** at the moment this file was being authored, the working tree contained an in-flight `v1.15.8` (uncommitted edits to `pubspec.yaml`, `lib/multi_view_cell.dart`, `lib/settings_view.dart`, `lib/channel_picker_screen.dart`, `lib/whats_new_modal.dart`, `AGENTS.md`). Running the **full** `bash scripts/build_and_release.sh` would have committed and shipped those as `v1.15.8` as a side effect of capturing a transcript, which was not approved. Instead: the **build portion** below was captured live (the expensive, network-touching, environment-sensitive part). The **post-build portion** is documented from `scripts/build_and_release.sh` source plus the receipts of the most recent successful run (`v1.15.7`, commit `d500acc`, GH release id `328222181`).

### 5a. Build-portion transcript (live capture, exit code 0, ~96.7 s gradle)

Captured via:

```bash
export PATH="/Users/builder/tools/flutter/bin:$PATH"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$PATH"
cd /Users/builder/git/free4me-iptv
flutter clean
flutter pub get
flutter build apk --release 2>&1 | tee /tmp/release-transcript.txt
```

Effective env at invocation time (from `env | sort | grep -E '...'`):

```
ANDROID_HOME=/Users/builder/Library/Android/sdk
ANDROID_SDK_ROOT=/Users/builder/Library/Android/sdk
JAVA_HOME=/Applications/Android Studio.app/Contents/jbr/Contents/Home
PATH=/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin:/Users/builder/tools/flutter/bin:<plus rest>
```

Output (verbatim, 70 lines):

```
Resolving dependencies...
Downloading packages...
  code_assets 1.0.0 (1.1.0 available)
  dbus 0.7.12 (0.7.13 available)
  device_info_plus 12.4.0 (13.1.0 available)
  device_info_plus_platform_interface 7.0.3 (8.1.0 available)
  file_picker 10.3.10 (11.0.2 available)
  hooks 1.0.3 (2.0.0 available)
  image 4.8.0 (4.9.0 available)
  matcher 0.12.19 (0.12.20 available)
  meta 1.18.0 (1.18.2 available)
  native_toolchain_c 0.17.6 (0.19.0 available)
  objective_c 9.3.0 (9.4.1 available)
  package_info_plus 9.0.1 (10.1.0 available)
  package_info_plus_platform_interface 3.2.1 (4.1.0 available)
  sqlite3 2.9.4 (3.3.1 available)
  sqlite3_flutter_libs 0.5.42 (0.6.0+eol available)
  sqlite3_web 0.4.1 (0.7.1 available)
  sqlite_async 0.13.1 (0.14.1 available)
  test_api 0.7.11 (0.7.12 available)
  vector_math 2.2.0 (2.3.0 available)
  wakelock_plus 1.5.2 (1.6.1 available)
  win32 5.15.0 (6.2.0 available)
  win32_registry 2.1.0 (3.0.3 available)
  xml 6.6.1 (7.0.1 available)
Got dependencies!
23 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.
The following plugins do not support Swift Package Manager for ios:
  - workmanager_apple
  - media_kit_video
  - media_kit_libs_ios_video
This will become an error in a future version of Flutter. Please contact the plugin maintainers to request Swift Package Manager adoption.
The following plugins do not support Swift Package Manager for macos:
  - media_kit_video
  - media_kit_libs_macos_video
This will become an error in a future version of Flutter. Please contact the plugin maintainers to request Swift Package Manager adoption.
Running Gradle task 'assembleRelease'...
Downloading file from: https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-arm64-v8a.jar
Downloading file from: https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-armeabi-v7a.jar
Downloading file from: https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-x86_64.jar
Downloading file from: https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-x86.jar
Your project is configured with Android NDK 27.0.12077973, but the following plugin(s) depend on a different Android NDK version:
- jni requires Android NDK 28.2.13676358
Fix this issue by using the highest Android NDK version (they are backward compatible).
Add the following to /Users/builder/git/free4me-iptv/android/app/build.gradle:

    android {
        ndkVersion = "28.2.13676358"
        ...
    }
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): audio_session, device_info_plus, file_picker, package_info_plus, url_launcher_android, video_player_android, wakelock_plus, workmanager_android
Future versions of Flutter will fail to build if your app uses plugins that apply KGP.
Please check the changelogs of these plugins and upgrade to a version that supports Built-in Kotlin.
If no such version exists, report the issue to the plugin. If necessary, here is a guide on filing
an issue against a plugin: https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers#report-incompatible-kotlin-gradle-plugin-usage-to-plugin-authors
If you are a plugin author, please migrate your plugin to Built-in Kotlin using this guide: https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors
Font asset "MaterialIcons-Regular.otf" was tree-shaken, reducing it from 1645184 to 8300 bytes (99.5% reduction). Tree-shaking can be disabled by providing the --no-tree-shake-icons flag when building your app.
warning: [options] source value 8 is obsolete and will be removed in a future release
warning: [options] target value 8 is obsolete and will be removed in a future release
warning: [options] To suppress warnings about obsolete options, use -Xlint:-options.
3 warnings
warning: [options] source value 8 is obsolete and will be removed in a future release
warning: [options] target value 8 is obsolete and will be removed in a future release
warning: [options] To suppress warnings about obsolete options, use -Xlint:-options.
3 warnings
Running Gradle task 'assembleRelease'...                           96.7s
✓ Built build/app/outputs/flutter-apk/app-release.apk (106.8MB)
```

Notes on the warnings (all non-fatal, all present in the host's working v1.15.7 release too):

- "23 packages have newer versions" — Pub resolves to satisfiable versions; not an error.
- Swift Package Manager warnings — iOS/macOS only, irrelevant for Android CI.
- NDK 27 vs 28 — `jni` plugin asks for newer NDK, AGP defaults to 27, build proceeds. Both NDKs are installed locally; CI must install at least 27.0.12077973 (or newer) and either accept the warning or set `ndkVersion = "27.0.12077973"` explicitly in `android/app/build.gradle`.
- KGP plugin warnings — eight Flutter plugins still apply Kotlin Gradle Plugin manually. Will become a hard error in a future Flutter release; tracked but not blocking today.
- "source value 8 / target value 8 is obsolete" — emitted twice (3 warnings each). Comes from one of the transitive plugins still targeting Java 8. Project's own code targets Java 11 (`compileOptions JavaVersion.VERSION_11` in `android/app/build.gradle`).
- Tree-shaking — informational; reduces APK size.

### 5b. Post-build phase (from `scripts/build_and_release.sh` source + v1.15.7 receipts)

After `flutter build apk --release` succeeds, the script does the following — verbatim commands and their observed output from the actual `v1.15.7` run on this host:

**Step b1: copy the APK to `~/Downloads/` with the version-tagged name.**

```bash
APK_SRC="$REPO_DIR/build/app/outputs/flutter-apk/app-release.apk"
APK_DOWNLOADS="$HOME/Downloads/Free4Me-IPTV-${VERSION}-arm64.apk"
cp "$APK_SRC" "$APK_DOWNLOADS"
```

This is purely a local convenience for sideloading; CI does not need it. Observed from `~/Downloads/`:

```
-rw-r--r--  Free4Me-IPTV-1.15.5-arm64.apk  106706054 bytes
-rw-r--r--  Free4Me-IPTV-1.15.6-arm64.apk  106788086 bytes
-rw-r--r--  Free4Me-IPTV-1.15.7-arm64.apk  106788082 bytes
```

The `-arm64` suffix in the filename is **misleading**: the build command is `flutter build apk --release` *without* `--split-per-abi`, so the resulting APK is a single fat APK containing four ABIs (`arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`) — confirmed by the four `default-<abi>.jar` libmpv downloads in the build transcript. The host has historically named this artifact `*-arm64.apk` because the target audience is Android TV (arm64). For CI, keep the name convention or change to `*-universal.apk`; either works.

**Step b2: update `version.json` (consumed by the in-app update checker).**

Inline Python script extracts the bullet list for the current version from `lib/whats_new_modal.dart` and writes:

```json
{
  "latest": "1.15.7",
  "releaseUrl": "https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/v1.15.7",
  "minSupportedAndroidApi": 21,
  "criticalUpdate": false,
  "releaseNotes": "..."
}
```

The Python is ~50 lines starting at line 63 of the script and uses `json`, `pathlib`, `re` from the stdlib only. No third-party Python deps. Python interpreter must be `python3` (`python3 -` heredoc). The script writes back to `version.json` and stages it for commit.

**Step b3: git stage + commit + push.**

```bash
git remote add origin git@github.com:rkinnc75/Free4Me-IPTV.git    # only if missing
git add -A
git diff --cached --quiet || git commit -m "v1.15.7: release build"
git push origin main
```

Uses **SSH** transport (`git@github.com:...`) and pulls the SSH key from `~/.ssh/id_rsa`. If the agent runs the script in a fresh shell, lines 39-49 attempt `ssh-add` against `~/.ssh/id_rsa` (with passphrase from `~/.ssh/id_rsa.passphrase` if present). For CI, replace with HTTPS push using `GITHUB_TOKEN` instead — there is no SSH-only requirement in the repo.

Observed output from the v1.15.7 run:

```
[main d500acc] v1.15.7: release build
 4 files changed, 53 insertions(+), 22 deletions(-)
 Pushing to GitHub
X11 forwarding request failed on channel 0
To github.com:rkinnc75/Free4Me-IPTV.git
   3f2abe4..d500acc  main -> main
```

The `X11 forwarding request failed` line is benign noise from the host's SSH config; not a failure.

**Step b4: read GitHub PAT from macOS Keychain.**

```bash
GITHUB_TOKEN=$(security find-internet-password -s "api.github.com" -a "rkinnc75" -w 2>/dev/null)
```

Keychain entry confirmed present:

```
keychain: /Users/builder/Library/Keychains/login.keychain-db
service:  api.github.com
account:  rkinnc75
label:    Free4Me-IPTV release token
type:     classic PAT (40 chars, prefix ghp_)
created:  2026-05-19
```

**Required scope: `repo`** (because the script creates releases and uploads release assets via the REST API on the private-allowed `rkinnc75/Free4Me-IPTV` repo). No additional scopes used. The CI workflow replaces this with the built-in `GITHUB_TOKEN` (which has the equivalent of `contents:write` when granted via `permissions:` block).

**Step b5: idempotent release-creation + asset upload.**

Three REST calls against `api.github.com`:

```
GET   /repos/rkinnc75/Free4Me-IPTV/releases/tags/v1.15.7
POST  /repos/rkinnc75/Free4Me-IPTV/releases                    (only if GET returned 404)
GET   /repos/rkinnc75/Free4Me-IPTV/releases/{id}/assets        (idempotency: delete pre-existing same-name asset)
DELETE/repos/rkinnc75/Free4Me-IPTV/releases/assets/{asset_id}  (only if pre-existing found)
POST  https://uploads.github.com/repos/rkinnc75/Free4Me-IPTV/releases/{id}/assets?name={APK_NAME}
       Content-Type: application/vnd.android.package-archive
       --data-binary @<APK path>
```

All authenticated via `Authorization: token $GITHUB_TOKEN`. Body of the create-release POST is built with inline Python heredoc to avoid shell-quoting hazards.

Observed output from v1.15.7 (verbatim, only the final lines):

```
 Creating GitHub release v1.15.7
 Release created (id=328222181)
 Uploading Free4Me-IPTV-1.15.7-arm64.apk

 Done! Release live at:
  https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/v1.15.7

 APK download URL:
  https://github.com/rkinnc75/Free4Me-IPTV/releases/download/v1.15.7/Free4Me-IPTV-1.15.7-arm64.apk
```

---

## 6. APK output location and naming

| Stage | Path |
|---|---|
| `flutter build apk --release` writes | `build/app/outputs/flutter-apk/app-release.apk` |
| Companion sha1 file | `build/app/outputs/flutter-apk/app-release.apk.sha1` |
| Local copy after script step b1 | `~/Downloads/Free4Me-IPTV-${VERSION}-arm64.apk` |
| Uploaded asset name on GH release | `Free4Me-IPTV-${VERSION}-arm64.apk` |

`${VERSION}` is parsed from `pubspec.yaml` line 19 by:

```bash
VERSION=$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}' | cut -d+ -f1)
```

For `version: 1.15.7+66`, this yields `1.15.7`. The git tag is `v${VERSION}` (so `v1.15.7`). The `+66` build number stays in `pubspec.yaml` only and is not used in any artifact name.

APK live size from the just-captured build run:

```
-rw-r--r--  app-release.apk     106804470 bytes
```

`file` confirms format:

```
build/app/outputs/flutter-apk/app-release.apk: Zip archive data, at least v0.0 to extract, compression method=deflate
```

(Standard Android APK layout. Single fat APK, four ABIs, debug-signed.)

---

## 7. gradle.properties

### Project-level: `android/gradle.properties`

```
org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G -XX:+HeapDumpOnOutOfMemoryError
android.useAndroidX=true
android.enableJetifier=true
# This builtInKotlin flag was added automatically by Flutter migrator
android.builtInKotlin=false
# This newDsl flag was added automatically by Flutter migrator
android.newDsl=false
```

Note: `Xmx3G` + `MaxMetaspaceSize=1G` for the Gradle daemon is sized for a 32 GB Mac. CI runners typically have less RAM (GitHub-hosted ubuntu-latest is 7 GB on classic runners, 16 GB on the new larger ones). Either reduce to `-Xmx2G` in CI by overriding via `org.gradle.jvmargs` env var, or leave alone if the runner has >=4 GB free.

`android.enableJetifier=true` — still on; can likely be turned off (no AndroidX-incompatible deps detected) but that is a separate cleanup.

### User-level: `~/.gradle/gradle.properties`

**File does not exist.** No user-level overrides on this host. `cat ~/.gradle/gradle.properties` returns nothing.

### `org.gradle.java.home`

Not set in either properties file. Daemon JVM is taken from the active `JAVA_HOME` at invocation time.

---

## 8. `flutter doctor -v` (full)

```
[✓] Flutter (Channel stable, 3.44.0, on macOS 26.3.1 25D771280a darwin-arm64, locale en-US) [167ms]
    • Flutter version 3.44.0 on channel stable at /Users/builder/tools/flutter
    • Upstream repository https://github.com/flutter/flutter.git
    • Framework revision 559ffa3f75 (7 days ago), 2026-05-15 14:13:13 -0700
    • Engine revision 4c525dac5e
    • Dart version 3.12.0
    • DevTools version 2.57.0
    • Feature flags: enable-web, enable-linux-desktop, enable-macos-desktop, enable-windows-desktop, enable-android, enable-ios, cli-animations, enable-native-assets, enable-swift-package-manager, omit-legacy-version-file, enable-lldb-debugging, enable-uiscene-migration

[!] Android toolchain - develop for Android devices (Android SDK version 36.0.0) [814ms]
    • Android SDK at /Users/builder/Library/Android/sdk
    • Emulator version 35.5.10.0 (build_id 13402964) (CL:N/A)
    ✗ cmdline-tools component is missing.
      Try installing or updating Android Studio.
      Alternatively, download the tools from https://developer.android.com/studio#command-line-tools-only and make sure to set the ANDROID_HOME environment variable.
      See https://developer.android.com/studio/command-line for more details.
    ✗ Android license status unknown.
      Run `flutter doctor --android-licenses` to accept the SDK licenses.
      See https://flutter.dev/to/macos-android-setup for more details.

[!] Xcode - develop for iOS and macOS [98ms]
    ✗ Xcode installation is incomplete; a full installation is necessary for iOS and macOS development.
      Download at: https://developer.apple.com/xcode/
      Or install Xcode via the App Store.
      Once installed, run:
        sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
        sudo xcodebuild -runFirstLaunch
    ! CocoaPods not installed.
        CocoaPods is a package manager for iOS or macOS platform code.
        Without CocoaPods, plugins will not work on iOS or macOS.
        For more info, see https://flutter.dev/to/platform-plugins
      For installation instructions, see https://guides.cocoapods.org/using/getting-started.html#installation

[✓] Chrome - develop for the web [40ms]
    • Chrome at /Applications/Google Chrome.app/Contents/MacOS/Google Chrome

[✓] Connected device (2 available) [7.6s]
    • macOS (desktop) • macos  • darwin-arm64   • macOS 26.3.1 25D771280a darwin-arm64
    • Chrome (web)    • chrome • web-javascript • Google Chrome 148.0.7778.179

[✓] Network resources [202ms]
    • All expected network resources are available.

! Doctor found issues in 2 categories.
```

Notes for CI:

- The two `[!]` issues (cmdline-tools missing, Xcode incomplete) are **not** blockers for `flutter build apk --release` on this host; the Android build works because AGP locates the SDK via `android/local.properties:sdk.dir`. CI runners use `actions/setup-flutter` + `android-actions/setup-android` which install cmdline-tools properly; doctor will be clean there.
- "Android license status unknown" — CI must run `flutter doctor --android-licenses` (yes-piped) or `sdkmanager --licenses` after SDK install, otherwise platform/build-tools downloads fail.
- Flutter 3.44 doctor no longer shows a dedicated Java/JDK section.

---

## 9. Network endpoints reached during a clean build

Captured from the live build transcript (Section 5a) plus dependency surface in `pubspec.lock` (142 hosted packages, **all** from `https://pub.dev`).

| Host | Purpose | Required? |
|---|---|---|
| `pub.dev` | Dart / Flutter packages (only host in `pubspec.lock`) | Yes |
| `storage.googleapis.com` | Flutter engine artifacts (downloaded by `flutter doctor` / `flutter precache`) | Yes |
| `download.flutter.io` | Flutter material assets, fallback CDN | Sometimes |
| `services.gradle.org` | Gradle distribution `gradle-8.14-all.zip` | Yes (first run only; cached in `~/.gradle/caches/`) |
| `dl.google.com` | AGP, Google Play Services, Maven `google()` repo | Yes |
| `repo.maven.apache.org` | Maven Central `mavenCentral()` repo | Yes |
| `plugins.gradle.org` | Gradle Plugin Portal `gradlePluginPortal()` repo | Yes |
| `github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/` | Pre-built `libmpv` JNI libs (4 ABI jars) — observed in transcript | Yes |
| `objects.githubusercontent.com` | Backing CDN for github.com release downloads (libmpv, this project's own assets) | Yes |
| `api.github.com` | Release create/update REST calls | Yes |
| `uploads.github.com` | Release asset upload (APK) | Yes |
| `github.com` (SSH) | `git push origin main` over `git@github.com:...` | Replace with HTTPS+token in CI |
| `clients3.google.com` (Google Play Services discovery), `connectivitycheck.gstatic.com` | only at runtime, not during build | No |

For a build with cold caches (`rm -rf build/ ~/.gradle/caches/ ~/.pub-cache/`), expect ~250-400 MB of network ingress dominated by the Gradle distribution, AGP, transitive Maven deps, libmpv JNI jars, and the Pub cache. With caches warm: ~10 MB (just plugin metadata refresh).

> Note: `strace -e trace=connect` was not run for this capture. The list above is derived from the live build transcript (which explicitly logs each libmpv download and the Gradle activity), `pubspec.lock`, `android/settings.gradle` repository declarations, and standard AGP behavior. The CI runner has open egress per the task description, so this section is informational, not gating.

---

## 10. GitHub release mechanics — current vs. CI

| Aspect | Local Mac script today | CI replacement |
|---|---|---|
| Auth | classic PAT `ghp_…` (40 chars) in macOS Keychain at `service=api.github.com, account=rkinnc75, label="Free4Me-IPTV release token"` | built-in `GITHUB_TOKEN` from `permissions: contents: write` block in `release.yml` |
| Required scope | `repo` (sufficient to read the repo, create releases, upload assets) | `contents: write` + (if pushing back) `actions: read` |
| Push transport | SSH `git@github.com:rkinnc75/Free4Me-IPTV.git`, key at `~/.ssh/id_rsa`, optional passphrase at `~/.ssh/id_rsa.passphrase` | HTTPS with `GITHUB_TOKEN`; no SSH key required |
| Release create | `POST /repos/rkinnc75/Free4Me-IPTV/releases` with JSON body | `gh release create` or `softprops/action-gh-release` |
| Asset upload | `POST https://uploads.github.com/.../releases/{id}/assets` with `--data-binary @apk` | same actions handle this |
| Idempotency | script GETs the tag first; if release exists, skips create. Deletes pre-existing same-name asset before upload. Re-runs are safe. | preserve this behavior in CI (`gh release upload --clobber`) |
| Release body | hardcoded short markdown referencing `DEVELOPMENT-HANDBOOK.md`; full release notes are pulled from `lib/whats_new_modal.dart` into `version.json` (in-app update checker), **not** posted to the GH release body. | optional: extend CI to also post the per-version bullet list as the GH release body |
| Trigger | `bash scripts/build_and_release.sh` run interactively after the user manually bumps `pubspec.yaml:version` | tag push (`git push origin v1.15.x`), or `workflow_dispatch` with explicit version |

---

## 11. Pre-flight invariants the workflow must preserve

1. **Single fat APK named `Free4Me-IPTV-${VERSION}-arm64.apk`** uploaded as the only release asset. Existing users' update checker fetches `version.json` and downloads this exact filename.
2. **`version.json` at repo root must be committed and pushed** before the GH release is created — the in-app update checker pulls it via `https://raw.githubusercontent.com/rkinnc75/Free4Me-IPTV/main/version.json`. The local script does this in step b2 as part of the same commit. CI must replicate.
3. **Tag must be `v${VERSION}` exactly**, not `${VERSION}` and not anything else. The script reads from `pubspec.yaml`, prepends `v`. `pubspec.yaml:version` is the single source of truth.
4. **Debug signing must produce the identical fingerprint** users already have, OR the workflow must transition to a release keystore in a coordinated cutover. See Section 4.
5. **Release must be `draft: false, prerelease: false`** so the in-app update checker sees it (it queries `releases/latest` semantics via `version.json`).
6. **Re-runs must be idempotent** — if a tag already exists and a release with the same APK name was uploaded, do not double-create or double-upload.
7. **Branch is `main`**. There is no `develop` / `release/` branching.
8. **Commit message convention** — workspace rule `git_commits.mdc` requires a Jira key on subjects, but the release script today uses `vX.Y.Z: release build` and the user has accepted that exception. Keep this exception in CI.

---

## 12. Things the CI workflow does NOT need to do

- No iOS / macOS / Linux / Windows builds (`flutter build apk` only).
- No `flutter test` invocation (the project has no real tests beyond the boilerplate `widget_test.dart`).
- No code generation step.
- No Crashlytics / Firebase deployment.
- No Play Store upload (`google-services.json` and `play-services-cast-framework` are dependencies, but releases are sideload-only).
- No localization regeneration.
- No `flutter analyze` gate (recommended to add as advisory, but the host script does not block on it).
- No SHA-256 checksum publishing (none in `version.json` today).

---

## 13. Repo-level inputs the workflow consumes

| File | Purpose |
|---|---|
| `pubspec.yaml` | version source of truth (`version: X.Y.Z+N`) |
| `pubspec.lock` | dependency resolution (commit ensures reproducibility) |
| `lib/whats_new_modal.dart` | per-version bullet list extracted into `version.json` by the inline Python in the script |
| `version.json` | written by the script and committed; consumed by in-app update checker |
| `android/app/build.gradle` | `applicationId = "me.free4me.iptv"`, `compileSdk = 36`, `signingConfigs.debug` |
| `android/settings.gradle` | AGP `8.13.2`, Kotlin `2.2.20` |
| `android/gradle.properties` | daemon JVM args, AndroidX/Jetifier flags |
| `android/gradle/wrapper/gradle-wrapper.properties` | Gradle `8.14-all` |
| `android/local.properties` | gitignored — generated by Flutter / Studio. CI must produce one or rely on `ANDROID_HOME` env. |
| `~/.android/debug.keystore` | signing — see Section 4 for fingerprint. |

---

## 14. Open issues / quirks the CI author should know about

- **In-flight `v1.15.8` work was uncommitted** at the time this file was written (six modified files including a `pubspec.yaml` bump to `1.15.8+67`). The CI workflow inherits whatever `pubspec.yaml` is on `main` at trigger time; do not re-derive the version from the tag if the workflow trigger is `push: tags: ['v*']` — read `pubspec.yaml` to keep the existing convention.
- **`scripts/build_and_release.sh` line 53** redundantly re-prepends the Flutter SDK to `PATH` even though the host shell already has it. This is harmless. CI does not need this line.
- **Stale Gradle daemon JVM** — `./gradlew --version` returned Java 8 once during the audit because an older daemon was reused. After `./gradlew --stop` and re-run with `JAVA_HOME=$JBR_PATH`, it correctly used Java 21. CI starts a fresh daemon every run, so this is not an issue, but if the workflow ever caches `~/.gradle/`, ensure the cache key includes the JDK version.
- **NDK 27 vs 28 mismatch** — non-fatal warning today. If the warning becomes an error in a future AGP, set `android { ndkVersion = "27.0.12077973" }` (or upgrade to 28.x) in `android/app/build.gradle`.
- **KGP plugin warnings** — eight Flutter plugins still apply Kotlin Gradle Plugin manually. Tracked future Flutter break.
- **No `~/.gradle/gradle.properties`** on this host. Gradle daemon settings live entirely in the project's `android/gradle.properties`.
- **Python 3 must be on PATH** — the script uses inline Python heredocs for JSON marshalling and changelog extraction. Default `python3` (any 3.8+) is sufficient; no third-party packages.
- **`X11 forwarding request failed on channel 0`** during git push is benign noise from the host's SSH config and does not appear in HTTPS push (which is what CI will use anyway).

---

*End of build environment document. Next step: produce `.github/workflows/release.yml` based on this content.*
