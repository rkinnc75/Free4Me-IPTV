# RUNBOOK PREFLIGHT — verify before every code-touching fix

Add this to the repo root and treat it as a hard gate on the **runbook-writing** side
(the phone/assistant), *before* the build machine ever runs `flutter analyze`. fix164.3
shipped a `ListTileThemeData.focusColor` that does not exist and broke CI; fix174 shipped
escaped `$` interpolations that broke CI with 6 unused-symbol warnings. This checklist is
the fix for both classes of error.

## The toolchain IS available — compile before shipping (added fix176)

The earlier premise that the author "has no Flutter SDK and cannot compile" is **false**
and caused fix174 to ship by inspection. The container network allowlist includes
`storage.googleapis.com` (Dart SDK + Flutter engine artifacts) and `github.com` (Flutter
itself). The author **must** run the real analyzer before handing over any code-touching
runbook:

```bash
# Dart SDK from an allowlisted host:
curl -sSL -o /tmp/dartsdk.zip \
  https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-x64-release.zip
unzip -q /tmp/dartsdk.zip -d /opt            # → /opt/dart-sdk

# Flutter stable (shallow) from github:
git clone --depth 1 -b stable https://github.com/flutter/flutter.git /opt/flutter
export PATH="/opt/flutter/bin:/opt/dart-sdk/bin:$PATH"

# In the edited project tree:
flutter pub get
flutter analyze --no-fatal-infos      # MUST be clean except known-tolerated INFOs
```

This is the authoritative gate. Inspection-based rules below still apply, but they are
no longer a substitute for running the analyzer. **If you produced code-touching edits
and did not run `flutter analyze`, the runbook is not ready.**

## The core problem

Inspection alone is fallible: an invented parameter, a renamed method, a wrong import,
a deprecated API, or an escaped string interpolation can read as "fine" in prose. Most
are now caught by running the analyzer (above); the rules below make the common ones
obvious before you even compile. **Assume nothing about an API you did not read in this
repo, confirm against the SDK docs, or compile.**

## Hard rules (every code-touching runbook)

1. **No symbol goes in a runbook unless it is one of:**
   - **(a) Read from this repo's source** — `grep`'d and viewed in the uploaded zip, OR
   - **(b) Confirmed against official API docs** — for Flutter/Dart, `api.flutter.dev`
     / `dart.dev`; web_fetch the actual class page and read the constructor signature.
   - If neither, it does **not** go in the runbook. No "I'm pretty sure this param exists."

2. **Framework/library API claims require a doc check, not memory.** Especially:
   - Constructor named parameters (the fix164.3 failure — `ListTileThemeData` has no
     `focusColor`; that's a per-`ListTile` property, and the global lever is
     `ThemeData.focusColor`).
   - Method names/signatures, enum members, widget property names.
   - Whether a property lives on the **widget** vs its **ThemeData** (they differ often:
     `focusColor` is on `ListTile`, not `ListTileThemeData`).
   - Deprecations (`withOpacity` → `withValues`, `MaterialState*` → `WidgetState*`).

3. **Prefer the repo's own proven pattern over a novel one.** If the codebase already
   solves a problem (e.g. `DpadTextField`/`DpadFocusEscape` for the focus trap), reuse
   it. Repo code is compile-verified by definition — it shipped. Novel theme/widget code
   is the highest-risk part of any runbook and needs the most doc-checking.

4. **Locate every edit by symbol, not line number** (already a project rule) — and while
   you're there, **read the surrounding real code** so the "current code" block in the
   runbook is a verbatim copy, never a paraphrase. A mis-quoted "current" block makes the
   str_replace fail on the build machine.

5. **Mentally diff against the analyzer's fatal set.** `--no-fatal-infos` means
   **WARNINGS and ERRORS are fatal; INFOs are tolerated.** Before shipping the runbook,
   walk each change and ask: would this produce an ERROR (undefined name/param/method,
   type mismatch, missing import, bad override) or a WARNING (unused import/element/var,
   dead code, unnecessary non-null)? If yes, fix it in the runbook. INFOs
   (`use_build_context_synchronously`, etc.) are acceptable and need no action.

6. **No escaped `$` or `\u…` inside Dart string literals in code blocks (added fix176).**
   `'\$x'` / `'\${expr}'` / `'\u2022'` slip through inspection and get pasted verbatim —
   `$x` renders as literal text instead of interpolating, leaving the variable unused (fatal
   WARNING) or putting garbage in SQL. Grep every code block for `\$` and `\u`; there must
   be none. Prefer literal characters (`•`) over `\u` escapes.

## Per-change checklist (run mentally for each `# Fix N.M` block)

- [ ] Every **new** symbol (class, param, method, enum, color, helper) is repo-read or
      doc-confirmed. List where each came from if non-obvious.
- [ ] Each named parameter actually exists on **that exact** constructor (not a sibling
      class, not the widget when you're configuring the theme-data).
- [ ] Imports: every referenced symbol resolves from an import the file has or that the
      runbook adds. No symbol from a package not in `pubspec.yaml`.
- [ ] No new **unused** import/field/method/var introduced (WARNING → fatal). If a fix
      adds a helper, it must be referenced; if it removes the last use of an import,
      remove the import too.
- [ ] "Current code" blocks are verbatim from the uploaded source (so str_replace lands).
- [ ] Deprecated APIs avoided; used the same modern API the repo already uses.
- [ ] Parens/quotes/braces balance in every replacement block (esp. when splitting a
      chained `..` cascade or adding a wrapper widget — the setup.dart `DpadFocusEscape`
      wraps add one `(` and one `)` each).
- [ ] No escaped `$` / `\u` inside any Dart string literal (fix176 rule 6). Grep `'\$'`
      and `'\u'`; every `$` must be a real interpolation, every bullet a literal `•`.
- [ ] **Compiled:** `flutter analyze --no-fatal-infos` on the edited tree returns only
      known-tolerated INFOs.
- [ ] Gating/behavioural flags (`hasTouchScreen`, `isTV`, `previewMode`) are referenced
      exactly as they exist in scope at that edit site.

## Doc-verification mechanics (no SDK available)

- For any Flutter/Dart API in doubt: `web_search` the class, then **`web_fetch` the
  `api.flutter.dev` page** and read the constructor's parameter list. Don't trust the
  search snippet alone for a parameter-existence claim — open the class page.
- Record the verification in the runbook's pre-tag gate ("`ThemeData.focusColor` is a
  real top-level field per api.flutter.dev") so the build machine and the next author
  can see it was checked, not assumed.
- When a symbol is repo-sourced, name the file/line you read it from.

## If analyze still hits errors (author's machine or build machine)

1. Capture the **exact** analyzer output (it names file:line:rule — that's gold).
2. Triage by severity: ERROR/WARNING must be fixed; INFO is tolerated and shipped as-is.
3. For each ERROR, re-verify the offending symbol against docs/repo (the same way it
   should have been verified pre-ship) and correct the runbook.
4. Feed the lesson back here: if it's a new *class* of mistake, add a bullet to the
   Hard Rules so it can't recur silently.

## Known-tolerated INFOs (do not "fix")

- `use_build_context_synchronously` in `settings_view.dart` (currently ~lines 2126/2712,
  and others) — long-standing, guarded, accepted. These are INFOs and never fatal under
  `--no-fatal-infos`. Do not contort the runbook to chase them.
