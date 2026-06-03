# fix31.md — Release keystore migration (stop signing releases with debug)

> **Why this exists.** Through v1.16.3 the release APK was signed with
> the *debug* keystore (`android/app/build.gradle:37` →
> `signingConfig = signingConfigs.debug`). The debug keystore is, by
> design, a per-developer-machine artifact: AGP auto-generates one
> wherever `~/.android/debug.keystore` doesn't already exist. To make
> CI APKs match the user's Mac fingerprint we shipped the Mac's
> `~/.android/debug.keystore` as a GitHub secret (`DEBUG_KEYSTORE_B64`)
> and restored it on the CI runner. This worked but was brittle —
> any drift (the secret being rotated, a fresh Mac, a contributor
> building locally) silently produced an APK with a different SHA-256
> fingerprint, which Android then refused to install over the top of
> an existing install.
>
> The symptom: "App not installed" on update; user has to uninstall
> the prior version first, losing data.
>
> The proper fix is to give the project a dedicated **release**
> keystore that lives in GitHub secrets, is never regenerated, and is
> used by both CI and any local Mac build. After the one-time
> v1.17.0 transition (which itself requires a final uninstall because
> the new fingerprint differs from any v1.16.x install), updates work
> cleanly forever.

---

## What's in this change set

| File | Change |
|---|---|
| `android/app/build.gradle` | Add `signingConfigs.release` reading `android/key.properties`. `buildTypes.release.signingConfig` now uses `signingConfigs.release` when configured, falls back to `signingConfigs.debug` otherwise (so fresh clones can still `flutter run --release`). |
| `.github/workflows/release.yml` | Replace the `DEBUG_KEYSTORE_B64` restore step with a `RELEASE_KEYSTORE_*` restore step that writes `android/app/release.keystore` and `android/key.properties` from four secrets. Fails the run if any secret is missing — no silent fallback to debug. |
| `scripts/build_and_release.sh` | Preflight check: refuse to build if `android/key.properties` or `android/app/release.keystore` is missing. |
| `android/app/release.keystore` | NEW. The signing keystore. Gitignored (`android/.gitignore` already covers `**/*.keystore`). |
| `android/key.properties` | NEW. References `release.keystore` and carries the passwords. Gitignored (`android/.gitignore` already covers `key.properties`). |
| `.release-keystore-secrets` | NEW. Backup file at repo root, gitignored. Contains the base64'd keystore and the three secret values so the keystore is recoverable if the working copy is lost. |
| `.gitignore` | Append `.release-keystore-secrets`. |

No SQL schema changes, no package dependencies, no Flutter / AGP /
Gradle version bumps. One required user action — set four GitHub
secrets — before the v1.17.0 tag is pushed.

---

## Keystore details (the one true fingerprint from v1.17.0 onward)

- **Key algorithm:** RSA 4096-bit
- **Validity:** 100 years from generation
- **Store type:** PKCS12 (the modern Java/Android default)
- **Alias:** `free4me-iptv`
- **DN:** `CN=Free4Me-IPTV, OU=Releases, O=Free4Me-IPTV, L=Unknown, ST=Unknown, C=US`
- **SHA-256:** `D8:D3:4D:5A:2F:35:7B:A4:40:3B:C0:C3:1D:65:2F:CD:D7:B5:50:4A:F9:DA:48:54:65:78:0A:FF:A0:46:9E:A2`
- **SHA-1:** `FE:FB:20:61:AE:AF:B0:4C:1C:12:B9:A5:6D:F8:1C:59:03:93:24:D1`

PKCS12 doesn't support different store and key passwords, so they
match. The workflow + build.gradle + key.properties all treat them
as a single value.

---

## How the build resolves the keystore

### On the user's Mac

1. `scripts/build_and_release.sh` checks `android/key.properties` and
   `android/app/release.keystore` exist. If either is missing, the
   script aborts with a recovery message before invoking Flutter.
2. `flutter build apk --release` invokes Gradle.
3. AGP loads `android/key.properties` via `rootProject.file("key.properties")`.
4. `signingConfigs.release` is populated from those properties.
5. `buildTypes.release.signingConfig = signingConfigs.release`.
6. The APK is signed with the release keystore.

### On GitHub Actions

1. The "Restore release keystore" step asserts all four
   `RELEASE_KEYSTORE_*` secrets are non-empty (fails the run otherwise).
2. `RELEASE_KEYSTORE_B64` is decoded into `android/app/release.keystore`.
3. `android/key.properties` is rebuilt from the other three secrets via
   `printf` (heredoc would leak YAML indent into the file).
4. `flutter build apk --release` follows the same Gradle path as above.

### On a fresh contributor checkout

1. No `key.properties`, no `release.keystore`.
2. `build.gradle` sees `hasReleaseKeystore = false`.
3. `buildTypes.release.signingConfig = signingConfigs.debug`.
4. `flutter run --release` produces a runnable APK signed with the
   contributor's own debug keystore — fine for local testing, not
   redistributable.

---

## One-time migration cost

v1.17.0 is signed with the new release keystore. Its SHA-256 differs
from every v1.16.x install (which was signed with the debug keystore).
**Every existing user must uninstall once** before installing v1.17.0.

This is unavoidable — Android does not accept a signature change on
an update, period. The migration is *the* fix; after v1.17.0 the
fingerprint never changes again and updates work forever.

For the user, the upgrade procedure is:

1. Open the app one last time on v1.16.x and use Settings → Backup &
   Restore → Export backup (fix28 made backup round-trip work for
   favorites, last-watched, settings, and multi-view config).
2. Save the JSON to Drive / Files / wherever.
3. Uninstall the app.
4. Sideload `Free4Me-IPTV-1.17.0-arm64.apk` from the GitHub release.
5. On the first-run Setup welcome screen, tap "Import settings
   backup" (fix28.1) and pick the JSON from step 2.

---

## Recovery if the keystore is lost

The keystore + passwords are the project's signing identity. Losing
them is catastrophic — without them, every existing user would have
to uninstall to take any future update, *and* you couldn't sign
anything new with the same identity.

Three independent copies should always exist:

1. **GitHub repository secrets** (`RELEASE_KEYSTORE_B64` etc.) — the
   working copy used by CI. Visible only to repo admins.
2. **`.release-keystore-secrets`** at repo root on the working Mac.
   Gitignored, `chmod 600`. Contains the same four values plus the
   fingerprint comment for reference.
3. **Offline backup** in a password manager (1Password / Bitwarden)
   or encrypted USB. Even if the Mac and the GitHub org both die,
   the keystore survives.

If (1) is lost: regenerate from (2) or (3) and re-set the GitHub
secrets. No update break.

If (2) and (3) are lost but (1) survives: download
`RELEASE_KEYSTORE_B64` once via a CI dry-run that dumps it, restore
locally, then re-create (2)/(3). No update break.

If (1), (2), and (3) are all lost: you cannot ship another update
without forcing every user to uninstall. Don't let that happen.

---

## Test plan

Manual test on a target device once v1.17.0 ships from CI:

1. Confirm v1.16.3 (or earlier) is installed.
2. Try to install `Free4Me-IPTV-1.17.0-arm64.apk` directly over the
   top. **Expected:** "App not installed" — this is the documented
   one-time transition.
3. Uninstall v1.16.3.
4. Install v1.17.0. **Expected:** clean install.
5. From v1.17.0, build and release v1.17.1 (any trivial change).
6. Install v1.17.1 over v1.17.0. **Expected:** clean update, no
   uninstall required, no data loss.
7. Repeat step 5–6 a few times to confirm stability.

CI verification:

1. Run `gh run view <run-id> --log` (or read the workflow run page)
   for v1.17.0.
2. Confirm the "Restore release keystore" step logged
   `SHA256: D8:D3:4D:5A:…` (the fingerprint above).
3. Repeat for v1.17.1; the SHA must match exactly.

---

## Notes for future maintainers

- Never commit `android/key.properties`, `android/app/release.keystore`,
  or `.release-keystore-secrets`. They're gitignored, but always
  double-check `git status` before committing if the gitignore is ever
  rewritten.
- The four GitHub secrets are the canonical source of truth for CI.
  If you rotate them, you rotate the project's signing identity — which
  forces every user to uninstall again. Don't do that without a
  deliberate decision.
- The PKCS12 format does not support separate store / key passwords.
  Setting `keyPassword != storePassword` in key.properties on a
  PKCS12 keystore will fail at Gradle config time. Keep them equal.
- The 100-year validity is so we never have to think about expiry.
- The fallback to `signingConfigs.debug` in build.gradle exists so
  contributors who clone the repo without the keystore can still run
  the app. Don't remove it — but also don't rely on it for releases.
