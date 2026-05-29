import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:sqlite_async/sqlite_async.dart';

class DbFactory {
  static SqliteDatabase? _db;

  static Future<SqliteDatabase> _createDB() async {
    var db = SqliteDatabase(path: "${await Utils.appDir}/db.sqlite");
    var migrations = SqliteMigrations()
      ..add(SqliteMigration(1, (tx) async {
        await tx.execute('''
        CREATE TABLE "sources" (
          "id"          INTEGER PRIMARY KEY,
          "name"        varchar(100),
          "source_type" integer,
          "url"         varchar(500),
          "username"    varchar(100),
          "password"    varchar(100),
          "enabled"     integer DEFAULT 1
        );
        ''');
        await tx.execute('''
        CREATE TABLE "channels" (
          "id" INTEGER PRIMARY KEY,
          "name" varchar(100),
          "group_name" varchar(100),
          "image" varchar(500),
          "url" varchar(500),
          "media_type" integer,
          "source_id" integer,
          "favorite" integer,
          "series_id" integer,
          "group_id" integer,
          "stream_id" integer,
          FOREIGN KEY (source_id) REFERENCES sources(id)
          FOREIGN KEY (group_id) REFERENCES groups(id)
        );
        ''');
        await tx.execute('''
        CREATE TABLE "channel_http_headers" (
            "id" INTEGER PRIMARY KEY,
            "channel_id" integer,
            "referrer" varchar(500),
            "user_agent" varchar(500),
            "http_origin" varchar(500),
            "ignore_ssl" integer DEFAULT 0,
            FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE
        );
        ''');
        await tx.execute('''
        CREATE TABLE "movie_positions" (
          "id" INTEGER PRIMARY KEY,
          "channel_id" integer,
          "position" int,
          FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE CASCADE
        )
        ''');
        await tx.execute('''
        CREATE TABLE "settings" (
          "key" VARCHAR(50) PRIMARY KEY,
          "value" VARCHAR(100)
        );
        ''');
        await tx.execute('''
          CREATE TABLE "groups" (
            "id" INTEGER PRIMARY KEY,
            "name" varchar(100),
            "image" varchar(500),
            "source_id" integer,
            FOREIGN KEY (source_id) REFERENCES sources(id)
          );
        ''');
        await tx
            .execute('''CREATE INDEX index_channel_name ON channels(name);''');
        await tx.execute(
            '''CREATE UNIQUE INDEX channels_unique ON channels(name, source_id);''');
        await tx.execute(
            '''CREATE UNIQUE INDEX index_source_name ON sources(name);''');
        await tx.execute(
            '''CREATE INDEX index_source_enabled ON sources(enabled);''');
        await tx.execute(
            '''CREATE UNIQUE INDEX index_group_unique ON groups(name, source_id);''');
        await tx.execute('''CREATE INDEX index_group_name ON groups(name);''');
        await tx.execute(
            '''CREATE INDEX index_channel_source_id ON channels(source_id);''');
        await tx.execute(
            '''CREATE INDEX index_channel_favorite ON channels(favorite);''');
        await tx.execute(
            '''CREATE INDEX index_channel_series_id ON channels(series_id);''');
        await tx.execute(
            '''CREATE INDEX index_channel_group_id ON channels(group_id);''');
        await tx.execute(
            '''CREATE INDEX index_channel_media_type ON channels(media_type);''');
        await tx.execute(
            '''CREATE INDEX index_channels_stream_id ON channels(stream_id);''');
        await tx.execute(
            '''CREATE INDEX index_channels_group_name ON channels(group_name);''');
        await tx.execute(
            '''CREATE INDEX index_group_source_id ON groups(source_id);''');
        await tx.execute('''
          CREATE UNIQUE INDEX index_channel_http_headers_channel_id ON channel_http_headers(channel_id);
        ''');
        await tx.execute('''
          CREATE UNIQUE INDEX index_movie_positions_channel_id ON movie_positions(channel_id);
        ''');
      }))
      ..add(SqliteMigration(2, (tx) async {
        await tx.execute('''
          ALTER TABLE channels
          ADD COLUMN last_watched integer;
        ''');
        await tx.execute('''
          CREATE INDEX index_channel_last_watched ON channels(last_watched);
        ''');
      }))
      ..add(SqliteMigration(3, (tx) async {
        await tx.execute('''
          ALTER TABLE groups
          ADD COLUMN media_type integer;
        ''');
        await tx.execute('''
          CREATE INDEX index_groups_media_type ON groups(media_type);
        ''');
      }))
      // Free4Me-IPTV: FTS5 search index. Trigram tokenizer so partial,
      // case-insensitive matches work without leading-wildcard LIKE scans.
      ..add(SqliteMigration(4, (tx) async {
        await tx.execute('''
          CREATE VIRTUAL TABLE channels_fts USING fts5(
            name,
            content='channels',
            content_rowid='id',
            tokenize='trigram'
          );
        ''');
        // Backfill any existing rows.
        await tx.execute('''
          INSERT INTO channels_fts(rowid, name)
          SELECT id, name FROM channels;
        ''');
        // Keep FTS in sync with the channels table.
        await tx.execute('''
          CREATE TRIGGER channels_ai AFTER INSERT ON channels BEGIN
            INSERT INTO channels_fts(rowid, name) VALUES (new.id, new.name);
          END;
        ''');
        await tx.execute('''
          CREATE TRIGGER channels_ad AFTER DELETE ON channels BEGIN
            INSERT INTO channels_fts(channels_fts, rowid, name)
              VALUES('delete', old.id, old.name);
          END;
        ''');
        await tx.execute('''
          CREATE TRIGGER channels_au AFTER UPDATE ON channels BEGIN
            INSERT INTO channels_fts(channels_fts, rowid, name)
              VALUES('delete', old.id, old.name);
            INSERT INTO channels_fts(rowid, name) VALUES (new.id, new.name);
          END;
        ''');
      }))
      ..add(SqliteMigration(5, (tx) async {
        // New columns on existing tables
        await tx.execute(
          'ALTER TABLE sources ADD COLUMN epg_url TEXT;',
        );
        await tx.execute(
          'ALTER TABLE channels ADD COLUMN epg_channel_id TEXT;',
        );
        await tx.execute(
          'ALTER TABLE channels ADD COLUMN epg_manual_override TEXT;',
        );
        await tx.execute(
          'CREATE INDEX idx_channels_epg_id ON channels(epg_channel_id);',
        );

        // Program guide table
        await tx.execute('''
          CREATE TABLE programmes (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            epg_channel_id TEXT NOT NULL,
            source_id   INTEGER NOT NULL,
            title       TEXT NOT NULL,
            description TEXT,
            category    TEXT,
            start_utc   INTEGER NOT NULL,
            stop_utc    INTEGER NOT NULL,
            episode_num TEXT,
            FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE
          );
        ''');
        await tx.execute('''
          CREATE INDEX idx_programs_channel_time
            ON programmes(epg_channel_id, source_id, start_utc);
        ''');
        await tx.execute('''
          CREATE INDEX idx_programs_time_range
            ON programmes(source_id, start_utc, stop_utc);
        ''');

        // EPG refresh audit log
        await tx.execute('''
          CREATE TABLE epg_refresh_log (
            source_id         INTEGER PRIMARY KEY,
            last_refreshed_utc INTEGER NOT NULL,
            programmes_loaded  INTEGER NOT NULL,
            last_error        TEXT,
            FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE
          );
        ''');
      }))
      ..add(SqliteMigration(6, (tx) async {
        await tx.execute(
          'ALTER TABLE channels ADD COLUMN catchup_type TEXT;',
        );
        await tx.execute(
          'ALTER TABLE channels ADD COLUMN catchup_source TEXT;',
        );
        await tx.execute(
          'ALTER TABLE channels ADD COLUMN catchup_days INTEGER;',
        );
      }))
      ..add(SqliteMigration(7, (tx) async {
        await tx.execute(
          'ALTER TABLE channels ADD COLUMN engine_override TEXT;',
        );
        await tx.execute(
          'ALTER TABLE sources ADD COLUMN default_engine TEXT;',
        );
      }))
      // users upgrading from schema 7 with a large EPG table (600k+ rows) were
      // paying the full dedupe+index cost at startup only to discard the table
      // moments later. Replaced with the same DROP statements migration 9 runs,
      // making both migrations safe no-ops when the table is already gone.
      // Devices already on schema 8→9 are unaffected — DROP IF EXISTS is
      // idempotent.
      ..add(SqliteMigration(8, (tx) async {
        await tx.execute('DROP TABLE IF EXISTS programmes;');
        await tx.execute('DROP TABLE IF EXISTS epg_refresh_log;');
        await tx.execute('DROP INDEX IF EXISTS idx_programs_channel_time;');
        await tx.execute('DROP INDEX IF EXISTS idx_programs_time_range;');
        await tx.execute('DROP INDEX IF EXISTS idx_programs_unique;');
      }))
      // large EPG WAL writes don't block channel-search reads in db.sqlite.
      // Drop the old tables to reclaim space. EPG data is intentionally
      // lost — the next "Refresh EPG now" repopulates epg.sqlite.
      ..add(SqliteMigration(9, (tx) async {
        await tx.execute('DROP TABLE IF EXISTS programmes;');
        await tx.execute('DROP TABLE IF EXISTS epg_refresh_log;');
        // Indexes are dropped automatically with the table, but include
        // explicit drops defensively in case of schema divergence.
        await tx.execute('DROP INDEX IF EXISTS idx_programs_channel_time;');
        await tx.execute('DROP INDEX IF EXISTS idx_programs_time_range;');
        await tx.execute('DROP INDEX IF EXISTS idx_programs_unique;');
      }))
      ..add(SqliteMigration(10, (tx) async {
        // NULL = never scanned, 1 = valid, 0 = invalid.
        // ALTER TABLE ADD COLUMN defaults to NULL for all existing rows —
        // correct, since existing channels have never been scanned.
        await tx.execute(
          'ALTER TABLE channels ADD COLUMN stream_validated INTEGER;',
        );
      }))
      ..add(SqliteMigration(11, (tx) async {
        // The previous trigger (AFTER UPDATE ON channels) fired for every
        // column write — favorites, history, stream_validated, EPG — causing
        // unnecessary FTS index churn and WAL growth with no search benefit.
        await tx.execute('DROP TRIGGER IF EXISTS channels_au;');
        await tx.execute('''
          CREATE TRIGGER channels_au AFTER UPDATE OF name ON channels BEGIN
            INSERT INTO channels_fts(channels_fts, rowid, name)
              VALUES('delete', old.id, old.name);
            INSERT INTO channels_fts(rowid, name) VALUES (new.id, new.name);
          END;
        ''');
        // (no-query Live TV browse and channel-picker browse).
        // Covers: source filter + media-type filter + ORDER BY columns.
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS index_channels_browse_order
          ON channels(
            source_id,
            media_type,
            favorite DESC,
            stream_validated DESC,
            last_watched DESC,
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL;
        ''');
      }));
    await migrations.migrate(db);

    // future "syntax error" or feature-gating bug report comes with
    // the version attached. Cheap one-shot at first DB open.
    try {
      final row = await db.get('SELECT sqlite_version();');
      AppLog.info('Sqlite: runtime version=${row.columnAt(0)}');
    } catch (_) {
      // Non-fatal; the rest of the app still works without the log line.
    }

    // Raise WAL auto-checkpoint from 1000 pages (4MB) to 8000 pages
    // (32MB). This prevents fragmented automatic checkpoints during
    // large batch inserts (EPG programme loading). The explicit
    // Sql.checkpointAndTruncateWal() call in epg_service.dart handles
    await db.execute('PRAGMA wal_autocheckpoint = 8000');

    return db;
  }

  static Future<SqliteDatabase> get db async {
    _db ??= await _createDB();
    return _db!;
  }
}

/// Manages the EPG-specific SQLite database (`epg.sqlite`).
///
/// Lives in a separate file from `db.sqlite` so that large EPG writes
/// (600k+ programme inserts, 800k+ stale-row deletes) never inflate the
/// WAL that channel-search reads must traverse. SQLite WAL contention is
/// per-file; two separate SqliteDatabase instances have independent WALs.
///
/// Schema: `programmes` and `epg_refresh_log` tables only.
/// The `sources` FK from these tables references `db.sqlite`, but SQLite
/// cross-file FK enforcement is not supported — we enforce referential
/// integrity at the application layer (Sql.deleteEpgForSource is called
/// from Sql.deleteSource).
class EpgDbFactory {
  static SqliteDatabase? _db;

  static Future<SqliteDatabase> _createDB() async {
    final db = SqliteDatabase(path: '${await Utils.appDir}/epg.sqlite');
    final migrations = SqliteMigrations()
      ..add(SqliteMigration(1, (tx) async {
        // Programme guide — identical schema to the programmes table in
        // db.sqlite migration v5. source_id is a logical FK; no FOREIGN KEY
        // constraint because cross-file FK enforcement is not supported.
        await tx.execute('''
          CREATE TABLE programmes (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            epg_channel_id TEXT NOT NULL,
            source_id   INTEGER NOT NULL,
            title       TEXT NOT NULL,
            description TEXT,
            category    TEXT,
            start_utc   INTEGER NOT NULL,
            stop_utc    INTEGER NOT NULL,
            episode_num TEXT
          );
        ''');
        await tx.execute('''
          CREATE INDEX idx_programs_channel_time
            ON programmes(epg_channel_id, source_id, start_utc);
        ''');
        await tx.execute('''
          CREATE INDEX idx_programs_time_range
            ON programmes(source_id, start_utc, stop_utc);
        ''');
        // Unique constraint built in from the start — no de-duplication
        // migration needed since epg.sqlite starts clean.
        await tx.execute('''
          CREATE UNIQUE INDEX idx_programs_unique
            ON programmes(source_id, epg_channel_id, start_utc);
        ''');
        // EPG refresh audit log — identical schema to epg_refresh_log in
        // db.sqlite migration v5 minus the cross-file FK.
        await tx.execute('''
          CREATE TABLE epg_refresh_log (
            source_id          INTEGER PRIMARY KEY,
            last_refreshed_utc INTEGER NOT NULL,
            programmes_loaded  INTEGER NOT NULL,
            last_error         TEXT
          );
        ''');
      }));
    await migrations.migrate(db);

    AppLog.info('EpgDb: opened epg.sqlite');

    // Same WAL tuning as db.sqlite — raise auto-checkpoint threshold so
    // the explicit Sql.checkpointAndTruncateWal() calls control flushing.
    await db.execute('PRAGMA wal_autocheckpoint = 8000');

    return db;
  }

  static Future<SqliteDatabase> get db async {
    _db ??= await _createDB();
    return _db!;
  }
}
