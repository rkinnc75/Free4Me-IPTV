# free4me-iptv SQL Table & Index Reference

Companion to **[`docs/CHANNELS_SQL_INDEX_MAP.md`](docs/CHANNELS_SQL_INDEX_MAP.md)** — that document is the canonical map for the **`channels`** table and its 20+ browse-tier indexes (migrations 1–40 + `sql.dart` machinery). This document covers **every other table** across both SQLite files. The `channels` indexes are **not** duplicated here; where a statement below joins to `channels`, only the non-`channels` side is analyzed.

All file:line citations are from `lib/backend/`. Read-only enumeration — no DB was modified.

---

## 1. Overview

The app uses **two independent SQLite files**, each with its own WAL (both open with `wal_autocheckpoint=8000`; migration path caps cache at 32 MiB to avoid disk-spill on huge catalogs):

| File | Tables (live) | Migration authority |
|---|---|---|
| **`db.sqlite`** | `sources`, `channels`†, `groups`, `channel_http_headers`, `movie_positions`, `settings`, `playback_metrics`, `app_meta`, `channels_fts` (FTS5 vtab) | `DbFactory` migrations 1–40 |
| **`epg.sqlite`** | `programmes`, `programmes_fts` (FTS5 vtab), `epg_refresh_log` | `EpgDbFactory` migrations 1–2 |

† **`channels` is documented separately** in `docs/CHANNELS_SQL_INDEX_MAP.md`.

**Why the split:** large EPG writes (600k+ inserts, 800k+ stale deletes) live in `epg.sqlite` so they don't inflate the WAL that `db.sqlite` channel-search reads must traverse. Cross-file FKs are **not** enforced by SQLite; `programmes.source_id` / `epg_refresh_log.source_id` referential integrity is app-layer (`Sql.deleteEpgForSource`, called from `Sql.deleteSource`).

**Lifecycle note:** `programmes` + `epg_refresh_log` were originally created in `db.sqlite` (mig5), **dropped** (mig8 no-op, mig9), and recreated in `epg.sqlite`. Only the `epg.sqlite` copies are live.

---

## 2. Per-table sections

### 2.1 `sources` (db.sqlite)

One row per configured IPTV provider (Xtream/M3U/XMLTV). Holds connection creds, EPG endpoint, per-source engine/sort/dividers defaults, connection cap, tag color, last-refresh counts, and EPG auto-discovery state.

**Columns** (base + ALTERs): `id INTEGER PK`; `name varchar(100)`; `source_type integer`; `url varchar(500)`; `username varchar(100)`; `password varchar(100)`; `enabled integer DEFAULT 1`; `epg_url TEXT` (mig5); `default_engine TEXT` (mig7, deprecated fix350); `max_connections INTEGER` (mig16); `color INTEGER` ARGB (mig17); `sort_mode TEXT` 'provider'|'alpha' (mig20); `last_live_count`/`last_movie_count`/`last_series_count INTEGER` (mig21); `hide_dividers INTEGER` (mig22); `epg_discovery_state TEXT` NULL|'auto'|'manual'|'none' (mig31).

**Indexes**

| Index | Columns | Unique | Origin |
|---|---|---|---|
| PK (rowid) | `id` | — | mig1 (`db_factory.dart:16`) |
| `index_source_name` | `name` | ✔ | mig1 (`db_factory.dart:82`) |
| `index_source_enabled` | `enabled` | — | mig1 (`db_factory.dart:84`) |

**SQL ↔ index**

| Fn / file:line | Op | WHERE / JOIN | ORDER BY | Index used | Notes |
|---|---|---|---|---|---|
| `getOrCreateSourceByName` probe `sql.dart:898` | SELECT | `name=?` | — | **`index_source_name`** | Unique-key lookup. |
| `getOrCreateSourceByName` update `sql.dart:909` | UPDATE | `id=?` | — | **PK** | rowid lookup. |
| `getOrCreateSourceByName` insert `sql.dart:935` | INSERT | — | — | maintains all 3 | Then `last_insert_rowid()` (953). |
| `_allSourceIds` `sql.dart:1797` | SELECT | — | — | **full scan** (inferred) | Returns every id; scan expected. |
| `sourceNameExists` `sql.dart:1912` | SELECT | `name=?` | — | **`index_source_name`** | Add-source dedupe. |
| `getSources` `sql.dart:1922` | SELECT `*` | — | — | **full scan** (inferred) | Read chokepoint; also refreshes AppLog redaction (fix374). |
| `getSourceById` `sql.dart:1936` | SELECT `*` | `id=?` | — | **PK** | getOptional. |
| `getEnabledSourcesMinimal` `sql.dart:1975` | SELECT | `enabled=1` | — | **`index_source_enabled`** (inferred; low-selectivity, planner may scan) | Refresh/fetch loop. |
| `hasSources` `sql.dart:1990` | SELECT | — LIMIT 1 | — | **PK** / early-out | Onboarding gate. |
| `deleteSource` `sql.dart:2035` | DELETE | `id=?` | — | **PK** | Final step; EPG cleaned first (cross-file). |
| `updateSource` `sql.dart:2103` (exec 2114) | UPDATE | `id=?` | — | **PK** | Edit-Source persist; extracted const for Rule-8 test. |
| `getSourceFromId` `sql.dart:2132` | SELECT `*` | `id=?` | — | **PK** | `db.get` — throws if missing. |
| `setSourceEnabled` `sql.dart:2138` | UPDATE | `id=?` | — | **PK** | Source-level toggle. |
| `setSourceEpgUrl` `sql.dart:2457` | UPDATE | `id=?` | — | **PK** | Manual EPG dialog. |
| `setSourceEpgDiscovery` found `sql.dart:2480` / none `sql.dart:2488` | UPDATE | `id=?` | — | **PK** | fix386 auto-discovery persist. |
| `_uniformSortMode` `sql.dart:3187` | SELECT DISTINCT | `id IN (…)` | — | **PK** (IN-list) | fix344/345 — single shared mode or null. |
| `_sourceModes` `sql.dart:3202` | SELECT | `id IN (…)` | — | **PK** (IN-list) | fix393 per-source mode map for mixed-mode UNION browse. |
| `getAllChannelNamesForCache` `sql.dart:1279` | SELECT (LEFT JOIN) | `s.id=c.source_id`; `c.url IS NOT NULL` | — | **PK** (join probe) | fix322 pulls `hide_dividers` into cache tuples. |
| search/browse favorites subquery `sql.dart:1165` | SELECT (correlated) | `s.id=c.source_id` | (Favorites ORDER BY) | **PK** | fix356 source-name tier; tiny result set. |
| `_searchLike` favorites subquery `sql.dart:3358` | SELECT (correlated) | `s.id=c.source_id` | (Favorites ORDER BY) | **PK** | fix356, LIKE path. |
| `searchGroup` provider subquery `sql.dart:1873` | SELECT (correlated) | `s.id=source_id` | (groups ORDER BY) | **PK** | Source-name tier for Categories provider sort. |
| `BrowseOrder` embedded const `browse_order.dart:73` | SELECT (correlated) | `id=c.source_id` | emitted into browse ORDER BY | **PK** | Per-row term; avoided when sort mode uniform. |

DDL ALTERs (index-neutral): mig5/7/16/17/20/21/22/31 (`db_factory.dart:167,230,374,378,415,421,440,598`).

---

### 2.2 `groups` (db.sqlite)

Provider category/group definitions (one per source+media_type). Drives the Categories grid; `enabled` toggles visibility (denormalized to `channels.cat_enabled`), `favorite` pins to top.

**Columns:** `id INTEGER PK`; `name varchar(100)`; `image varchar(500)`; `source_id integer` FK→sources(id); `media_type integer` (mig3); `enabled INTEGER DEFAULT 1` (mig23); `favorite INTEGER DEFAULT 0` (mig25).

**Indexes**

| Index | Columns | Unique | Origin |
|---|---|---|---|
| PK (rowid) | `id` | — | mig1 (`db_factory.dart:69`) |
| `index_group_unique` | `(name, source_id, media_type)` | ✔ | **recreated mig40** (`db_factory.dart:965`) from orig `(name, source_id)` mig1 (`db_factory.dart:86`) |
| `index_group_name` | `name` | — | mig1 (`db_factory.dart:87`) |
| `index_group_source_id` | `source_id` | — | mig1 (`db_factory.dart:103`) |
| `index_groups_media_type` | `media_type` | — | mig3 (`db_factory.dart:121`) |

**SQL ↔ index**

| Fn / file:line | Op | WHERE / JOIN | ORDER BY | Index used | Notes |
|---|---|---|---|---|---|
| `updateGroups` rebuild `sql.dart:791` | UPSERT (INSERT…SELECT) | `channels.source_id=?`; GROUP BY `group_name,media_type`; ON CONFLICT `(name,source_id,media_type)` | — | **`index_group_unique`** (conflict target) | fix583/#18 target matches mig40 index. |
| `updateGroups` restore disabled `sql.dart:806` | UPDATE | `source_id=?`, `name IN (…)` | — | **`index_group_source_id`** or `index_group_unique` (inferred) | fix298 preserve user-disabled categories. |
| `updateGroups` group_id backfill `sql.dart:825` | UPDATE (…FROM groups g) | `g.name=c.group_name, g.source_id=?, g.media_type IS c.media_type` | — | **`index_group_unique`** (inferred; full join key) | fix517 set-based; target=channels. |
| `updateGroups` cat_enabled denorm `sql.dart:840` | UPDATE (…FROM groups g) | `g.id=c.group_id, c.source_id=?` | — | **PK** (g.id probe) | fix365/517; target=channels. |
| `setGroupEnabled` `sql.dart:1322` | UPDATE | `id=?` | — | **PK** | fix278; companion `channels.cat_enabled` at 1327. |
| `getDisabledGroupIds` `sql.dart:1341` | SELECT | `COALESCE(enabled,1)=0` | — | **full scan** (inferred; expr not indexable) | fix298 cache-exclude set. |
| `setAllGroupsEnabled` `sql.dart:1362` | UPDATE | `source_id IN (…)`, opt `media_type IN (…)` | — | **`index_group_source_id`** (inferred) | fix278/296 bulk. |
| `setAllGroupsEnabled` resync `sql.dart:1381` | SELECT | same WHERE | — | **`index_group_source_id`** (inferred) | Cache resync, no rebuild. |
| `setAllGroupsEnabledForSearch` `sql.dart:1419` | UPDATE | `id IN (SELECT … WHERE <groupSearchWhere>)` | — | **PK** (outer) + subquery below | fix389; no id-list ceiling. |
| `setAllGroupsEnabledForSearch` subquery `sql.dart:1420 & 1425` | SELECT | keyword LIKE(s), `media_type`, `source_id IN (…)`, safe-mode block | — | **`index_group_source_id`** partial; LIKE not index-served (inferred) | Feeds both bulk UPDATEs. |
| `setAllGroupsEnabledForSearch` resync `sql.dart:1431` | SELECT | `<groupSearchWhere>` | — | as above (inferred) | Cache resync. |
| `searchGroup` `sql.dart:1849` | SELECT | `<groupSearchWhere>`: LIKE(s), `media_type`, `source_id IN (…)`, safe-mode | `COALESCE(favorite,0) DESC, COALESCE(enabled,1) DESC, [provider subq ASC,] name COLLATE NOCASE ASC, id ASC`; LIMIT ?,? | **`index_group_source_id`** for filter; **ORDER BY not index-served → temp B-tree sort** (inferred) | The user-facing Categories grid. COALESCE/NOCASE tiers can't use `index_group_name`. |
| `favoriteGroup` `sql.dart:1905` | UPDATE | `id=?` | — | **PK** | fix308 toggle. |
| `deleteSource` `sql.dart:2034` | DELETE | `source_id=?` | — | **`index_group_source_id`** | Before sources delete. |
| `wipeSource` stash `sql.dart:2050` | SELECT | `source_id=?`, `COALESCE(enabled,1)=0` | — | **`index_group_source_id`** (filter), expr residual | fix298/320 capture disabled names. |
| `wipeSource` full wipe `sql.dart:2073` | DELETE | `source_id=?` | — | **`index_group_source_id`** | Refresh full-wipe branch. |
| `wipeSource` partial `sql.dart:2083` | DELETE | `source_id=? AND id NOT IN (SELECT DISTINCT group_id FROM channels …)` | — | **`index_group_source_id`** (outer) | fix321 keep surviving-channel categories. |
| `getGroupsCurated` `sql.dart:2151` | SELECT | `source_id=? AND (COALESCE(favorite,0)=1 OR COALESCE(enabled,1)=0)` | — | **`index_group_source_id`** (filter), expr residual | fix355 export (favorited/disabled only). |
| `applyGroupState` `sql.dart:2171` | UPDATE | `source_id=?, name=?` | — | **`index_group_unique`** prefix (inferred) | fix355 restore. |
| `applyGroupState` id-resolve subquery `sql.dart:2183` | SELECT | `source_id=?, name=?` LIMIT 1 | — | **`index_group_unique`** prefix (inferred) | fix370 companion cat_enabled sync. |

**Diagnostics / stale probes (log-only, not live writes):**

| Fn / file:line | Op | Notes |
|---|---|---|
| `logRefreshQueryPlans.plan updateGroups.update` `sql.dart:140` | SELECT (EXPLAIN QUERY PLAN) | fix222 probe of **OLD** correlated-subquery group_id form — **stale** vs live set-based `sql.dart:825`. |
| `logRefreshQueryPlans.plan updateGroups.insertSelect` `sql.dart:147` | SELECT (EXPLAIN QUERY PLAN) | fix222 probe; GROUP BY `group_name` only — **stale** vs live `GROUP BY group_name,media_type` (`sql.dart:796`). |
| TimedDb fix533 enabled dump `timed_db.dart:111` | SELECT | Per source/media_type `COUNT(*)`, `SUM(enabled)`; full scan (log-only). |
| TimedDb fix533 orphan `timed_db.dart:126` | SELECT (LEFT JOIN channels) | NULL/dangling `group_id` per source (log-only). |

DDL: mig3/23/25/29/40 (`db_factory.dart:121,447,463,542,965`). mig29 (`:542`) backfills `channels.cat_enabled` reading `groups` (target=channels).

---

### 2.3 `programmes` (epg.sqlite)

XMLTV program-guide entries (now/next). Its own file so bulk EPG writes don't inflate `db.sqlite`'s WAL.

**Columns:** `id INTEGER PK AUTOINCREMENT`; `epg_channel_id TEXT NOT NULL`; `source_id INTEGER NOT NULL` (logical FK, app-enforced); `title TEXT NOT NULL`; `description TEXT`; `category TEXT`; `start_utc INTEGER NOT NULL`; `stop_utc INTEGER NOT NULL`; `episode_num TEXT`.

**Indexes** (all `EpgDbFactory` mig1)

| Index | Columns | Unique | file:line |
|---|---|---|---|
| PK | `id` | — | `db_factory.dart:1078` |
| `idx_programs_channel_time` | `(epg_channel_id, source_id, start_utc)` | — | `db_factory.dart:1091` |
| `idx_programs_time_range` | `(source_id, start_utc, stop_utc)` | — | `db_factory.dart:1095` |
| `idx_programs_unique` | `(source_id, epg_channel_id, start_utc)` | ✔ | `db_factory.dart:1101` |

**SQL ↔ index**

| Fn / file:line | Op | WHERE / JOIN | ORDER BY | Index used | Notes |
|---|---|---|---|---|---|
| `EpgService.isStale` `epg_service.dart:60` | SELECT count | `start_utc<=? AND stop_utc>?` | — | **none usable → scan / partial range** | No `source_id`/`epg_channel_id` predicate; `idx_programs_time_range` leading col unusable. **Hot-ish unindexed query.** |
| `deleteProgramsForSource` `sql.dart:2551` | DELETE | `source_id=?` | — | **`idx_programs_time_range`** (or `idx_programs_unique`; both lead `source_id`) | Pre-import purge. |
| `deleteEpgForSource` `sql.dart:2565` | DELETE | `source_id=?` | — | **`idx_programs_time_range`** / `idx_programs_unique` | Cross-file cascade; `_epgWriteWithRetry`. |
| `insertProgramsBatch` `sql.dart:2655` | UPSERT | ON CONFLICT `(source_id,epg_channel_id,start_utc)` | — | **`idx_programs_unique`** (conflict target) | 100-row chunks; fix625 retry. |
| `deleteStalePrograms` `sql.dart:2754` | DELETE | `source_id=? AND stop_utc<?` | — | **`idx_programs_time_range`** (source_id eq; stop_utc trailing → partial) | GC ended programmes; `_epgWriteWithRetry`. |
| `getNowNext` `sql.dart:2767` | SELECT | `epg_channel_id=? AND source_id=? AND stop_utc>?` | `start_utc ASC` LIMIT 2 | **`idx_programs_channel_time`** (eq prefix + ordered start_utc) | Ideal. |
| `getSchedule` `sql.dart:2797` | SELECT | `epg_channel_id=? AND source_id=? AND start_utc<? AND stop_utc>?` | `start_utc ASC` | **`idx_programs_channel_time`** (eq prefix + range + ordered) | Ideal. |
| `getGridPrograms` `sql.dart:2953` | SELECT | `source_id=? AND epg_channel_id IN (≤900) AND start_utc<? AND stop_utc>?` | — | **`idx_programs_channel_time`** (via IN-list + source_id) | fix503 rail-scoped, per-source chunk. |
| `getAvailableEpgIds` outer `sql.dart:3062` | SELECT | `source_id=?`; GROUP BY `epg_channel_id` | `epg_channel_id ASC` | outer **`idx_programs_time_range`**/scan by source; correlated subquery served by **`idx_programs_channel_time`** | subq: `p2.epg_channel_id=p.epg_channel_id AND p2.source_id=p.source_id` ORDER BY `start_utc DESC LIMIT 1`. |
| self-heal count `db_factory.dart:1151` | SELECT count | — | — | **full scan** | fix593 vs FTS count. |

---

### 2.4 `programmes_fts` (epg.sqlite)

FTS5 virtual table over programme **titles**. `content='programmes'`, `content_rowid='id'`, `tokenize='trigram'` (mig2/fix502). External-content; **no sync triggers by design** — rebuilt en masse after each EPG refresh, self-healed at open (fix593).

**Indexes:** FTS5-internal shadow tables only (no user `CREATE INDEX`). `rowid = programmes.id`.

**SQL ↔ index**

| Fn / file:line | Op | Detail | Index used | Notes |
|---|---|---|---|---|
| create vtab `db_factory.dart:1123` | CREATE | `fts5(title, content='programmes', content_rowid='id', tokenize='trigram')` | — | mig2. |
| seed `db_factory.dart:1131` | INSERT | `SELECT id,title FROM programmes` | maintains shadow | mig2 one-time (empty on fresh DB). |
| self-heal count `db_factory.dart:1155` | SELECT count | full scan of fts | shadow scan | fix593. |
| self-heal rebuild `db_factory.dart:1162` | INSERT | `programmes_fts(programmes_fts) VALUES('rebuild')` | rebuilds shadow | Runs only when counts disagree. |
| self-heal verify `db_factory.dart:1164` | SELECT count | — | shadow scan | Post-rebuild. |
| `rebuildProgrammesFts` `sql.dart:2832` | INSERT | `VALUES('rebuild')` | rebuilds shadow | fix502 once per refresh; `_epgWriteWithRetry`. |
| `searchPrograms` `sql.dart:2858` | SELECT | `programmes_fts MATCH ?` CROSS JOIN `programmes p ON p.id=f.rowid`, `p.source_id IN (…) AND p.stop_utc>? AND p.start_utc<?`; ORDER BY `p.start_utc ASC` LIMIT ? | **FTS posting list** (driver) + **programmes PK** resolve | fix502/556: CROSS JOIN forces FTS outer driver; residual filter+sort ≤200. Avoids `idx_programs_time_range`-driven per-row FTS probes. |
| `searchPrograms` empty-path diag `sql.dart:2886` | SELECT count | `programmes_fts MATCH ?` | **FTS** | fix595; only when windowed search returns 0. |

---

### 2.5 `epg_refresh_log` (epg.sqlite)

One row per source: last refresh time, programmes loaded, last error.

**Columns:** `source_id INTEGER PK` (logical FK, app-enforced); `last_refreshed_utc INTEGER NOT NULL`; `programmes_loaded INTEGER NOT NULL`; `last_error TEXT`.

**Indexes:** PK on `source_id` only (rowid alias). No secondary indexes.

**SQL ↔ index**

| Fn / file:line | Op | WHERE | ORDER BY | Index used | Notes |
|---|---|---|---|---|---|
| create `db_factory.dart:1107` | CREATE | — | — | — | mig1. |
| `deleteEpgForSource` `sql.dart:2567` | DELETE | `source_id=?` | — | **PK** | `_epgWriteWithRetry`. |
| `upsertEpgRefreshLog` `sql.dart:2978` | UPSERT | ON CONFLICT `(source_id)` | — | **PK** (conflict target) | Record outcome; `_epgWriteWithRetry`. |
| `getEpgRefreshLog` `sql.dart:2992` | SELECT | `source_id=?` | — | **PK** | getOptional. |
| `getLatestEpgRefresh` `sql.dart:3010` | SELECT `MAX(last_refreshed_utc)` | — | — | **full scan** (aggregate) | fix541; table is tiny (1 row/source), scan fine. |

---

### 2.6 `movie_positions` (db.sqlite)

Resume-playback offset per movie/VOD channel. At most one row per channel.

**Columns:** `id INTEGER PK`; `channel_id integer` FK→channels(id) ON DELETE CASCADE; `position int`.

**Indexes**

| Index | Columns | Unique | file:line |
|---|---|---|---|
| PK | `id` | — | mig1 `db_factory.dart:55` |
| `index_movie_positions_channel_id` | `channel_id` | ✔ | mig1 `db_factory.dart:108` |

**SQL ↔ index**

| Fn / file:line | Op | WHERE / JOIN | Index used | Notes |
|---|---|---|---|---|
| `getMoviePositionsForExport` `sql.dart:2193` | SELECT (JOIN channels) | `c.source_id=? AND c.url IS NOT NULL AND mp.position>0` | **`index_movie_positions_channel_id`** (join probe) | fix355 export keyed by URL. |
| `applyMoviePosition` `sql.dart:2214` | UPSERT (INSERT…SELECT) | `channels WHERE source_id=? AND url=?`; ON CONFLICT `(channel_id)` | **`index_movie_positions_channel_id`** (conflict target) | fix355 restore. |
| `setPosition` `sql.dart:2224` | UPSERT | ON CONFLICT `(channel_id)` | **`index_movie_positions_channel_id`** | DO UPDATE position. |
| `getPosition` `sql.dart:2235` | SELECT | `channel_id=?` | **`index_movie_positions_channel_id`** | Read resume offset. |

---

### 2.7 `channel_http_headers` (db.sqlite)

Optional per-channel HTTP overrides (Referer/User-Agent/Origin/SSL-ignore). At most one row per channel.

**Columns:** `id INTEGER PK`; `channel_id integer` FK→channels(id) ON DELETE CASCADE; `referrer varchar(500)`; `user_agent varchar(500)`; `http_origin varchar(500)`; `ignore_ssl integer DEFAULT 0`.

**Indexes**

| Index | Columns | Unique | file:line |
|---|---|---|---|
| PK | `id` | — | mig1 `db_factory.dart:44` |
| `index_channel_http_headers_channel_id` | `channel_id` | ✔ | mig1 `db_factory.dart:105` |

**SQL ↔ index**

| Fn / file:line | Op | WHERE | Index used | Notes |
|---|---|---|---|---|
| `insertChannelHeaders` `sql.dart:859` | INSERT OR IGNORE | `(channel_id,…)` | **`index_channel_http_headers_channel_id`** (backs OR IGNORE) | channel_id from `memory['lastChannelId']`. |
| `getChannelHeaders` `sql.dart:873` | SELECT `*` | `channel_id=?` LIMIT 1 | **`index_channel_http_headers_channel_id`** | → `_rowToHeaders`. |

---

### 2.8 `app_meta` (db.sqlite)

Internal marker key/value store gating one-shot deferred maintenance. Distinct from user-facing `settings`. `CREATE TABLE IF NOT EXISTS` in mig39 (`db_factory.dart:961`).

**Columns:** `key TEXT PK`; `value TEXT`. **Indexes:** PK on `key` only.

**SQL ↔ index** (all served by **PK** on `key`)

| Fn / file:line | Op | key | Notes |
|---|---|---|---|
| `withDroppedBrowseIndexes` `sql.dart:513` | UPSERT (INSERT OR REPLACE) | `pending_browse_index_ddl` | fix628 persist captured browse DDL before drop. |
| `withDroppedBrowseIndexes` `sql.dart:585` | DELETE | `pending_browse_index_ddl` | fix628 clear once recreated. |
| `runPendingDividerCleanup` `sql.dart:1465` | SELECT | `fix546_dividers_purged` | Marker check (early return). |
| `runPendingDividerCleanup` `sql.dart:1472` | UPSERT | `fix546_dividers_purged` | Record after cleanup. |
| `runPendingIndexMaintenance` `sql.dart:1557` | SELECT | `fix537_index_rebuild_done` | fix542 marker check. |
| `runPendingIndexMaintenance` `sql.dart:1565` | SELECT | `fix537_vacuum_done` | Legacy-marker check. |
| `runPendingIndexMaintenance` `sql.dart:1569` | UPSERT | `fix537_index_rebuild_done` | Short-circuit when legacy present. |
| `runPendingIndexMaintenance` `sql.dart:1594` | UPSERT | `fix537_index_rebuild_done` | After deferred rebuild + VACUUM. |
| `ensureBrowseIndexesPresent` `sql.dart:1687` | SELECT | `pending_browse_index_ddl` | fix628 startup self-heal read. |
| `ensureBrowseIndexesPresent` `sql.dart:1730` | DELETE | `pending_browse_index_ddl` | fix628 clear after replay. |

---

### 2.9 `playback_metrics` (db.sqlite)

fix154 rolling local playback-quality history — one row per analyzed session. Local only, capped to newest 50 by the DAO.

**Columns:** `id INTEGER PK AUTOINCREMENT`; `session_start INTEGER NOT NULL`; `session_minutes REAL`; `streams_opened`, `median_first_frame_ms`, `median_stable_ms`, `startup_visible_rebuffers`, `total_rebuffers`, `visible_rebuffers`, `median_rebuffer_ms`, `reconnects_watchdog`, `reconnects_error`, `gave_up`, `created_at` — all `INTEGER NOT NULL`.

**Indexes**

| Index | Columns | file:line |
|---|---|---|
| PK | `id` | mig12 `db_factory.dart:303` |
| `idx_pm_session` | `session_start` | mig12 `db_factory.dart:320`; re-asserted IF NOT EXISTS mig13 `db_factory.dart:326` |

**SQL ↔ index**

| Fn / file:line | Op | WHERE / ORDER BY | Index used | Notes |
|---|---|---|---|---|
| `insertPlaybackMetrics` delete-dupe `sql.dart:3394` | DELETE | `session_start=?` | **`idx_pm_session`** | Idempotent re-run. |
| `insertPlaybackMetrics` insert `sql.dart:3398` | INSERT | 13 cols | maintains PK + `idx_pm_session` | Persist session summary. |
| `insertPlaybackMetrics` cap `sql.dart:3423` | DELETE | `id NOT IN (SELECT id … ORDER BY session_start DESC LIMIT 50)` | subquery ORDER BY served by **`idx_pm_session`** (reverse scan); outer by **PK** | Cap to newest 50. |
| `clearPlaybackMetrics` `sql.dart:3437` | DELETE | — (truncate) | — | fix180 wipe on new-version boot. |
| `getAggregatedMetrics` `sql.dart:3444` | SELECT `*` | — | **full scan** (≤50 rows) | Weighted aggregate. |

---

### 2.10 `settings` (db.sqlite)

Generic key/value store for app-wide preferences. `CREATE` in mig1 (`db_factory.dart:63`).

**Columns:** `key VARCHAR(50) PK`; `value VARCHAR(100)`. **Indexes:** PK on `key` only.

**SQL ↔ index**

| Fn / file:line | Op | WHERE | Index used | Notes |
|---|---|---|---|---|
| `getSettings` `sql.dart:2010` | SELECT | — | **full scan** (small) | Into HashMap, cached after first read. |
| `updateSettings` `sql.dart:2019` | UPSERT | ON CONFLICT `(key)` | **PK** (conflict target) | All `settings_io.dart`/`settings_service.dart` writes route here (`settings_service.dart:535/557`, `settings_io.dart:447`) — no direct SQL there. |

---

### 2.11 `channels_fts` (db.sqlite)

FTS5 virtual table over channel **names**. `content='channels'`, `content_rowid='id'`. Tokenizer: **unicode61, prefix='2 3'** (mig35/fix519); originally trigram (mig4). `rowid = channels.id`.

**Indexes:** FTS5-internal shadow tables only. Kept in sync by **3 triggers on `channels`** — `channels_ai` (AFTER INSERT), `channels_ad` (AFTER DELETE, FTS 'delete' op), `channels_au` (AFTER UPDATE **OF name** — narrowed in mig11 so non-name writes don't churn). Triggers are reconciled **byte-identically at boot** by `Sql.reconcileFtsTriggers` to avoid spurious rebuilds.

> Query-time `channels_fts MATCH … JOIN channels` reads belong to the `channels` search path — see `docs/CHANNELS_SQL_INDEX_MAP.md`. Below is **maintenance-only** SQL (rebuild / integrity / delete+reinsert / DDL / trigger reconcile).

**Maintenance SQL** (all operate on FTS5 shadow tables / trigger objects)

| Fn / file:line | Op | Detail | Notes |
|---|---|---|---|
| create vtab `db_factory.dart:133` | CREATE | original external-content fts5 | mig13 (trigram era). |
| recreate vtab `db_factory.dart:720` | CREATE | `fts5(unicode61, prefix='2 3')` | mig35/fix519 tokenizer switch. |
| `withSuspendedFtsTriggers` probe `sql.dart:282` | SELECT | `sqlite_master` triggers exist? | `hadTriggers` gate. |
| `withSuspendedFtsTriggers` drop `sql.dart:314` | DROP | `channels_ai/au/ad` | fix521/619/621 suspend around bulk refresh. |
| `withSuspendedFtsTriggers` targeted delete `sql.dart:350` | DELETE | `rowid IN (≤900 ids from channels WHERE source_id=?)` | fix514 per-source delete **before** bulk wipe (external-content correctness). |
| `withSuspendedFtsTriggers` targeted reinsert `sql.dart:374` | INSERT | `SELECT id,name FROM channels WHERE source_id=?` | fix514 re-index new rows after reinsert. |
| `reconcileFtsTriggers` probe `sql.dart:613` | SELECT | present triggers | rebuild-vs-drop decision. |
| `reconcileFtsTriggers` rebuild `sql.dart:622` | INSERT | `channels_fts(channels_fts) VALUES('rebuild')` | fix212/514 when triggers were absent (unless skipRebuild). |
| `reconcileFtsTriggers` create `sql.dart:624` | CREATE | `channels_ai/ad/au` | ad/au use FTS5 'delete' command. |
| `reconcileFtsTriggers` drop `sql.dart:640` | DROP | triggers | When active search is non-FTS. |
| `rebuildFtsTableFromScratch` drop triggers `sql.dart:660` | DROP | triggers | fix619 malformed-index recovery. |
| `rebuildFtsTableFromScratch` drop table `sql.dart:665` | DROP | `DROP TABLE IF EXISTS channels_fts` | Discard corruption (code 267). |
| `rebuildFtsTableFromScratch` recreate `sql.dart:667` | CREATE | `fts5(unicode61, prefix='2 3')` byte-identical to mig | Recovery. |
| `rebuildFtsTableFromScratch` repopulate `sql.dart:676` | INSERT | `SELECT id,name FROM channels` | Full re-index. |
| `rebuildFtsTableFromScratch` recreate triggers `sql.dart:681` | CREATE | `channels_ai/ad/au` | Consistent end state. |
| `ensureFtsHealthy` `sql.dart:719` | INSERT | `channels_fts(channels_fts) VALUES('integrity-check')` | fix620 pre-flight; code-267 → rebuild. |

---

## 3. Cross-DB observations & gaps

### Unindexed / partially-indexed hot queries

- **`EpgService.isStale`** (`epg_service.dart:60`) — `WHERE start_utc<=? AND stop_utc>?` with **no `source_id`/`epg_channel_id`**. None of the `programmes` indexes lead with a time column, so this is a **scan / weak partial range** on a ~1M-row table. Runs on the stale-check path (potentially at startup / periodically). **Watch:** a `(stop_utc)` or `(start_utc)` index would help, but weigh against write cost on bulk EPG inserts. Currently the deliberate no-extra-index trade-off.
- **`getDisabledGroupIds`** (`sql.dart:1341`) and the `COALESCE(enabled,1)` / `COALESCE(favorite,0)` predicates in `wipeSource`/`getGroupsCurated`/`searchGroup` — the `COALESCE(...)` expression is **not** index-usable, so `enabled`/`favorite` filtering always falls to a residual scan of the (per-source) row set. `groups` is small per source, so acceptable, but the ORDER BY in `searchGroup` (`COALESCE(favorite) DESC, COALESCE(enabled) DESC, name COLLATE NOCASE`) forces a **temp B-tree sort** every Categories page — the one place `index_group_name` cannot help because of the COLLATE NOCASE + leading COALESCE tiers.
- **`getLatestEpgRefresh`** (`sql.dart:3010`) `MAX(last_refreshed_utc)` — full scan, but `epg_refresh_log` holds one row per source (tiny). Not a concern.

### Indexes with no query using them (dead weight)

- **`index_source_enabled`** (`sources.enabled`) — only `getEnabledSourcesMinimal` (`sql.dart:1975`) filters on `enabled`, and with typically a handful of sources the planner will usually table-scan regardless. Low value; not harmful. No other selective consumer found.
- **`index_group_name`** (`groups.name`) — no live query filters on bare `name` alone; name lookups always come with `source_id` (served by `index_group_unique` prefix) and the ORDER BY uses COLLATE NOCASE (index is BINARY collation → unusable for the sort). Effectively unused by current SQL. Candidate for review, though cheap to keep.
- `programmes` triple-index set is well-matched: `idx_programs_channel_time` serves all per-channel reads; `idx_programs_time_range` serves per-source deletes/GC; `idx_programs_unique` is both the upsert conflict target and a `source_id`-leading fallback. No dead index on `programmes`.

### FTS maintenance patterns (two deliberately different designs)

- **`channels_fts`** — trigger-**driven** (3 sync triggers), because channel names change incrementally. Triggers are byte-reconciled at boot (`reconcileFtsTriggers`) and **suspended** around bulk refresh (`withSuspendedFtsTriggers`) with targeted per-source delete/reinsert (fix514). Malformed-index self-healing via `integrity-check` → `rebuildFtsTableFromScratch` (fix619/620). Tokenizer moved trigram → unicode61 prefix (fix519) to make the large-source global rebuild cheap.
- **`programmes_fts`** — trigger-**free** by design: programmes change only during a batch refresh, so the index is rebuilt once afterward (`rebuildProgrammesFts`, fix502) and self-healed at open when `count(fts) != count(programmes)` (fix593). Still trigram (title search benefits from substring matching).

### Correctness caveats to watch

- **Stale EXPLAIN QUERY PLAN probes** (`sql.dart:140` and `:147`, fix222): both log-only probes drifted from the live `updateGroups()` — the group_id probe uses the **old correlated-subquery** form vs the live set-based `UPDATE…FROM groups` (`sql.dart:825`), and the rebuild probe's `GROUP BY group_name` omits `media_type` vs the live `GROUP BY group_name, media_type` (`sql.dart:796`). The plans they log **do not reflect the statements the refresh actually runs**. Diagnostic only — no functional impact, but misleading if read as ground truth.
- **Cross-file referential integrity** is entirely app-layer: `programmes` / `epg_refresh_log` `source_id` have no enforced FK to `db.sqlite sources(id)`. Removal of a source must call `Sql.deleteEpgForSource` (from `Sql.deleteSource`) — if that call path is ever skipped, EPG rows orphan silently.
- **fix625 write-retry** (`_epgWriteWithRetry`, `sql.dart:2604`) wraps all `epg.sqlite` **writers** (`insertProgramsBatch`, `deleteEpgForSource`, `deleteStalePrograms`, `rebuildProgrammesFts`, `upsertEpgRefreshLog`, TRUNCATE checkpoint) against cross-isolate `SQLITE_BUSY` (code 5). **Reads are not wrapped** — a read racing a writer isolate can still surface a transient busy error.

### Channels-table follow-ups (tracked in the other doc)

Captured in `docs/CHANNELS_SQL_INDEX_MAP.md`, not here: 3 permanently dropped dead indexes (`index_channels_browse_order`, `index_channel_favorite`, `index_channel_media_type`, mig36); fix537/mig39 + `runPendingIndexMaintenance` rebuilding 7 browse indexes without `cat_enabled` and dropping 5 never-selected ones; and the requirement that the browse-tier `CASE` expression stay byte-identical to `BrowseOrder` (guarded by `test/browse_order_test.dart`). The `channels`-side companion writes noted inline above (`cat_enabled` / `group_id` updates driven from `updateGroups`) are analyzed there.