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
      // v1.2: EPG support
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
      // v1.3: Catchup / time-shift columns
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
      // v1.4: Per-channel and per-source engine override
      ..add(SqliteMigration(7, (tx) async {
        await tx.execute(
          'ALTER TABLE channels ADD COLUMN engine_override TEXT;',
        );
        await tx.execute(
          'ALTER TABLE sources ADD COLUMN default_engine TEXT;',
        );
      }));
    await migrations.migrate(db);
    return db;
  }

  static Future<SqliteDatabase> get db async {
    _db ??= await _createDB();
    return _db!;
  }
}
