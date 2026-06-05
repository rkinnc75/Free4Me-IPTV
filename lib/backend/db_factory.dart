import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/backend/timed_db.dart';
import 'package:sqlite_async/sqlite_async.dart';

class DbFactory {
  static SqliteDatabase? _db;
  // fix238: cached timing wrapper handed out by the `db` getter.
  static TimedWriteContext? _timedDb;

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
      ..add(SqliteMigration(12, (tx) async {
        // fix154: rolling playback metrics history (local, no telemetry).
        // One row per analyzed session summary. Capped to newest 50 by DAO.
        await tx.execute('''
          CREATE TABLE "playback_metrics" (
            id                        INTEGER PRIMARY KEY AUTOINCREMENT,
            session_start             INTEGER NOT NULL,
            session_minutes           REAL    NOT NULL,
            streams_opened            INTEGER NOT NULL,
            median_first_frame_ms     INTEGER NOT NULL,
            median_stable_ms          INTEGER NOT NULL,
            startup_visible_rebuffers INTEGER NOT NULL,
            total_rebuffers           INTEGER NOT NULL,
            visible_rebuffers         INTEGER NOT NULL,
            median_rebuffer_ms        INTEGER NOT NULL,
            reconnects_watchdog       INTEGER NOT NULL,
            reconnects_error          INTEGER NOT NULL,
            gave_up                   INTEGER NOT NULL,
            created_at                INTEGER NOT NULL
          );
        ''');
        await tx.execute(
            'CREATE INDEX idx_pm_session '
            'ON playback_metrics(session_start);');
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
      }))
      // fix170: migration 12 (CREATE TABLE playback_metrics) was registered
      // out of order (after 10, before 11), so sqlite_async's version-tracked
      // migrate() skipped it on upgraded devices. New highest-version migration
      // is guaranteed to run everywhere; IF NOT EXISTS is a no-op on fresh installs.
      ..add(SqliteMigration(13, (tx) async {
        await tx.execute('''
          CREATE TABLE IF NOT EXISTS "playback_metrics" (
            id                        INTEGER PRIMARY KEY AUTOINCREMENT,
            session_start             INTEGER NOT NULL,
            session_minutes           REAL    NOT NULL,
            streams_opened            INTEGER NOT NULL,
            median_first_frame_ms     INTEGER NOT NULL,
            median_stable_ms          INTEGER NOT NULL,
            startup_visible_rebuffers INTEGER NOT NULL,
            total_rebuffers           INTEGER NOT NULL,
            visible_rebuffers         INTEGER NOT NULL,
            median_rebuffer_ms        INTEGER NOT NULL,
            reconnects_watchdog       INTEGER NOT NULL,
            reconnects_error          INTEGER NOT NULL,
            gave_up                   INTEGER NOT NULL,
            created_at                INTEGER NOT NULL
          );
        ''');
        await tx.execute(
            'CREATE INDEX IF NOT EXISTS idx_pm_session '
            'ON playback_metrics(session_start);');
      }))
      // fix174: channel uniqueness was keyed on (name, source_id), so a
      // catalog with repeated display names collapsed onto the distinct-
      // name set on import (270k rows → ~46). Re-key on provider stable id.
      ..add(SqliteMigration(14, (tx) async {
        // fix178: migration 14 originally created a coalesced UNIQUE index
        // that threw on existing data and froze the app at launch. Neutralised
        // to a no-op drop; the correct partial indexes are created in mig 15.
        await tx.execute('DROP INDEX IF EXISTS channels_unique;');
      }))
      // fix178: replace the throwing coalesced index with two PARTIAL unique
      // indexes scoped to real (non-sentinel) ids only, so divider/junk rows
      // with stream_id=-1/null coexist instead of colliding.
      ..add(SqliteMigration(15, (tx) async {
        await tx.execute('DROP INDEX IF EXISTS channels_unique;');
        await tx.execute('''
          CREATE UNIQUE INDEX IF NOT EXISTS channels_unique_stream
          ON channels(source_id, media_type, stream_id)
          WHERE stream_id IS NOT NULL AND stream_id >= 0;
        ''');
        await tx.execute('''
          CREATE UNIQUE INDEX IF NOT EXISTS channels_unique_series
          ON channels(source_id, series_id)
          WHERE series_id IS NOT NULL;
        ''');
      }))
      // fix184: provider connection limit for multi-view gating.
      ..add(SqliteMigration(16, (tx) async {
        await tx.execute(
            'ALTER TABLE sources ADD COLUMN max_connections INTEGER;');
      }))
      // fix196: per-source tag color (ARGB int; null = no tint).
      ..add(SqliteMigration(17, (tx) async {
        await tx.execute('ALTER TABLE sources ADD COLUMN color INTEGER;');
      }))
      // fix236: (name, source_id) index for the refresh restore-preserve join.
      // Migrations 14/15 dropped the old channels_unique(name, source_id)
      // index (uniqueness moved to provider stream/series ids), leaving the
      // name+source_id match in restorePreserve with only single-column
      // indexes — the planner fell back to source_id-only and scanned all
      // same-source channels per row (~134s on a 21,794-row preserve set).
      // Non-unique (display names repeat across a provider's catalog).
      ..add(SqliteMigration(18, (tx) async {
        await tx.execute(
            'CREATE INDEX IF NOT EXISTS index_channel_name_source '
            'ON channels(name, source_id);');
      }))
      // fix244: partial index for the EPG auto-match scan
      // (getUnmatchedLiveChannels): WHERE source_id=? AND media_type=0
      // AND epg_manual_override IS NULL AND epg_channel_id IS NULL. The
      // partial WHERE indexes only the small set of still-unmatched live
      // channels, so it is tiny and turns a media_type scan (~1.3s on a 2GB
      // TV with a 320k catalog) into a targeted lookup.
      ..add(SqliteMigration(19, (tx) async {
        await tx.execute(
            'CREATE INDEX IF NOT EXISTS idx_epg_unmatched '
            'ON channels(source_id) '
            'WHERE media_type = 0 AND epg_manual_override IS NULL '
            'AND epg_channel_id IS NULL;');
      }))
      // fix256: preserve the provider's intended channel order. Xtream
      // get_live_streams returns a `num` field (and the response order itself)
      // that providers use to interleave "#### SECTION ####" header channels
      // with their channels. provider_order stores that; sources.sort_mode
      // ('provider' | 'alpha', default 'alpha') chooses per-source whether
      // browse views sort by provider_order or by name.
      ..add(SqliteMigration(20, (tx) async {
        await tx.execute(
            'ALTER TABLE channels ADD COLUMN provider_order INTEGER;');
        await tx.execute(
            "ALTER TABLE sources ADD COLUMN sort_mode TEXT;");
      }))
      // fix268: store the live/movie/series counts found by the most recent
      // refresh, so the source edit dialog can show them. Null until a source
      // is refreshed after this ships.
      ..add(SqliteMigration(21, (tx) async {
        await tx.execute(
            'ALTER TABLE sources ADD COLUMN last_live_count INTEGER;');
        await tx.execute(
            'ALTER TABLE sources ADD COLUMN last_movie_count INTEGER;');
        await tx.execute(
            'ALTER TABLE sources ADD COLUMN last_series_count INTEGER;');
      }))
      // fix272: provider "divider" channels (name fully wrapped in '#', e.g.
      // "##### KIDS NETWORK #####") are visual section separators with no
      // playable stream. is_divider flags them at import so the per-source
      // hide_dividers toggle can filter them with an indexed WHERE (faster
      // than a LIKE on every query). sources.hide_dividers drives the toggle.
      ..add(SqliteMigration(22, (tx) async {
        await tx.execute(
            'ALTER TABLE channels ADD COLUMN is_divider INTEGER DEFAULT 0;');
        await tx.execute(
            'CREATE INDEX IF NOT EXISTS idx_channel_divider '
            'ON channels(source_id, is_divider);');
        await tx.execute(
            'ALTER TABLE sources ADD COLUMN hide_dividers INTEGER;');
      }))
      // fix278: per-category enable/disable. groups.enabled = 1 (shown) by
      // default; the Categories view checkboxes flip it. Disabled categories
      // are hidden from the Categories grid AND from Live/All browse views.
      ..add(SqliteMigration(23, (tx) async {
        await tx.execute(
            'ALTER TABLE groups ADD COLUMN enabled INTEGER DEFAULT 1;');
      }))
      // fix300: unified adult flag. Set at import to (provider is_adult) OR
      // (name matches the hardcoded safeModeBlocklist), so every safe-mode
      // filter becomes a single indexed "is_adult = 0" check instead of a
      // per-term LIKE chain. Providers without is_adult contribute 0.
      ..add(SqliteMigration(24, (tx) async {
        await tx.execute(
            'ALTER TABLE channels ADD COLUMN is_adult INTEGER DEFAULT 0;');
        await tx.execute(
            'CREATE INDEX IF NOT EXISTS idx_channel_adult '
            'ON channels(source_id, is_adult);');
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

    // fix236: one-shot read-only index inventory. Logs which indexes actually
    // exist on the channels/groups/sources tables of THIS (possibly long-
    // upgraded) database, so a bug report shows real on-device index state
    // rather than what current migration source implies. Read-only — creates
    // and drops nothing. Helps catch any index a past migration removed/renamed.
    try {
      final idx = await db.getAll(
        "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name IN ('channels', 'groups', 'sources') "
        "ORDER BY tbl_name, name",
      );
      final listed =
          idx.map((r) => '${r.columnAt(1)}.${r.columnAt(0)}').join(', ');
      AppLog.info('Sqlite indexes (channels/groups/sources): $listed');
    } catch (_) {
      // Non-fatal diagnostic.
    }

    // Raise WAL auto-checkpoint from 1000 pages (4MB) to 8000 pages
    // (32MB). This prevents fragmented automatic checkpoints during
    // large batch inserts (EPG programme loading). The explicit
    // Sql.checkpointAndTruncateWal() call in epg_service.dart handles
    await db.execute('PRAGMA wal_autocheckpoint = 8000');

    return db;
  }

  static Future<SqliteWriteContext> get db async {
    _db ??= await _createDB();
    // fix238: hand callers a timing wrapper (slow-query logging) instead of the
    // raw database. The wrapper exposes the SqliteWriteContext surface all
    // callers use; the raw instance is retained in _db for lifecycle.
    _timedDb ??= TimedWriteContext(_db!);
    return _timedDb!;
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
