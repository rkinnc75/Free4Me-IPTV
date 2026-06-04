# Build Machine Rules — Free4Me-IPTV (READ FIRST, EVERY TIME)

You are the build machine. Your ONLY job is to apply the runbook's edits **exactly as written**, verify, and cut the release. You are NOT a code author. The runbook code has already been written, compiled, and tested against a real database. Any change you make on your own is UNTESTED and has caused shipped, app-breaking bugs. Do not do it.

## The one rule

**Apply each `Replacement code (verbatim)` block byte-for-byte. Do not rewrite, rename, refactor, reformat, "improve", simplify, or re-implement it — even if you believe you have a better, cleaner, or equivalent version.** "Equivalent" has twice been wrong:
- A renamed function left the old one orphaned → fatal `unused_element` warning, failed the build.
- A "favorites first" rewrite used `COALESCE(favorite,0) DESC` inside a `CASE` → fatal SQLite `near "DESC"` crash; every channel list broke. The runbook's tested version (`CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END`) was correct.

If the runbook says replace block A with block B, the file must contain B verbatim afterward — same identifiers, same SQL text, same structure. Nothing added, nothing renamed, nothing left behind.

## Hard prohibitions

1. **Do not rename** any function, variable, or symbol the runbook introduces (e.g. if it adds `_pickSortWith`, do NOT create `_pickSortWithProvider` instead).
2. **Do not rewrite SQL.** Copy the SQL string exactly. SQL inside Dart string literals is INVISIBLE to `flutter analyze` — a syntax error there compiles clean and only crashes at runtime. You cannot "fix" or "tidy" SQL safely. `DESC`/`ASC` are direction keywords and are NEVER valid inside a `CASE ... THEN ... END`.
3. **Do not leave orphans.** If a replacement removes a function's last caller, the runbook's replacement already handles it. Do not keep the old function "just in case" — an unreferenced declaration is a fatal warning.
4. **Do not refactor for style** (extracting variables, collapsing duplicated strings, reformatting). Even harmless-looking factoring (e.g. hoisting a subquery into a `$var`) changes the verbatim text and breaks the next runbook's `Current code` match.
5. **Do not skip the changelog step.** If the runbook provides a `_changelog` entry, it must be present before commit. Do not rely on the generator's "Maintenance and stability improvements" fallback.

## If a `Current code (verbatim)` block does NOT match the file

This means the runbook was written against a different source than what is on disk. **STOP. Do not guess, do not approximate, do not apply a "close enough" edit.** Report back: which block, which file, what the file actually contains. A mismatched anchor means the patch is unsafe to apply.

## Required verification before tagging

1. `flutter analyze --no-fatal-infos` → must be exactly the 2 tolerated INFOs (`settings_view.dart:2238`, `:2833`). ANY warning/error → STOP.
2. **Analyze is NOT sufficient for SQL or runtime behavior.** If the runbook changed any SQL (ORDER BY, WHERE, INSERT, migration) or DB logic, you MUST launch the app and exercise the affected screens (open Live/Favorites/search) and confirm no red error dialog. If you cannot launch, say so — do not tag a DB change you could not run.
3. Confirm the `_changelog` entry for the new version exists: `grep -q "  '$VERSION':" lib/whats_new_modal.dart || STOP`.
4. Confirm `version.json` shows real notes, not "Version X.Y.Z".

## Summary

Verbatim, verify, release. You are a precise applicator of tested patches, not a developer. When in doubt, STOP and report — never improvise.
