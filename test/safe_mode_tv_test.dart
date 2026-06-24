// fix524 (safety-critical): Safe Mode must hide adult content in TV mode too.
// Two pins:
//   1. The keyword blocklist (Channel.nameIsAdult) — incl. the fix524 additions
//      [xx] / adult / brazzer — matches case-insensitively on name OR group.
//   2. The getLiveChannelsByEpg adult predicate: with safeMode the resolved
//      live channels exclude is_adult=1; with safeMode off the SQL is unchanged.
//      (Mirrors the real query in lib/backend/sql.dart, like the other SQL
//      parity tests, since the method needs the app DB stack.)
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/media_type.dart';

/// Mirrors the fix524 WHERE in Sql.getLiveChannelsByEpg (no `c.` alias).
String _epgChannelsSql({required bool safeMode}) {
  final smSql = safeMode ? ' AND COALESCE(is_adult, 0) = 0' : '';
  return 'SELECT id FROM channels'
      ' WHERE media_type = ${MediaType.livestream.index}'
      ' AND url IS NOT NULL'
      ' AND source_id IN (1)'
      " AND epg_channel_id IN ('espn.us')"
      '$smSql'
      ' ORDER BY id';
}

void main() {
  group('fix524 blocklist (Channel.nameIsAdult)', () {
    test('fix524 additions match (case-insensitive, name OR group)', () {
      expect(Channel.nameIsAdult('[XX] Hot Stuff', 'General'), isTrue,
          reason: 'bracketed [xx] tag');
      expect(Channel.nameIsAdult('Adult Movies', null), isTrue);
      expect(Channel.nameIsAdult('BRAZZERS TV', null), isTrue,
          reason: 'brazzer matches Brazzers, case-insensitive');
      expect(Channel.nameIsAdult('Regular', '|XXX| Late Night'), isTrue,
          reason: 'group-side match');
    });

    test('original keywords still match', () {
      expect(Channel.nameIsAdult('XXX Channel', null), isTrue);
      expect(Channel.nameIsAdult('CNN', '18+ Zone'), isTrue);
      expect(Channel.nameIsAdult('Erotic Nights', null), isTrue);
      expect(Channel.nameIsAdult('Porn Hub TV', null), isTrue);
      expect(Channel.nameIsAdult('X-Rated', null), isTrue);
    });

    test('ordinary channels are NOT flagged', () {
      expect(Channel.nameIsAdult('FOX Sports', 'Sports'), isFalse);
      expect(Channel.nameIsAdult('ESPN HD', 'USA Sports'), isFalse);
      expect(Channel.nameIsAdult('Max', 'Movies'), isFalse);
    });
  });

  group('fix524 getLiveChannelsByEpg adult predicate', () {
    late s3.Database db;
    setUp(() {
      db = s3.sqlite3.openInMemory();
      db.execute('CREATE TABLE channels (id INTEGER PRIMARY KEY, name TEXT, '
          'media_type INTEGER, url TEXT, source_id INTEGER, '
          'epg_channel_id TEXT, is_adult INTEGER)');
      final live = MediaType.livestream.index;
      // A clean live channel and an adult one, same source + epg id.
      db.execute(
        'INSERT INTO channels(id,name,media_type,url,source_id,epg_channel_id,is_adult) '
        'VALUES (1,?,?,?,1,?,0),(2,?,?,?,1,?,1)',
        ['ESPN HD', live, 'http://x/1', 'espn.us',
         'XXX ESPN', live, 'http://x/2', 'espn.us'],
      );
    });
    tearDown(() => db.dispose());

    test('safeMode ON excludes the adult channel', () {
      final ids = db
          .select(_epgChannelsSql(safeMode: true))
          .map((r) => r['id'] as int)
          .toList();
      expect(ids, [1], reason: 'adult channel id=2 filtered out');
    });

    test('safeMode OFF returns both (behavior unchanged)', () {
      final ids = db
          .select(_epgChannelsSql(safeMode: false))
          .map((r) => r['id'] as int)
          .toList();
      expect(ids, [1, 2], reason: 'no predicate → both returned');
    });
  });
}
