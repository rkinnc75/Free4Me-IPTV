# fix46.md — XMLTV stream body has no timeout; rematch stalls indefinitely

> **Version:** Free4Me-IPTV 1.17.3 (code identical to 1.17.1 — fix44 not yet applied)
> **Evidence:** `free4me_log_1779665210872.txt` + `free4me_log_1779665764812.txt`
>
> Symptom: tapping "Re-match all channels" in Settings shows the
> re-match progress dialog, which stalls at "Downloading & parsing…"
> forever. Force-close is the only escape. The regular "Refresh EPG
> now" works fine immediately before.

---

## Root cause — XMLTV stream body has no per-chunk timeout

The XMLTV parser establishes the HTTP connection with a 60-second
timeout (the `timeout` parameter on `AppHttp.sendStreaming`). That
timeout only governs receiving the initial response headers. Once
the server sends `HTTP 200` and the body stream opens, there is no
watchdog on subsequent chunks.

**`lib/backend/xmltv_parser.dart:94-125`:**

```dart
Stream<List<int>> byteStream = await _maybeUngzip(response.stream);
// ↑ response.stream has NO .timeout() applied

final eventStream = byteStream
    .transform(utf8.decoder)
    .transform(XmlEventDecoder())
    .expand((list) => list);

await for (final event in eventStream) {  // ← waits forever for next chunk
  ...
}
```

Compare the M3U parser, which correctly applies a 60-second
per-chunk body timeout:

**`lib/backend/m3u.dart:234-237`:**

```dart
await for (var chunk in response.stream.timeout(
  const Duration(seconds: 60),
  onTimeout: (sink) => sink.close(),
))
```

If a CDN connection stalls mid-stream — server sent `HTTP 200` and
a few chunks, then stopped responding — the XMLTV parser sits in
`await for` indefinitely. The dialog shows "Downloading & parsing…"
and never progresses. Since the dialog is `barrierDismissible:
false` and has no OK button until `done=true`, the user cannot
dismiss it. Force-close is the only exit.

---

## Why the rematch triggers this and the regular refresh does not

Both paths call `EpgService.downloadAndParseEpg` → `XmltvParser.parse`
on the same URL. The regular "Refresh EPG now" runs once; the
"Re-match all channels" runs the download **a second time** within
minutes of the first.

The user's session (both logs):
```
19:12:17  XMLTV: GET https://iptv-epg.org/files/epg-siyyygmhip.xml
19:12:18  XMLTV: HTTP 200  (first bytes 0x3c 0x3f = XML)
19:13:02  XMLTV: parse done — 574920 programs in 44 seconds
19:13:16  EPG: match done — 15345/35945 matched
           ← user taps "Re-match all channels"
           ← second GET of the same URL
           ← HTTP 200 received
           ← stream stalls mid-body
           ← dialog frozen at "Downloading & parsing…"
           ← force-close
```

CDN nodes commonly rotate connections between requests. A second
request to the same large file (Aniel3000's feed is ~600 MB
uncompressed) within minutes often lands on a different edge node
that may be under load or have a degraded connection to the origin.
Without a body timeout, the stall is permanent.

---

## Fix 46.1 — Add stream body timeout to XmltvParser

**File:** `lib/backend/xmltv_parser.dart`

Apply the timeout to `response.stream` before passing it to
`_maybeUngzip`, mirroring the M3U parser exactly.

**Current code (line 94):**

```dart
Stream<List<int>> byteStream = await _maybeUngzip(response.stream);
```

**Replace with:**

```dart
// Apply a per-chunk body timeout matching the M3U parser (m3u.dart:234).
// The connection-establishment timeout on AppHttp.sendStreaming only
// covers receiving the response headers — once the body stream opens,
// there is no watchdog. A CDN that stalls mid-body would otherwise
// leave the parser in `await for` indefinitely.
//
// `onTimeout` closes the stream (rather than erroring) so the `await
// for` loop exits cleanly and control falls through to the
// `flushBatch()` at line 182. `downloadAndParseEpg` will then return
// a partial channelMap (whatever arrived before the stall). Callers
// treat a partial download as a usable result if at least some
// programs were inserted; the match then runs on what we have.
//
// If a total-failure timeout (0 programs) is preferable to a partial
// result, change `sink.close()` to
// `sink.closeWithError(Exception('XMLTV body stalled'))` — but
// partial data is generally better for the user's EPG coverage.
Stream<List<int>> byteStream = await _maybeUngzip(
  response.stream.timeout(
    const Duration(seconds: 60),
    onTimeout: (sink) {
      AppLog.warn(
        'XMLTV: body stream stalled — no data for 60 s, closing'
        ' (partial result will be used)',
      );
      sink.close();
    },
  ),
);
```

Add the import at the top of `xmltv_parser.dart` if not already
present (AppLog is likely already imported; verify):

```dart
import 'package:open_tv/backend/app_logger.dart';
```

### What happens when the timeout fires

1. `sink.close()` closes the source stream — no more chunks arrive.
2. `_maybeUngzip`'s internal `StreamController` receives the close
   via the `onDone` callback (line ~231 of xmltv_parser.dart) and
   closes its own controller.
3. The `eventStream` (which derives from `byteStream`) also closes.
4. `await for (final event in eventStream)` exits normally (not via
   an exception).
5. `await flushBatch()` at line 182 flushes the last partial batch.
6. The `onProgress` "done" call fires and `XmltvParser.parse`
   returns whatever `channelMap` it built from the data that arrived
   before the stall.
7. `downloadAndParseEpg` logs "EPG: downloaded … N programs" and
   returns the partial channelMap.
8. The match step runs on whatever programs and channels arrived.
9. The dialog advances from "Downloading & parsing…" to the matching
   phase. If enough programs arrived, the match is useful. If not,
   the user sees a reduced match count in the results.

This is significantly better than the current state (permanent stall
requiring force-close). The user sees the dialog complete and can
assess the result.

---

## Fix 46.2 — Apply fix44 (which was not applied in 1.17.3)

Both log files confirm fix44 is not in 1.17.3 — no
`SourcesRefreshDialog:` lines, no `EpgRematch:` lines, no `Setup:`
lines, no `Sqlite: runtime version=` line from `db_factory.dart`.

**Apply the complete fix44.md runbook to 1.17.3.**

This gives:

- The `Completer`-based race-condition fix in
  `sources_refresh_dialog.dart` (fix44.1)
- `AppLog` lines across `setup.dart:_importBackup` (fix44.2)
- `AppLog` lines across `settings_view.dart:_runEpgRefresh` (fix44.3)
- `AppLog` lines across `settings_view.dart:_runEpgRematch` (fix44.4)

With fix44 applied, the next rematch stall will produce a log like:

```
EpgRematch: starting — 1 eligible source(s): "Aniel3000 "
EpgRematch: source "Aniel3000 " — downloading EPG
XMLTV: GET https://iptv-epg.org/files/epg-siyyygmhip.xml
XMLTV: HTTP 200, content-length=?, encoding=gzip
XMLTV: gzip-sniff → plain (first bytes 0x3c 0x3f)
[... progress updates if any arrive ...]
XMLTV: body stream stalled — no data for 60 s, closing (partial result)
XMLTV: parse done — N channels, M programs inserted, K outside window
EPG: downloaded "Aniel3000 " — M programs
EpgRematch: source "Aniel3000 " — EPG downloaded (N channel entries), starting force-match
EpgRematch: source "Aniel3000 " — force-match done M/35945
EpgRematch: complete — 1 source(s) processed
```

If the stall fires the timeout, "body stream stalled" appears.
If the download completes cleanly, the stall was network transient
and the log proves it. Either way, the dialog finishes.

---

## Fix 46.3 — Add `Sqlite: runtime version` log (from db_factory.dart)

The earlier fix31 runbook noted this as a suggested one-liner; the
`db_factory.dart` in 1.17.3 already has it (confirmed: lines
253-259). This fix is already applied — no action needed.

---

## Apply order

1. **Fix 46.2 first** — apply the complete fix44.md runbook. This
   adds the logging infrastructure needed to diagnose any future
   failures.
2. **Fix 46.1** — add the stream body timeout to `xmltv_parser.dart`.
   One code change, one new log line.

---

## Test plan

### Primary — rematch no longer stalls

1. Run "Refresh EPG now" (regular refresh). Confirm it completes.
2. Immediately tap "Re-match all channels".
3. **Expected (fix46.1 working):** the rematch dialog progresses
   through "Downloading & parsing…" within 60 seconds of any stall,
   then advances to the matching phase, then shows the results
   summary. The dialog does NOT hang indefinitely.
4. With debug logging enabled, look for either:
   - Clean completion: `EpgRematch: source … — EPG downloaded (N
     channel entries), starting force-match` with no timeout line.
   - Partial completion: `XMLTV: body stream stalled — no data for
     60 s, closing` followed by the match phase running on the
     partial data.

### Secondary — timeout fires correctly

To force the timeout (optional, for CI/dev testing):

1. Temporarily change the timeout to `Duration(seconds: 5)`.
2. Run rematch on a slow network or with network throttling.
3. **Expected:** "body stream stalled" log line appears within 5s of
   the last chunk, dialog advances past the download phase.

### Regression — regular refresh unaffected

1. Run "Refresh EPG now" on a normal network.
2. **Expected:** completes at the same speed as before (44 seconds
   for Aniel3000 in the user's session). The 60s body timeout only
   fires when no data arrives for 60 seconds — a healthy download
   receives chunks continuously and never triggers it.

### Fix44 regression — sources refresh dialog

1. Fresh install → import backup → confirm progress dialog shows
   and advances (fix44.1 Completer fix).
2. Confirm `SourcesRefreshDialog: dialog built — ready` log line
   appears before `SourcesRefreshDialog: starting refresh`.

---

## Notes for the implementer

- **One new line of real code** in fix46.1 (plus the surrounding
  comment). The rest of this runbook is applying the already-written
  fix44.
- **`sink.close()` vs `sink.closeWithError()`:** closing normally
  gives a partial result; erroring gives a clean failure. Partial
  is chosen here because some programs are better than none for EPG
  coverage. If the product owner prefers a clean error message over
  partial data, swap to `sink.closeWithError(Exception('XMLTV body
  stalled after 60 s'))` — `downloadAndParseEpg` already has a
  catch that returns `null`, and the rematch dialog shows
  `⚠ source: failed to download EPG`.
- **`_maybeUngzip` and the timeout:** `_maybeUngzip` wraps the
  source stream in a new `StreamController`. The `.timeout()` is
  applied to `response.stream` BEFORE it enters `_maybeUngzip`, so
  the timeout fires based on the raw HTTP byte stream's chunk
  arrival rate — exactly what we want. Timeouts are per-chunk
  (60 seconds of silence), not total-download time, so a legitimate
  600-MB download that arrives steadily at 10 MB/s never triggers.
- **No schema changes, no new dependencies, no new files.**
