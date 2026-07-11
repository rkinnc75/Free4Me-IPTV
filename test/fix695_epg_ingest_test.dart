// fix695: EPG ingest cost-cutters. The XMLTV parse now (a) filters programmes
// at <programme> START by window-overlap AND bound-channel membership (only
// xmltv ids we carry), before any object/text allocation, and (b) the download
// path skips parse+insert entirely when the body hash matches the previous
// refresh (or the server answers 304). This pins the two pure decisions that
// drive those wins:
//   1. the keep/skip predicate (mirrors xmltv_parser.dart <programme> start)
//   2. Sql.getBoundEpgIds (distinct non-null epg_channel_id for a source),
//      exercised against a real in-memory sqlite.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _has() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

// Mirrors the fix695 keep decision in xmltv_parser.dart's <programme> handler.
bool keepProgramme({
  required int startUtc,
  required int stopUtc,
  required String channelId,
  required int windowStart,
  required int windowEnd,
  required Set<String>? boundEpgIds,
}) {
  final inWindow = stopUtc > windowStart && startUtc <= windowEnd;
  final bound = boundEpgIds == null ||
      boundEpgIds.isEmpty ||
      boundEpgIds.contains(channelId);
  return inWindow && bound;
}

// Mirrors Sql.getBoundEpgIds' query.
Set<String> boundEpgIds(s3.Database db, int sourceId) => db
    .select(
        'SELECT DISTINCT epg_channel_id FROM channels '
        'WHERE source_id = ? AND epg_channel_id IS NOT NULL',
        [sourceId])
    .map((r) => r['epg_channel_id'] as String)
    .toSet();

void main() {
  const wStart = 1700000000; // now-ish
  const wEnd = wStart + 24 * 3600; // +1 day forecast

  group('fix695 keep/skip predicate', () {
    const bound = {'yes.us', 'ae.us'};

    test('in-window + bound → keep', () {
      expect(
          keepProgramme(
              startUtc: wStart + 100,
              stopUtc: wStart + 3700,
              channelId: 'yes.us',
              windowStart: wStart,
              windowEnd: wEnd,
              boundEpgIds: bound),
          isTrue);
    });

    test('currently-airing (started before window, ends after) → keep (finding 51)',
        () {
      expect(
          keepProgramme(
              startUtc: wStart - 1800,
              stopUtc: wStart + 1800,
              channelId: 'yes.us',
              windowStart: wStart,
              windowEnd: wEnd,
              boundEpgIds: bound),
          isTrue);
    });

    test('fully in the past → skip (out of window)', () {
      expect(
          keepProgramme(
              startUtc: wStart - 7200,
              stopUtc: wStart - 3600,
              channelId: 'yes.us',
              windowStart: wStart,
              windowEnd: wEnd,
              boundEpgIds: bound),
          isFalse);
    });

    test('beyond forecast → skip (out of window)', () {
      expect(
          keepProgramme(
              startUtc: wEnd + 3600,
              stopUtc: wEnd + 7200,
              channelId: 'yes.us',
              windowStart: wStart,
              windowEnd: wEnd,
              boundEpgIds: bound),
          isFalse);
    });

    test('in-window but UNBOUND channel → skip (fix695 bound filter)', () {
      expect(
          keepProgramme(
              startUtc: wStart + 100,
              stopUtc: wStart + 3700,
              channelId: 'shopping.us', // not carried
              windowStart: wStart,
              windowEnd: wEnd,
              boundEpgIds: bound),
          isFalse);
    });

    test('empty bound set → no filter (first EPG, ingest all in-window)', () {
      expect(
          keepProgramme(
              startUtc: wStart + 100,
              stopUtc: wStart + 3700,
              channelId: 'anything.us',
              windowStart: wStart,
              windowEnd: wEnd,
              boundEpgIds: const {}),
          isTrue);
      // null behaves the same as empty
      expect(
          keepProgramme(
              startUtc: wStart + 100,
              stopUtc: wStart + 3700,
              channelId: 'anything.us',
              windowStart: wStart,
              windowEnd: wEnd,
              boundEpgIds: null),
          isTrue);
    });
  });

  group('fix695 getBoundEpgIds', () {
    if (!_has()) {
      test('sqlite3 unavailable — skipped', () => expect(true, isTrue));
      return;
    }
    late s3.Database db;
    setUp(() {
      db = s3.sqlite3.openInMemory();
      db.execute('CREATE TABLE channels(id INTEGER PRIMARY KEY, '
          'source_id INTEGER, epg_channel_id TEXT)');
      db.execute("INSERT INTO channels(source_id,epg_channel_id) VALUES"
          "(2,'yes.us'),(2,'ae.us'),(2,'yes.us'),(2,NULL),(2,'abc.us'),"
          "(3,'bbc.uk')"); // different source
    });
    tearDown(() => db.dispose());

    test('distinct non-null epg ids for the source only', () {
      final s = boundEpgIds(db, 2);
      expect(s, {'yes.us', 'ae.us', 'abc.us'}); // deduped, NULL excluded
      expect(s.contains('bbc.uk'), isFalse); // other source excluded
    });

    test('source with no matches → empty (⇒ parser applies no filter)', () {
      db.execute('DELETE FROM channels WHERE source_id = 2');
      db.execute('UPDATE channels SET epg_channel_id = NULL');
      expect(boundEpgIds(db, 2), isEmpty);
    });
  });
}
