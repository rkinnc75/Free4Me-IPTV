# fix45.md — AGENTS.md signing cleanup + dependency audit (v1.17.3)

Odd-number fix file (Mac session). Previous odd fix: fix43.

---

## Changes (v1.17.3)

### 1. `AGENTS.md` — stale signing references
Two lines were left over from the pre-fix31 debug-signing era:

- **Current state table:** `Signing` row said "debug key … DEBUG_KEYSTORE_B64".
  Updated to: release keystore, alias `free4me-iptv`, see `BUILD-ENV.md §4`.
- **Do not change list:** Said "Debug signing".
  Updated to: release signing identity with explicit note that any change forces
  every existing user to uninstall before updating.

---

## Deferred items → fix47

### KGP deprecation warnings (8 plugins)

`flutter pub get` warns that `audio_session`, `device_info_plus`, `file_picker`,
`package_info_plus`, `url_launcher_android`, `video_player_android`, `wakelock_plus`,
`workmanager_android` apply Kotlin Gradle Plugin (KGP) directly. Future Flutter
versions will make this a hard build error.

**Why not fixed here:** The 8 plugins are already at the latest versions within
our `^` constraints — pub resolved them. Fixing KGP requires upgrading to new major
versions that use Flutter's built-in Kotlin:

| Plugin | Current | Needs | Constraint bump |
|---|---|---|---|
| device_info_plus | 12.4.0 | 13.x | ^12.3.0 → ^13.0.0 |
| file_picker | 10.3.10 | 11.x | ^10.2.0 → ^11.0.0 |
| package_info_plus | 9.0.1 | 10.x | ^9.0.0 → ^10.0.0 |
| audio_session | 0.2.3 | TBD | — |
| url_launcher_android | 6.3.30 | via url_launcher | transitive |
| video_player_android | 2.9.5 | via video_player | transitive |
| wakelock_plus | 1.5.2 | 1.6.1 | transitive (parent constraint) |
| workmanager_android | 0.9.0+2 | via workmanager | transitive |

**Note:** `android.builtInKotlin=false` in `android/gradle.properties` cannot be
flipped to `true` while these plugins still apply KGP — that would introduce a
Kotlin version conflict at build time. The flag change and plugin upgrades must
happen together.

**Fix47 plan:**
1. Audit call sites for `device_info_plus`, `file_picker`, `package_info_plus` API
   changes in the new major versions.
2. Update pubspec.yaml constraints to the new majors.
3. Run `flutter pub upgrade` on Mac, commit new `pubspec.lock`.
4. Flip `android.builtInKotlin=true` in `android/gradle.properties`.
5. Verify build is clean.

### sqlite3_flutter_libs EOL

`flutter pub get` reports `sqlite3_flutter_libs 0.5.42 (0.6.0+eol available)`.
The `+eol` tag means 0.6.0 itself is flagged EOL — the whole package line is being
deprecated. We're on 0.5.42 which remains functional.

**Why not fixed here:** Need to identify the successor distribution. The `sqlite3`
package (already a transitive dep at 2.9.4) or a new bundling approach is likely.
Migration may affect `sqlite3_flutter_libs` removal and changes to `sqlite_async`.
Defer to fix47 with dedicated investigation.

### 23 packages with newer incompatible versions

All require constraints bumps beyond the current `^` major. Several are
platform-irrelevant for Android (win32, dbus, objective_c, sqlite3_web). The
Android-relevant ones (xml 6→7, sqlite_async 0.13→0.14, etc.) require API review.
Defer to fix47 as a coordinated upgrade pass after KGP is resolved.

---

## Status
KGP warnings: **warnings only**, not errors. Build succeeds. No user-visible impact.
sqlite3_flutter_libs: **0.5.42 functional**, EOL path TBD.
Incompatible packages: **no action required** until fix47.
