import 'dart:async';

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
      // fix359: 11 registered before 12 (was 12-before-11). sqlite_async
      // 0.13.1 asserts migrations are added in ascending toVersion order;
      // the old order tripped that assert in any asserts-enabled build
      // (debug/profile/widget tests). 12's table+index are also re-created
      // IF NOT EXISTS by 13, so reordering changes no resulting schema.
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
      }))
      // fix308: per-category favorite. groups.favorite = 1 sorts that category
      // to the top of the Categories list (does NOT favorite its channels).
      ..add(SqliteMigration(25, (tx) async {
        await tx.execute(
            'ALTER TABLE groups ADD COLUMN favorite INTEGER DEFAULT 0;');
      }))
      // fix319: composite indexes to speed up the no-query / history browse on
      // very large catalogues (700k+ channels on low-RAM TV boxes were taking
      // 20-30s full scans). Lets the planner seek by source + media type, and
      // by last_watched for the History view, instead of scanning all rows.
      ..add(SqliteMigration(26, (tx) async {
        await tx.execute(
            'CREATE INDEX IF NOT EXISTS idx_channel_src_media_url '
            'ON channels(source_id, media_type, url);');
        await tx.execute(
            'CREATE INDEX IF NOT EXISTS idx_channel_lastwatched_media '
            'ON channels(last_watched, media_type) '
            'WHERE last_watched IS NOT NULL;');
      }))
      // fix330: the "All" browse view (live+movies+series together, alpha sort)
      // forced a full sort of the whole catalogue — EXPLAIN showed
      // "USE TEMP B-TREE FOR ORDER BY" over ~270k rows, ~11s cold on the Shield.
      // The existing (source_id, media_type, …) index can filter but cannot
      // satisfy the ORDER BY because the sort leads with a computed 6-tier CASE
      // and the view spans multiple media_type values. This expression index
      // stores exactly that tier CASE plus name, scoped per source, so the
      // planner walks it in sort order and stops after one page (measured:
      // ~340ms warm / ~11s cold -> ~0.1ms; deep pages ~1ms). The index
      // expression MUST stay structurally identical to BrowseOrder.tier
      // (lib/backend/browse_order.dart) — the single source of the alpha-mode
      // ORDER BY since fix344. If either side changes, the index stops being
      // used; test/browse_order_test.dart EXPLAIN-asserts the match against a
      // real sqlite DB.
      ..add(SqliteMigration(27, (tx) async {
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_channels_browse_tier
          ON channels(
            source_id,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL;
        ''');
      }))
      // fix353: channels_unique_series was (source_id, series_id) — one row
      // per series. Series PARENT tiles never set series_id (id lives in url),
      // so the index only ever matched EPISODES, collapsing every episode of a
      // series onto one row via the bare-upsert in insertChannel ("series
      // loads 1 episode"). Re-key on (source_id, series_id, url): episode url
      // embeds the provider's unique episode id + container extension, stable
      // across fetches, so re-opening a series upserts instead of duplicating.
      // Existing collapsed data (1 row/series) trivially satisfies the wider
      // key — no migration-time conflict. Collapsed series self-heal on next
      // open (getEpisodes re-runs each app session).
      ..add(SqliteMigration(28, (tx) async {
        await tx.execute('DROP INDEX IF EXISTS channels_unique_series;');
        await tx.execute('''
          CREATE UNIQUE INDEX IF NOT EXISTS channels_unique_series
          ON channels(source_id, series_id, url)
          WHERE series_id IS NOT NULL;
        ''');
      }))
      // fix365: browse (Live/VOD/Series) ran a correlated (SELECT g.enabled …)
      // subquery PER ROW. With most categories disabled and the enabled ones
      // sorting late, SQLite walked deep into idx_channels_browse_tier running
      // that subquery thousands of times before LIMIT 36 was satisfied — 5s+
      // grid loads on a large catalog (S24 2026-06-13 log: 4.8–5.6s/switch).
      // Denormalize the category-enabled flag onto channels.cat_enabled and add
      // a partial browse index that EXCLUDES disabled rows, so the scan stops at
      // 36 immediately. cat_enabled is maintained at group_id resolution
      // (refresh) and on every category toggle.
      ..add(SqliteMigration(29, (tx) async {
        await tx.execute(
            'ALTER TABLE channels ADD COLUMN cat_enabled INTEGER DEFAULT 1;');
        // Backfill from the current groups.enabled (default 1 when no group).
        await tx.execute('''
          UPDATE channels SET cat_enabled = COALESCE(
            (SELECT g.enabled FROM groups g WHERE g.id = channels.group_id), 1);
        ''');
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_channels_browse_enabled
          ON channels(
            source_id,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1;
        ''');
      }))
      // fix373: the fix365 index leads with source_id, so a MULTI-source browse
      // (e.g. 2 providers) could not satisfy the global ORDER BY tier,name from
      // the index — SQLite built a TEMP B-TREE sorting every enabled row across
      // sources to return the top 36. On a large 2-source catalog with a cold
      // page cache this was a ~5.8s first paint (S24 2026-06-15 09:01 log,
      // mediaTypes=livestream). This index leads with media_type instead: for a
      // single-media-type browse (Live / VOD / Series) media_type is pinned and
      // (tier, name) then matches the ORDER BY directly — no temp b-tree, stops
      // at LIMIT. source_id IN (...) is residual. (The mixed-media "All" view
      // keeps a temp b-tree because media_type IN (0,1,2) can't pin; the
      // startup warm-up in main.dart covers that cold-start case.)
      ..add(SqliteMigration(30, (tx) async {
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_channels_browse_mt
          ON channels(
            media_type,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1;
        ''');
      }))
      // fix386: persist the EPG auto-discovery state for each source.
      // NULL = no probe run yet, 'auto' = auto-detected by EpgDiscovery,
      // 'manual' = user-set via the EPG dialog (see settings_view.dart),
      // 'none' = probed but no XMLTV endpoint found.
      // The state is sticky once set; a successful auto-detection
      // never re-probes. The user can re-run the probe via the
      // "Re-detect EPG" button on the source row, which sets the
      // state to 'auto' or 'none' depending on the result.
      ..add(SqliteMigration(31, (tx) async {
        await tx.execute('''
          ALTER TABLE sources ADD COLUMN epg_discovery_state TEXT;
        ''');
      }))
      // fix392: the no-text browse (Live/Movies/Series tabs) filters
      // `series_id IS NULL` via VisibilityClause — episodes are stored as
      // media_type=movie WITH a series_id (see episodeToChannel), so that
      // predicate is what separates standalone titles from episodes, not
      // redundant. The unconditional index_channel_series_id MATCHED
      // `series_id IS NULL`, so the planner chose it and then TEMP-B-TREE
      // sorted the whole media-type set — silently defeating BOTH browse-tier
      // indexes (migration 27 source-led, migration 30 media_type-led). EXPLAIN
      // on a seeded 675k-row DB confirmed the index was unused and the sort ran
      // (~4.3s first paint on an S24 with 3 sources). Making the index PARTIAL
      // on `series_id IS NOT NULL` keeps it for the series drilldown
      // (`series_id = ?`) but stops it matching the browse's `series_id IS
      // NULL`; the planner then serves the global tier+name order straight from
      // idx_channels_browse_mt with no sort, for any source count (~0.04ms in
      // the same bench). Index-only change — query results are unchanged.
      ..add(SqliteMigration(32, (tx) async {
        await tx.execute('DROP INDEX IF EXISTS index_channel_series_id;');
        await tx.execute('CREATE INDEX index_channel_series_id'
            ' ON channels(series_id) WHERE series_id IS NOT NULL;');
      }))
      // fix393: per-mode browse indexes so the no-text browse is index-served
      // for ALL sort modes, not just alpha (migration 30's idx_channels_browse_mt
      // only covers alpha/tier ordering). Each leads with media_type (a single
      // constant in a Live/Movies/Series tab) so it serves the GLOBAL order
      // across all in-scope sources from the index — no temp B-tree. Partial on
      // the same browse predicate as idx_channels_browse_mt. The fav-first /
      // validated-float CASE prefixes mirror BrowseOrder.orderBy('provider'|
      // 'category') exactly (fix258/fix272/fix375); if those change, these must
      // change in lockstep (guarded by browse_order_test). Mixed-mode in-scope
      // sources are handled in Sql.search via a per-source UNION ALL where each
      // source sorts in its own (uniform, now-indexed) mode.
      ..add(SqliteMigration(33, (tx) async {
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_prov ON channels(
            media_type,
            (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END),
            (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1
              THEN 0 ELSE 1 END),
            provider_order,
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1;
        ''');
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_cat ON channels(
            media_type,
            (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END),
            (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1
              THEN 0 ELSE 1 END),
            group_name COLLATE NOCASE,
            provider_order,
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1;
        ''');
      }))
      // fix419: composite browse indexes that pin BOTH selective dimensions, so
      // a single-source browse stops at LIMIT instead of residual-scanning every
      // other source's rows (issue #2/#3: 2.6s VOD / 1.7s category on a 1.15M-row
      // catalog with one source enabled — disabled sources' rows stay in the
      // table/indexes). idx_browse_src_grp removes the category temp-B-tree (the
      // planner adopts it on its own); idx_browse_src_mt is hinted explicitly in
      // sql.dart for the single-media-type browse (LIMIT defeats the planner's
      // selectivity estimate so it won't pick it unaided). Tier expression is
      // byte-identical to BrowseOrder.orderBy('alpha') / idx_channels_browse_mt so
      // it serves the sort. cat_enabled is omitted from the grp index because the
      // category view shows rows regardless of the enabled checkbox.
      ..add(SqliteMigration(34, (tx) async {
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_src_mt
          ON channels(
            source_id,
            media_type,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1;
        ''');
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_src_grp
          ON channels(
            source_id,
            group_id,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL;
        ''');
      }))
      // fix519: replace the trigram channels_fts with a WORD-PREFIX (unicode61)
      // index. Trigram indexed every 3-char gram of every channel name, so the
      // global 'rebuild' (fired on every large-source refresh) re-tokenized the
      // whole catalog — measured ~200s+ per large source on the onn 4K box, and
      // worse as the catalog grew. unicode61 indexes whole words; prefix='2 3'
      // keeps 2-3 char queries index-served. Channel search only needs
      // word/start-of-name matching (owner decision), so this is the right
      // trade, and the (now far cheaper) rebuild stays as the safe fallback.
      // Runs once per install on upgrade; the channels table is untouched.
      ..add(SqliteMigration(35, (tx) async {
        // Drop the sync triggers BEFORE the table (they reference channels_fts).
        await tx.execute('DROP TRIGGER IF EXISTS channels_ai;');
        await tx.execute('DROP TRIGGER IF EXISTS channels_au;');
        await tx.execute('DROP TRIGGER IF EXISTS channels_ad;');
        await tx.execute('DROP TABLE IF EXISTS channels_fts;');
        await tx.execute('''
          CREATE VIRTUAL TABLE channels_fts USING fts5(
            name,
            content='channels',
            content_rowid='id',
            tokenize='unicode61',
            prefix='2 3'
          );
        ''');
        // One-time repopulate from the existing channels (paid once here, not
        // per refresh).
        await tx.execute('''
          INSERT INTO channels_fts(rowid, name)
          SELECT id, name FROM channels;
        ''');
        // Recreate the sync triggers BYTE-IDENTICAL to Sql.reconcileFtsTriggers
        // (channels_au is AFTER UPDATE OF name, per migration 11) so the
        // boot-time reconcile never treats them as drifted and rebuilds.
        await tx.execute('CREATE TRIGGER IF NOT EXISTS channels_ai '
            'AFTER INSERT ON channels BEGIN '
            'INSERT INTO channels_fts(rowid, name) VALUES (new.id, new.name); END;');
        await tx.execute('CREATE TRIGGER IF NOT EXISTS channels_ad '
            'AFTER DELETE ON channels BEGIN '
            "INSERT INTO channels_fts(channels_fts, rowid, name) "
            "VALUES('delete', old.id, old.name); END;");
        await tx.execute('CREATE TRIGGER IF NOT EXISTS channels_au '
            'AFTER UPDATE OF name ON channels BEGIN '
            "INSERT INTO channels_fts(channels_fts, rowid, name) "
            "VALUES('delete', old.id, old.name); "
            'INSERT INTO channels_fts(rowid, name) VALUES (new.id, new.name); END;');
      }))
      // fix523: permanently drop dead/superseded secondary indexes on `channels`
      // so they are NEVER rebuilt in the refresh recreate loop
      // (Sql.withDroppedBrowseIndexes reads sqlite_master, so a dropped index
      // simply stops appearing — no loop code change needed). Each removal
      // eliminates one ~20-36s CREATE INDEX from every full refresh. Limited to
      // the 3 highest-confidence superseded/dead-by-construction indexes that
      // passed an adversarial dead-index review. DROP IF EXISTS = idempotent;
      // the historical CREATE INDEX migrations (mig 1 / mig 11) are left intact
      // (immutable history — a fresh install creates then drops them, cheap on
      // an empty table). Roll back via a later migration that re-CREATEs.
      ..add(SqliteMigration(36, (tx) async {
        // index_channels_browse_order (mig 11): fully superseded by the
        //   tier-CASE browse indexes (mig 27/30/34); alpha browse's ORDER BY
        //   (6-tier CASE + name COLLATE NOCASE) cannot use its favorite-DESC /
        //   stream_validated-DESC / last_watched-DESC shape.
        await tx.execute('DROP INDEX IF EXISTS index_channels_browse_order;');
        // index_channel_favorite (mig 1): single-col favorite — only ever a
        //   residual AND favorite=1 after a source_id/media_type filter or
        //   inside the tier CASE, never a leading equality this index serves.
        await tx.execute('DROP INDEX IF EXISTS index_channel_favorite;');
        // index_channel_media_type (mig 1): cardinality 0/1/2 — non-selective;
        //   always combined with source_id or led by a media_type browse
        //   composite (idx_channels_browse_mt / idx_channel_src_media_url).
        await tx.execute('DROP INDEX IF EXISTS index_channel_media_type;');
      }))
      // fix528: Safe-Mode-ON TV browse went 7-84s on the onn 4K box. fix524
      // first applied Safe Mode on TV, appending `AND COALESCE(is_adult,0)=0`
      // (safeModeClause) to the browse query — but EVERY partial browse index
      // lacks is_adult, so it's a RESIDUAL the planner can't serve in sort order
      // -> USE TEMP B-TREE over the whole media_type partition (~1.17M rows;
      // 84s/0-rows = a fully-adult source scanned to exhaustion). These
      // SAFE-MODE-VARIANT partials duplicate the existing browse index KEY
      // columns (byte-identical to mig 30/33/34 & BrowseOrder — guarded by
      // browse_order_test) with `AND COALESCE(is_adult,0)=0` added to the PARTIAL
      // WHERE (never the key — a key column would scatter the safe-OFF sort).
      // Safe-ON matches the variant (full filter+ORDER BY service, no temp
      // b-tree, stops at LIMIT); Safe-OFF carries no is_adult predicate so it
      // can't match the variant and keeps using the ORIGINAL indexes unchanged
      // (zero safe-off regression). Also re-asserts the 3 mig-34 partials missing
      // on fix518-era DBs (idempotent — closes the "no such index" perf gap).
      // Wrapped in the fix523 memory pragmas: this runs OUTSIDE
      // withDroppedBrowseIndexes, and each ~1.17M-row partial CREATE
      // external-merge-sorts (a ~2MiB cache spills to slow eMMC). Restored after.
      ..add(SqliteMigration(37, (tx) async {
        try {
          await tx.execute('PRAGMA temp_store = FILE;');
          await tx.execute('PRAGMA cache_size = -32768;');
        } catch (_) {}
        // provider-mode safe variant (mirrors idx_browse_prov, mig 33)
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_prov_safe ON channels(
            media_type,
            (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END),
            (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1
              THEN 0 ELSE 1 END),
            provider_order,
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1
            AND COALESCE(is_adult,0) = 0;
        ''');
        // category-mode safe variant (mirrors idx_browse_cat, mig 33)
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_cat_safe ON channels(
            media_type,
            (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END),
            (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1
              THEN 0 ELSE 1 END),
            group_name COLLATE NOCASE,
            provider_order,
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1
            AND COALESCE(is_adult,0) = 0;
        ''');
        // alpha-mode safe variant (mirrors idx_channels_browse_mt, mig 30)
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_channels_browse_mt_safe ON channels(
            media_type,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1
            AND COALESCE(is_adult,0) = 0;
        ''');
        // source-led alpha safe variant (mirrors idx_browse_src_mt, mig 34) so
        // the mixed-union per-source inner subqueries seek (source_id, media_type)
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_src_mt_safe ON channels(
            source_id,
            media_type,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1
            AND COALESCE(is_adult,0) = 0;
        ''');
        // re-assert the mig-34/33 partials missing on fix518-era DBs (idempotent;
        // verbatim from their migrations so withDroppedBrowseIndexes recaptures
        // them on the next refresh).
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_src_mt
          ON channels(
            source_id,
            media_type,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1;
        ''');
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_src_grp
          ON channels(
            source_id,
            group_id,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL;
        ''');
        await tx.execute('''
          CREATE INDEX IF NOT EXISTS idx_browse_cat ON channels(
            media_type,
            (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END),
            (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1
              THEN 0 ELSE 1 END),
            group_name COLLATE NOCASE,
            provider_order,
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1;
        ''');
        // fix528: restore the ~2 MiB default cache (best-effort, like fix523).
        try {
          await tx.execute('PRAGMA cache_size = -2000;');
        } catch (_) {}
      }))
      // fix530: the app had NEVER run a full ANALYZE (only PRAGMA optimize), so
      // the planner was blind and chose the NON-safe browse indexes over the
      // fix528 *_safe partial variants — leaving Safe-Mode browse on the slow
      // residual-is_adult scan (on-box: a fully-adult 2-source slice measured
      // 105s, rows=0, because it walked the whole media_type partition skipping
      // adult rows). ANALYZE records each partial index's TRUE row count; the
      // *_safe partials are smaller (adult rows excluded) so the planner now
      // prefers them for the safe-mode query (filter + ORDER BY index-served, no
      // full-partition scan; an all-adult source's _safe slice is ~0 rows =
      // instant). One-time; wrapped in the fix523 memory pragmas.
      ..add(SqliteMigration(38, (tx) async {
        try {
          await tx.execute('PRAGMA temp_store = FILE;');
          await tx.execute('PRAGMA cache_size = -32768;');
        } catch (_) {}
        await tx.execute('ANALYZE;');
        try {
          await tx.execute('PRAGMA cache_size = -2000;');
        } catch (_) {}
      }))
      // fix537: the enable/disable-source delay (10-72s on the onn 4K box,
      // confirmed on the field db.sqlite: 1.2M channels, ~1GB of indexes) was
      // write-amplification. Eight browse indexes were PARTIAL on
      // `cat_enabled = 1`, so toggling cat_enabled on hundreds of thousands of
      // rows (Select-All / source enable) inserted/removed every one of those
      // rows in every partial index. Measured on the real DB: removing
      // cat_enabled from the index predicate cut an all-source live toggle from
      // 11.0s to 0.8s (13x) with NO browse regression — the browse queries keep
      // these indexes (planner-verified for every sort mode) and apply
      // `cat_enabled = 1` as a cheap residual filter on the already-narrowed
      // page (VisibilityClause still emits it). Also drops 5 never-selected
      // indexes (idx_browse_cat/_safe never beat idx_channels_browse_mt_safe;
      // index_channel_name is covered by index_channel_name_source;
      // idx_channel_adult/_divider are unused). The VACUUM that reclaims the
      // freed pages (~290MB on the field DB) runs once AFTER migrate(), below
      // (VACUUM cannot run inside the migration transaction).
      ..add(SqliteMigration(39, (tx) async {
        // fix542: migration 39 is now TRIVIAL — it only creates the marker
        // table. The original fix537 body (drop 5 dead indexes + rebuild 7
        // browse indexes without cat_enabled + VACUUM) ran INSIDE this
        // migration on the cold-start path, before runApp(). On a device with
        // the full ~1.43GB catalog that was ~27s of index work + a full-file
        // VACUUM on the main thread, which blacked-out/ANR-killed the app on
        // open (both phone and the onn box, on the 2.0.35->latest jump). All of
        // that heavy work is deferred to Sql.runPendingIndexMaintenance(),
        // invoked unawaited from main() AFTER first frame and gated by the
        // app_meta marker so it runs at most once. Until it completes, the OLD
        // cat_enabled-partial indexes remain and browse works normally (enable-
        // source is merely slow, the pre-fix537 behaviour) — never a crash.
        await tx.execute(
          'CREATE TABLE IF NOT EXISTS app_meta'
          ' (key TEXT PRIMARY KEY, value TEXT);',
        );
      }))
      ..add(SqliteMigration(40, (tx) async {
        // fix583 (#18): the groups unique index was (name, source_id), but
        // `media_type` was added to groups later (migration 33) and never added
        // to the constraint — so a Live category and a Movie/Series category
        // with the SAME name collided on insert (the second was silently
        // dropped). Recreate the index to include media_type so same-named
        // categories across media types coexist. The 3-column index is LESS
        // restrictive than the old 2-column one, so it cannot fail on existing
        // data. Runs on every install (fresh runs the whole chain).
        await tx.execute('DROP INDEX IF EXISTS index_group_unique;');
        await tx.execute(
          'CREATE UNIQUE INDEX index_group_unique '
          'ON groups(name, source_id, media_type);',
        );
      }))
      ..add(SqliteMigration(41, (tx) async {
        // fix629: drop three bare single-column channels indexes that NO app
        // query ever seeks on — they only cost write-amplification on every
        // channel insert during a refresh (millions of rows). Confirmed dead
        // against docs/CHANNELS_SQL_INDEX_MAP.md:
        //   - index_channels_stream_id(stream_id): stream_id is only read by
        //     rowid/PK-style lookups, never filtered/ordered by this index.
        //   - index_channels_group_name(group_name): superseded by group_id and
        //     the browse composites; no query filters on group_name.
        //   - index_channel_last_watched(last_watched): superseded by the
        //     PARTIAL composite idx_channel_lastwatched_media
        //     (last_watched, media_type WHERE last_watched IS NOT NULL).
        // Also removed from Sql._canonicalChannelIndexes so the fix628 startup
        // self-heal never resurrects them. Base migration 1 still creates them
        // on a fresh install; this migration drops them immediately after.
        await tx.execute('DROP INDEX IF EXISTS index_channels_stream_id;');
        await tx.execute('DROP INDEX IF EXISTS index_channels_group_name;');
        await tx.execute('DROP INDEX IF EXISTS index_channel_last_watched;');
      }))
      ..add(SqliteMigration(42, (tx) async {
        // fix641: persist the Xtream subscription expiry + account status from
        // player_api.php user_info, so the source edit screen can show the
        // expiry date and the app can auto-disable an expired line on refresh.
        await tx.execute(
            'ALTER TABLE sources ADD COLUMN exp_date INTEGER;');
        await tx.execute(
            'ALTER TABLE sources ADD COLUMN status TEXT;');
      }));
    // fix608 (#2): bound memory so any migration that rebuilds a browse index
    // over an ALREADY-POPULATED channels table — a user upgrading with a huge
    // catalog (e.g. 272k channels on a Shield, where it disk-spilled ~75s/index
    // and froze startup) — merge-sorts within a 32 MiB cap instead of spilling
    // on SQLite's ~2 MiB default. The import path (Sql.withDroppedBrowseIndexes)
    // already does this; this covers the migration path. Connection-scoped on
    // the single sqlite_async writer; restored to the normal browse cap after.
    try {
      await db.execute('PRAGMA temp_store = FILE;');
      await db.execute('PRAGMA cache_size = -32768;');
    } catch (_) {}
    await migrations.migrate(db);
    try {
      await db.execute('PRAGMA cache_size = -2000;');
    } catch (_) {}
    // fix542: the heavy fix537 index maintenance (drop 5 dead indexes, rebuild
    // 7 browse indexes without cat_enabled, then VACUUM) is NO LONGER run on
    // this cold-start path — it blacked-out/ANR-killed the app on open for the
    // full ~1.43GB catalog. It now runs in Sql.runPendingIndexMaintenance(),
    // called unawaited from main() after first frame, gated once by app_meta.
    // fix419: give the planner real statistics. The app never ran ANALYZE, so
    // SQLite planned blind — part of why the device chose the slow VOD index.
    // PRAGMA optimize is cheap on repeat runs (re-analyzes only changed tables).
    try {
      await db.execute('PRAGMA optimize;');
    } catch (e) {
      AppLog.warn('PRAGMA optimize failed: $e');
    }

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
      }))
      // fix502: FTS5 over programme titles for fast "what's on" search on a
      // ~1M-row table (no leading-wildcard scans). Trigram + external content,
      // mirroring channels_fts. NO sync triggers — programmes change only
      // during a batch EPG refresh, so the index is rebuilt once afterward
      // (Sql.rebuildProgrammesFts) instead of paying per-row trigger cost on
      // the bulk insert.
      ..add(SqliteMigration(2, (tx) async {
        await tx.execute('''
          CREATE VIRTUAL TABLE programmes_fts USING fts5(
            title,
            content='programmes',
            content_rowid='id',
            tokenize='trigram'
          );
        ''');
        await tx.execute('''
          INSERT INTO programmes_fts(rowid, title)
          SELECT id, title FROM programmes;
        ''');
      }));
    await migrations.migrate(db);

    AppLog.info('EpgDb: opened epg.sqlite');

    // Same WAL tuning as db.sqlite — raise auto-checkpoint threshold so
    // the explicit Sql.checkpointAndTruncateWal() calls control flushing.
    await db.execute('PRAGMA wal_autocheckpoint = 8000');

    // fix593: self-heal the programme-title FTS. programmes_fts is only
    // (re)built after an XMLTV refresh (epg_service) — never on a plain source
    // refresh or app start. If programmes were loaded but the FTS is empty (or
    // out of sync), EPG title search returns 0 and the search "On now"/"Coming
    // up" shelves are silently always empty (diag 2026-06-28: epgProg=.../0 on
    // every query while the guide showed NOW/NEXT). Rebuild once if the counts
    // disagree.
    // fix644: run the check FIRE-AND-FORGET instead of blocking the open. The
    // two COUNT(*)s walk ~2.8M programme rows plus the trigram FTS — ~7-15s
    // EACH on the onn — and every first EPG consumer (the guide's category
    // select) was stuck behind them (2026-07-03 log: ~26s category -> channels).
    // Worst case during the check window: EPG title search briefly returns
    // stale/empty shelves; the guide's NOW/NEXT grid (plain programmes table)
    // is unaffected.
    unawaited(_selfHealProgrammesFts(db));

    return db;
  }

  /// fix644: extracted fix593 self-heal — see the call site above.
  static Future<void> _selfHealProgrammesFts(SqliteDatabase db) async {
    try {
      final progCount = (await db.get('SELECT count(*) c FROM programmes'))['c']
              as int? ??
          0;
      final ftsCount =
          (await db.get('SELECT count(*) c FROM programmes_fts'))['c'] as int? ??
              0;
      AppLog.info('EpgDb: programmes=$progCount programmes_fts=$ftsCount');
      if (progCount > 0 && ftsCount != progCount) {
        AppLog.warn('EpgDb: programmes_fts stale (fts=$ftsCount vs '
            'programmes=$progCount) — rebuilding (fix593)');
        await db
            .execute("INSERT INTO programmes_fts(programmes_fts) VALUES('rebuild');");
        final after =
            (await db.get('SELECT count(*) c FROM programmes_fts'))['c'] as int? ??
                0;
        AppLog.info('EpgDb: programmes_fts rebuilt — now $after rows');
      }
    } catch (e) {
      AppLog.warn('EpgDb: programmes_fts self-heal check failed — $e');
    }
  }

  // fix644: memoize the OPEN FUTURE, not the result. The old
  // `_db ??= await _createDB()` raced: every caller that arrived while the
  // first open was still in flight saw `_db == null` and started ANOTHER full
  // open (2026-07-03 onn log: two "EpgDb: opened" + three programme-count
  // pairs stacked ~26s of duplicate work behind the guide's first category
  // select). With the future memoized, concurrent callers await the same open.
  static Future<SqliteDatabase>? _dbFuture;

  static Future<SqliteDatabase> get db async {
    return _dbFuture ??= _createDB();
  }
}
