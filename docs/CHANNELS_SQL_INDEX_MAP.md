# free4me-iptv `channels` Table — Index / SQL Cross-Reference

**Sources:** `/Users/rich.kalsky/git/free4me-iptv/lib/backend/db_factory.dart` (migrations 1–40, index DDL), `/Users/rich.kalsky/git/free4me-iptv/lib/backend/sql.dart` (index-management machinery + all channels SQL builders), `lib/backend/timed_db.dart`, `lib/backend/search_perf_test.dart`, plus observed on-device `fix418 PLAN:` logs (`pvt_2026-07-01T22-51.log`, `onn_refresh2.log`, `onn_epg_refresh.log`, `onn_rematch*.log`).

**The 6-tier tier CASE** (referenced below as `<tier>`) — `sql.dart:1614` `_t6`, byte-identical to `BrowseOrder.tier` and every migration's inline expression:

```
CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
     WHEN COALESCE(favorite,0)=1 THEN 1
     WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
     WHEN last_watched IS NOT NULL THEN 3
     WHEN COALESCE(stream_validated,0)=1 THEN 4
     ELSE 5 END
```

---

## 1. Index inventory

Lifecycle legend: **canon** = in `_canonicalChannelIndexes` (sql.dart:1630), self-healed at startup by `ensureBrowseIndexesPresent()` (fix628); **refresh:drop/recreate** = dropped by `withDroppedBrowseIndexes` (sql.dart:480) during bulk refresh and recreated verbatim in `finally`; **refresh:kept** = in `_keepIndexesDuringRefresh` (sql.dart:465); **unique-survives** = UNIQUE, never dropped by refresh (drop query excludes `UPPER(sql) LIKE 'CREATE UNIQUE%'`); **dead** = permanently dropped; **fix537-rebuilt** = rebuilt without `cat_enabled` by `runPendingIndexMaintenance` (sql.dart:1480).

### 1a. Live browse-tier partial indexes (all self-healed, dropped/recreated per refresh)

| Index | Columns | Partial WHERE (current / post-fix537) | Lifecycle | Serves |
|---|---|---|---|---|
| `idx_channels_browse_tier` | `source_id, <tier>, name COLLATE NOCASE` | `url IS NOT NULL` (mig 27, no series filter) | canon; refresh:drop/recreate | Per-source alpha/tier ORDER BY, mixed-media "All" browse. Structurally matches `BrowseOrder.orderBy('alpha')`. |
| `idx_channels_browse_enabled` | `source_id, <tier>, name COLLATE NOCASE` | `url IS NOT NULL AND series_id IS NULL` (orig mig 29 also `AND cat_enabled=1`) | canon; fix537-rebuilt; refresh:drop/recreate | Per-source enabled-category alpha browse; `cat_enabled` now applied as residual. |
| `idx_channels_browse_mt` | `media_type, <tier>, name COLLATE NOCASE` | `url IS NOT NULL AND series_id IS NULL` (orig mig 30 also `AND cat_enabled=1`) | canon; fix537-rebuilt; refresh:drop/recreate | Single-media-type alpha browse across all sources, no temp B-tree (media_type pinned). |
| `idx_channels_browse_mt_safe` | `media_type, <tier>, name COLLATE NOCASE` | `url IS NOT NULL AND series_id IS NULL AND COALESCE(is_adult,0)=0` (orig mig 37 also `AND cat_enabled=1`) | canon; fix537-rebuilt; refresh:drop/recreate | Safe-Mode-ON single-media-type alpha browse; ANALYZE (mig 38/fix530) biases planner toward it. |
| `idx_browse_prov` | `media_type, favFirst-CASE, favValidated-CASE, provider_order, name COLLATE NOCASE` | `url IS NOT NULL AND series_id IS NULL` (orig mig 33 also `AND cat_enabled=1`) | canon; fix537-rebuilt; refresh:drop/recreate | `BrowseOrder.orderBy('provider')` per media_type. |
| `idx_browse_prov_safe` | `media_type, favFirst-CASE, favValidated-CASE, provider_order, name COLLATE NOCASE` | `... AND COALESCE(is_adult,0)=0` (orig mig 37 also `AND cat_enabled=1`) | canon; fix537-rebuilt; refresh:drop/recreate | Safe-Mode-ON provider-sort browse. |
| `idx_browse_src_mt` | `source_id, media_type, <tier>, name COLLATE NOCASE` | `url IS NOT NULL AND series_id IS NULL` (orig mig 34/37 also `AND cat_enabled=1`) | canon; fix537-rebuilt; refresh:drop/recreate | Single-source single-media-type alpha browse; hinted `INDEXED BY` (fix419/fix526). Also mixed-union inner seeks. |
| `idx_browse_src_mt_safe` | `source_id, media_type, <tier>, name COLLATE NOCASE` | `... AND COALESCE(is_adult,0)=0` (orig mig 37 also `AND cat_enabled=1`) | canon; fix537-rebuilt; refresh:drop/recreate | Safe-Mode-ON source+media_type composite; hinted `INDEXED BY` in mixed-union. |
| `idx_browse_src_grp` | `source_id, group_id, <tier>, name COLLATE NOCASE` | `url IS NOT NULL AND series_id IS NULL` (**no** cat_enabled — category view ignores the enabled toggle) | canon; refresh:drop/recreate (not in fix537 rebuilt list — already cat_enabled-free) | Single-source single-category (group) alpha browse; hinted `INDEXED BY` (fix526/fix627). |

### 1b. Live non-browse indexes

| Index | Columns | Partial WHERE | Lifecycle | Serves |
|---|---|---|---|---|
| `index_channel_source_id` | `source_id` | (full) | **refresh:kept** (ONLY channels index kept); not canon | Refresh per-source statements (restorePreserve UPDATE, targeted SELECT); planner fallback when browse indexes absent (fix520). |
| `index_channel_group_id` | `group_id` | (full) | canon; refresh:drop/recreate | group_id lookups / group joins. |
| `index_channel_series_id` | `series_id` | `series_id IS NOT NULL` (partial as of mig 32/fix392; was full in mig 1) | canon; refresh:drop/recreate | Series drilldown (`series_id = ?`). Made partial so it stops shadowing browse-tier indexes on `series_id IS NULL` (fix392). |
| `index_channels_stream_id` | `stream_id` | (full) | canon; refresh:drop/recreate | stream_id lookups. |
| `index_channels_group_name` | `group_name` | (full) | canon; refresh:drop/recreate | group_name lookups. |
| `index_channel_last_watched` | `last_watched` | (full) | canon; refresh:drop/recreate | History / last_watched ordering. |
| `idx_channels_epg_id` | `epg_channel_id` | (full) | canon; refresh:drop/recreate | EPG channel-id matching / programme-guide joins. |
| `index_channel_name_source` | `name, source_id` | (full) | canon; refresh:drop/recreate | restorePreserve join on `(name, source_id)`; replaced dropped `channels_unique` (~134s regression fix). |
| `idx_epg_unmatched` | `source_id` | `media_type=0 AND epg_manual_override IS NULL AND epg_channel_id IS NULL` | canon; refresh:drop/recreate | EPG auto-match scan `getChannelsNeedingEpgMatch` / `getUnmatchedLiveChannels`. |
| `idx_channel_src_media_url` | `source_id, media_type, url` | (full) | canon; refresh:drop/recreate | No-query / history seek by source + media type on large catalogs. |
| `idx_channel_lastwatched_media` | `last_watched, media_type` | `last_watched IS NOT NULL` | canon; refresh:drop/recreate | History view ordered by last_watched, filtered by media_type. |

### 1c. UNIQUE indexes (survive refresh; not canon)

| Index | Columns | Partial WHERE | Lifecycle | Serves |
|---|---|---|---|---|
| `channels_unique_stream` | `source_id, media_type, stream_id` | `stream_id IS NOT NULL AND stream_id >= 0` — UNIQUE | unique-survives (mig 15/fix178) | Live/VOD upsert conflict key (`insertChannel`/`insertChannelsBulk`). |
| `channels_unique_series` | `source_id, series_id, url` | `series_id IS NOT NULL` — UNIQUE (re-keyed w/ url in mig 28/fix353) | unique-survives | Series/episode upsert conflict key. |

### 1d. Dead / removed indexes

| Index | Columns | Removed by | Was for |
|---|---|---|---|
| `idx_browse_cat` | `media_type, favFirst, favValidated, group_name NOCASE, provider_order, name NOCASE` | fix537 `dead` (never beat `idx_channels_browse_mt_safe`) | category-sort browse |
| `idx_browse_cat_safe` | (same + `COALESCE(is_adult,0)=0`) | fix537 `dead` | Safe-ON category-sort browse |
| `index_channel_name` | `name` | fix537 `dead` (covered by `index_channel_name_source`) | name lookup |
| `index_channel_favorite` | `favorite` | mig 36/fix523 DROP IF EXISTS | single-column favorite (never a leading equality) |
| `index_channel_media_type` | `media_type` | mig 36/fix523 DROP IF EXISTS | single-column media_type (cardinality 3, non-selective) |
| `index_channels_browse_order` | `source_id, media_type, favorite DESC, stream_validated DESC, last_watched DESC, name NOCASE` | mig 36/fix523 DROP IF EXISTS | original DESC-shape browse; can't serve tier-CASE ORDER BY |
| `index_channel_divider` | `source_id, is_divider` | fix537 `dead` | hide_dividers toggle (unused) |
| `index_channel_adult` | `source_id, is_adult` | fix537 `dead` | unified safe-mode filter (superseded by `*_safe`) |
| `channels_unique` | `name, source_id` — UNIQUE | dropped mig 14/15 (fix174/178) | original name uniqueness (collapsed dupes) |

### 1e. FTS shadow index

| Object | Definition | Lifecycle | Serves |
|---|---|---|---|
| `channels_fts` | `fts5(name, content='channels', content_rowid='id', tokenize='unicode61', prefix='2 3')` (mig 35/fix519; was trigram mig 4) | external-content FTS5; triggers suspended during batch refresh, reindexed/rebuilt once at end (fix614/fix621); self-heals via integrity-check + `rebuildFtsTableFromScratch` (fix619/620) | Channel-name full-text search; `MATCH` joins `channels_fts.rowid = channels.id`. Sync triggers `channels_ai`/`channels_ad`/`channels_au` (AFTER UPDATE OF name). |

---

## 2. SQL ↔ index cross-reference

**Shared clause assembly** (sql.dart notes): every browse/search branch base WHERE = `media_type IN (?..)`, `source_id IN/=`, `url IS NOT NULL` (+ FTS `channels_fts MATCH`). Then appended in order: view filter (`favorite=1` favorites / `last_watched IS NOT NULL` history), `safeModeClause` → `AND COALESCE(c.is_adult,0)=0` (sql.dart:3100), `VisibilityClause.build` (visibility_clause.dart:28) → `AND c.series_id=?` OR `AND c.series_id IS NULL` (+ `AND c.group_id=?`) plus `AND c.cat_enabled=1` when `groupId` is null. ORDER BY from `BrowseOrder.orderBy(mode)` (browse_order.dart:50): `alpha` → `<tier> ASC, c.name NOCASE ASC`; `provider`/`category` → favFirst/valFloat/…; `null` (mixed) → legacy per-row correlated subquery (not index-served). Every branch ends `LIMIT ?, ?`.

### Access pattern: Browse — grouped (single category, `group_id=?`)

| Item | Value |
|---|---|
| Builder | `Sql.search` no-query browse, sql.dart:1113; hint gate `Sql.search no-query src_grp hint gate`, sql.dart:1105 |
| Op / WHERE | SELECT; `media_type IN, source_id IN, url IS NOT NULL [+ is_adult=0], series_id IS NULL, group_id=?` |
| ORDER BY | `<tier>, c.name NOCASE` (alpha) |
| Forced INDEXED BY | `idx_browse_src_grp` — applied only when viewType≠fav/history, seriesId null, groupId≠null, and `_indexExists('idx_browse_src_grp')` true (fix627, sql.dart:1105) |
| **Planner-used index** | **Observed:** `index_channel_source_id (source_id=?)` + **USE TEMP B-TREE FOR ORDER BY** — `idx_browse_src_grp` NOT used, 7.5–15s (`pvt_…22-51.log` 2413-2420 @2026-07-01 18:47:52). **Intended (healthy):** `idx_browse_src_grp` served fully (columns `source_id, group_id, <tier>, name NOCASE` cover both the equality and the ORDER BY). |
| TEMP B-TREE? | **Observed: YES** (index dropped/absent). **Intended: NO** (hint covers it). |

### Access pattern: Browse — ungrouped single-source (`cat_enabled=1`)

| Item | Value |
|---|---|
| Builder | `Sql.search` no-query browse, sql.dart:1113; hint gate `Sql.search no-query src_mt hint gate`, sql.dart:1073 |
| Op / WHERE | SELECT; `media_type IN, source_id IN, url IS NOT NULL [+ is_adult=0], series_id IS NULL, cat_enabled=1` |
| ORDER BY | `<tier>, c.name NOCASE` (alpha) |
| Forced INDEXED BY | `idx_browse_src_mt` — applied only when seriesId null, groupId null, `sourceIds.length==1`, `mediaTypes.length==1`, `browseMode=='alpha'`, `_indexExists('idx_browse_src_mt')` true (fix419/fix526, sql.dart:1073) |
| **Planner-used index** | **Observed:** `index_channel_source_id (source_id=?)` + **USE TEMP B-TREE FOR ORDER BY** — purpose-built tier composites NOT chosen; 12–14s, once 77s (`pvt_…22-51.log` 1514-1516 @2026-06-30 23:51:22, branch=no-query rows=36 sql=77250ms @23:52:27; `onn_refresh2.log` 31-34). **Intended:** `idx_browse_src_mt` fully served — `cat_enabled=1` is a residual post-fix537 (partial WHERE dropped it), the rest is index-served. |
| TEMP B-TREE? | **Observed: YES.** **Intended: NO.** |
| Note | If `sourceIds.length>1` (uniform mode, alpha), no `src_mt` hint fires; the natural pick would be `idx_channels_browse_mt` (media_type-led). *(inferred)* |

### Access pattern: Browse — multi-source mixed sort modes (`_browseMixedUnion`)

| Item | Value |
|---|---|
| Builder | `Sql._browseMixedUnion` per-source subquery, sql.dart:3270 (fix393) |
| Op / WHERE | SELECT per source: `media_type IN, source_id=?, url IS NOT NULL [+ is_adult=0], series_id IS NULL [+ group_id=?], cat_enabled=1 when groupId null`, UNION ALL |
| ORDER BY | inner per-source `BrowseOrder.orderBy(modes[s] ?? 'alpha')` + `LIMIT offset+pageSize`; outer `BrowseOrder.orderBy(null)` (legacy mixed correlated) + `LIMIT ?,?` |
| Forced INDEXED BY | `idx_browse_src_grp` (when groupId set) OR `idx_browse_src_mt_safe` (when safeMode ON + ungrouped) — both `_indexExists`-gated |
| **Planner-used index** | *(inferred)* per-source inner subqueries served by `idx_browse_src_mt_safe` / `idx_browse_src_grp` when hinted+present; else `index_channel_source_id` + temp B-tree per source. No direct device plan for this shape in the datasets. Outer re-sort over the tiny union always uses a temp B-tree (legacy correlated ORDER BY, not index-served — by design). |
| TEMP B-TREE? | Inner: NO when hint present *(inferred)*. Outer: YES by design (small N). |

### Access pattern: FTS text search

| Item | Value |
|---|---|
| Builder | `Sql.search` FTS branch, sql.dart:1022 |
| Op / WHERE | SELECT; `INNER JOIN channels_fts` on rowid; `channels_fts MATCH ?`, `media_type IN, source_id IN, url IS NOT NULL [+ view/safe/visibility clauses]` |
| ORDER BY | favorites/history overrides else `BrowseOrder.orderBy(_uniformSortMode)`; then `LIMIT ?,?` |
| Forced INDEXED BY | none (FTS virtual table drives the join) |
| **Planner-used index** | **Observed:** `channels_fts` virtual table (FTS5); fast (sql=146ms, rows=1000), never crossed slow threshold → no PLAN emitted (`pvt_…22-51.log` 1816-1819 @2026-07-01 00:07:40). The channels side is joined by rowid (PK). |
| TEMP B-TREE? | Not observed for the MATCH itself. A temp B-tree *may* appear for the ORDER BY if `_uniformSortMode` is null (mixed correlated) *(inferred)*; not seen in logs. |

### Access pattern: `likeSubstring` search

| Item | Value |
|---|---|
| Builder | `Sql._searchLike`, sql.dart:3320 |
| Op / WHERE | SELECT; `(c.name LIKE ? AND …) per term`, `media_type IN, source_id IN, url IS NOT NULL [+ view/safe/visibility]` |
| ORDER BY | favorites legacy / history `last_watched DESC` / else `BrowseOrder.orderBy(_uniformSortMode)`; `LIMIT ?,?` |
| Forced INDEXED BY | none |
| **Planner-used index** | *(inferred)* full-table scan — `name LIKE '%term%'` (leading wildcard) is non-sargable; planner picks a `source_id`/`media_type` composite to narrow rows then residual-LIKE-scans + temp B-tree for the tier ORDER BY. No device plan (this method is off by default). |
| TEMP B-TREE? | YES *(inferred)* for the tier ORDER BY. |

### Access pattern: `inMemory` search (hydration)

| Item | Value |
|---|---|
| Builder | `Sql._searchInMemory` hydration, sql.dart:3155 |
| Op / WHERE | SELECT; `c.id IN (?..)` — ids pre-filtered/paginated by `ChannelSearchCache` |
| ORDER BY | none in SQL (order rebuilt in Dart from cache's ordered ids) |
| Forced INDEXED BY | none |
| **Planner-used index** | *(inferred)* INTEGER PRIMARY KEY (rowid) point lookups per id — optimal, no browse index involved. |
| TEMP B-TREE? | NO. |
| Cache feed | `Sql.getAllChannelNamesForCache`, sql.dart:1269 — `SELECT … WHERE c.url IS NOT NULL LEFT JOIN sources`; no ORDER BY, no hint → *(inferred)* full scan filtered by `url IS NOT NULL` (intended bulk load). |

### Access pattern: warm-up (delegates to browse)

| Item | Value |
|---|---|
| Builder | `Sql.warmBrowseCache`, sql.dart:1787 |
| Behavior | No own SQL — calls `search(all sources, [livestream], viewType=all, page 1)` → emits the no-query browse SELECT (1113). Inherits its index behavior (observed as the 77s / 12–14s slow warm-up above). |

### ORDER-BY / hint helper reads (not channels)

| Builder | File:line | Reads | Purpose |
|---|---|---|---|
| `Sql._uniformSortMode` | sql.dart:3187 | `sources` | Resolves single shared sort mode (null if mixed) → picks index-served vs correlated ORDER BY. |
| `Sql._sourceModes` | sql.dart:3202 | `sources` | Per-source mode map; gates mixed-union path. |
| `Sql._indexExists` | sql.dart:473 | `sqlite_master` (`type='index' AND name=?`) | fix526 gate for every forced `INDEXED BY` so a missing/mid-rebuild index never crashes browse. |

### Access pattern: EPG-match reads

| Builder | File:line | WHERE | Intended index | Observed plan |
|---|---|---|---|---|
| `Sql.getChannelsNeedingEpgMatch` | sql.dart:3034 | `source_id=? AND media_type=0 AND epg_manual_override IS NULL AND epg_channel_id IS NULL` | `idx_epg_unmatched` (partial exactly matches these predicates) | **UNSTABLE / wrong index.** Variant A: `idx_channels_epg_id (epg_channel_id=?)`, 13–21s (`pvt_…22-51.log` 600-601 @2026-06-30 00:19:29, 621-622, 639-640, 660-661). Variant B: `index_channel_source_id (source_id=?)`, 2.4–7.2s (`onn_epg_refresh.log` 33-34, 54-55, 72-73, 93-94). `idx_epg_unmatched` NOT chosen in either. |
| `Sql.getChannelsForEpgMatching` | sql.dart:3020 | `source_id=? AND media_type=0` (rematch-all) | `index_channel_source_id` (appropriate) | `SEARCH channels USING INDEX index_channel_source_id (source_id=?)`; 2.6–5.5s, row-count driven, no temp B-tree, no defect (`onn_rematch.log` 27-28; `onn_rematch2.log` 124-125, 146-147, 168-169). |
| `Sql.getLiveChannelsForMapping` | sql.dart:3048 | `source_id=? AND media_type=0`, ORDER BY `epg_channel_id IS NOT NULL ASC, name ASC` | `index_channel_source_id` seek + temp B-tree for the ORDER BY *(inferred)* | not in logs. |
| `Sql.getLiveChannelsByEpg` | sql.dart:2914 | `media_type=0 AND url IS NOT NULL AND source_id IN(…) AND epg_channel_id IN(…) [+ is_adult=0]` | `idx_channels_epg_id` on `epg_channel_id IN(…)` would be ideal | **Observed:** `index_channel_source_id (source_id=?)`, epg_channel_id applied as residual, 3745ms (the epgCh=3748ms leg of a 4124ms search) (`pvt_…22-51.log` 1817-1819 @2026-07-01 00:07:44). `idx_channels_epg_id` NOT chosen. |
| `Sql.setChannelEpgIds` | sql.dart:2533 | UPDATE `id IN (SELECT id FROM _data)` (CTE, 200/chunk) | PK | *(inferred)* PK-driven. |
| `Sql.setManualEpgOverride` | sql.dart:3087 | UPDATE `id=?` | PK | *(inferred)* PK point write. |

### Access pattern: Refresh writes (bulk import + group/cat backfill)

| Builder | File:line | Op / WHERE | Intended index | Observed plan |
|---|---|---|---|---|
| `Sql.insertChannel` | sql.dart:158 | UPSERT, ON CONFLICT (stream/series unique) | `channels_unique_stream` / `channels_unique_series` (conflict targets) | *(inferred)* — conflict resolved via the UNIQUE indexes (which survive refresh). |
| `Sql.insertChannelsBulk` | sql.dart:756 | UPSERT N-row VALUES (≤1000 rows / 13000 params), same ON CONFLICT | same UNIQUE indexes | *(inferred)*. |
| `Sql.updateGroups` NULL reset | sql.dart:822 | UPDATE `source_id=?` | `index_channel_source_id` | *(inferred)* source_id seek. |
| `Sql.updateGroups` group_id join | sql.dart:825 | UPDATE …FROM groups, `channels.source_id=?` | channels `index_channel_source_id`; groups `index_group_unique` | **Observed healthy:** `SEARCH channels USING INDEX index_channel_source_id` \| `BLOOM FILTER ON g` \| `SEARCH g USING INDEX index_group_unique`; 1.6–5.6s row-count driven (`pvt_…22-51.log` 60-61, 103-104, 189-190). |
| `Sql.updateGroups` cat_enabled join | sql.dart:840 | UPDATE …FROM groups, `channels.source_id=?` | channels `index_channel_source_id`; groups PK | **Observed healthy:** `SEARCH channels USING INDEX index_channel_source_id` \| `SEARCH g USING INTEGER PRIMARY KEY`; 1.2–2.8s (`pvt_…22-51.log` 62-63, 105-106, 191-192). |
| `Sql.updateGroups` cat_enabled default-1 | sql.dart:847 | UPDATE `source_id=? AND group_id IS NULL` | `index_channel_source_id` | *(inferred)*. |
| groups INSERT…SELECT…GROUP BY (rebuild groups from channels) | (refresh; probe at sql.dart:147) | INSERT INTO groups SELECT …FROM channels WHERE `source_id=?` GROUP BY group_name, media_type | wants `(source_id, group_name, media_type)` | **Observed gap:** `SEARCH channels USING INDEX index_channel_source_id` \| **USE TEMP B-TREE FOR GROUP BY**; 1.1–2.8s — no covering index feeds the grouping in order (`pvt_…22-51.log` 56-57, 99-100, 185-186). |
| `Sql.setGroupEnabled` sync | sql.dart:1327 | UPDATE `group_id=?` | `index_channel_group_id` | *(inferred)* group_id seek. |
| `Sql.setAllGroupsEnabled` sync | sql.dart:1369 | UPDATE `group_id IN (subquery)` | `index_channel_group_id` per id *(inferred)* | not in logs. |
| `Sql.setAllGroupsEnabledForSearch` | sql.dart:1423 | UPDATE `group_id IN (subquery)` | `index_channel_group_id` *(inferred)* | not in logs. |
| `Sql.applyGroupState` | sql.dart:2180 | UPDATE `source_id=? AND group_id=(subquery)` | `index_channel_source_id` + `index_channel_group_id` *(inferred)* | not in logs. |
| `Sql.wipeSource` COUNT | sql.dart:2042 | SELECT COUNT(*) WHERE `source_id=?` | `index_channel_source_id` (covering) *(inferred)* | not in logs. |
| `Sql.wipeSource` full delete | sql.dart:2071 | DELETE `source_id=?` | `index_channel_source_id` | *(inferred)* source_id seek (kept during refresh precisely for this). |
| `Sql.wipeSource` keepMediaTypes delete | sql.dart:2076 | DELETE `source_id=? AND media_type NOT IN (…)` | `index_channel_source_id` + residual media_type | *(inferred)*. |
| `Sql.deleteSource` | sql.dart:2033 | DELETE `source_id=?` | `index_channel_source_id` | *(inferred)*. |
| `Sql.runPendingDividerCleanup` | sql.dart:1470 | DELETE `COALESCE(is_divider,0)=1` | none (no is_divider index — dropped fix537) | *(inferred)* full scan; one-time deferred purge. |

### Access pattern: Preserve (restore user attributes across wipe+reimport)

| Builder | File:line | Op / WHERE | Intended index | Observed plan |
|---|---|---|---|---|
| `Sql.getChannelsPreserve` | sql.dart:2289 | SELECT `source_id=? AND (favorite=1 OR last_watched IS NOT NULL OR epg_channel_id IS NOT NULL OR epg_manual_override IS NOT NULL OR stream_validated IS NOT NULL)` | `index_channel_source_id` + residual OR-set | *(inferred)* source_id seek then residual. |
| `Sql.restorePreserve` temp INSERT | sql.dart:2385 | INSERT INTO `_preserve_restore` (chunked) | n/a (temp staging) | — |
| `Sql.restorePreserve` UPDATE…FROM | sql.dart:2401 | UPDATE …FROM `_preserve_restore p` ON `p.name=channels.name AND p.source_id=channels.source_id` | `index_channel_name_source` (planner picks it, no forced hint) | **Observed:** `SCAN channels` (driving) \| `SEARCH p USING INDEX _preserve_restore_idx (name=? AND source_id=?)`; **full SCAN of channels**, slowest single stmt 10.6/11.7s (`pvt_…22-51.log` 108-109, 149-150; also `onn_refresh2.log` ×4). Note: with the temp table as inner and channels driving, `index_channel_name_source` is not exercised on the channels side; the whole source's rows are scanned. |
| TEMP B-TREE? | NO (SCAN, not sort). |

### Access pattern: FTS maintenance

| Builder | File:line | Op / WHERE | Observed plan |
|---|---|---|---|
| `withSuspendedFtsTriggers` targeted COUNT | sql.dart:327 | SELECT COUNT(*) src / total | *(inferred)* source_id covering + full count. |
| `withSuspendedFtsTriggers` targeted id-list | sql.dart:341 | SELECT `source_id=?` | **Observed:** `SEARCH channels USING COVERING INDEX index_channel_source_id (source_id=?)` — optimal, 1.08s (`pvt_…22-51.log` 280-281 @2026-06-30 00:06:37). Same shape as `SELECT id FROM channels WHERE source_id=?`. |
| `withSuspendedFtsTriggers` FTS delete | sql.dart:349 | DELETE FROM `channels_fts` WHERE rowid IN (chunks) | **Observed:** `SCAN channels_fts VIRTUAL TABLE INDEX 0:=` — expected FTS5 path; 1–6.2s from large IN-list, not a defect (357 such lines; `pvt_…22-51.log` 282-283 @00:06:43 block). |
| `withSuspendedFtsTriggers` FTS insert | sql.dart:373 | INSERT INTO channels_fts SELECT id,name FROM channels WHERE `source_id=?` | *(inferred)* source_id seek. |
| `reconcileFtsTriggers` rebuild | sql.dart:622 | INSERT INTO channels_fts('rebuild') | FTS5 command. |
| `rebuildFtsTableFromScratch` repopulate | sql.dart:675 | INSERT INTO channels_fts SELECT id,name FROM channels | **Observed:** `SCAN channels` — correct for whole-table repopulate; 41.6s / ~1.16M rows (`onn_refresh2.log` 333-334 @2026-07-01 00:03:30). |
| `ensureFtsHealthy` integrity-check | sql.dart:719 | INSERT INTO channels_fts('integrity-check') | FTS5 command; on code-267 triggers rebuild. |
| triggers `channels_ai`/`channels_ad`/`channels_au` | sql.dart:624/627/631 | per-row FTS sync | dropped during bulk refresh; recreated after. |

### Point reads / toggles

| Builder | File:line | WHERE | Index |
|---|---|---|---|
| `Sql.getChannelById` | sql.dart:1308 | `id=? LIMIT 1` | PK point read. |
| `Sql.favoriteChannel` | sql.dart:2000 | UPDATE `id=?` | PK. |
| `Sql.setStreamValidated` | sql.dart:2432 | UPDATE `id=?` | PK. |
| `Sql.addToHistory` set | sql.dart:2264 | UPDATE `id=?` | PK. |
| `Sql.deleteHistoryEntry` | sql.dart:2244 | UPDATE `id=?` | PK. |
| `Sql.addToHistory` prune | sql.dart:2268 | UPDATE `last_watched IS NOT NULL AND id NOT IN (SELECT … ORDER BY last_watched DESC LIMIT 36)` | inner ORDER BY served by `index_channel_last_watched` *(inferred)*; outer full-ish scan of history rows. |
| `Sql.clearHistory` | sql.dart:2255 | UPDATE `last_watched IS NOT NULL` (unscoped) | *(inferred)* `index_channel_last_watched` filter or scan. |
| `Sql.clearAllStreamValidated` | sql.dart:2448 | UPDATE (unscoped) | full scan (intended). |
| `Sql.getMoviePositionsForExport` | sql.dart:2193 | SELECT `c.source_id=? AND c.url IS NOT NULL AND mp.position>0` (mp JOIN c on id) | *(inferred)* mp PK join to channels PK. |
| `Sql.applyMoviePosition` | sql.dart:2214 | INSERT INTO movie_positions SELECT id FROM channels WHERE `source_id=? AND url=?` | *(inferred)* `index_channel_source_id` + residual url; or `idx_channel_src_media_url` (`source_id, media_type, url`) — but no media_type predicate, so it degrades to the source_id prefix. |

### Diagnostic-only channels reads (outside sql.dart, gated by `AppLog.enabled`)

| Builder | File:line | WHERE / GROUP BY | Index *(inferred)* |
|---|---|---|---|
| `TimedDb._logBrowseStats` per-mediatype | timed_db.dart:75 | GROUP BY source_id, media_type | full scan + temp B-tree for GROUP BY. |
| `TimedDb._logBrowseStats` category counts | timed_db.dart:89 | GROUP BY source_id | full scan. |
| `TimedDb._logBrowseStats` biggest categories | timed_db.dart:97 | GROUP BY source_id, group_id ORDER BY COUNT(*) DESC LIMIT 5 | full scan + temp B-tree. |
| `TimedDb._logBrowseStats` orphan gid | timed_db.dart:127 | LEFT JOIN groups, GROUP BY c.source_id | full scan + join. |
| `SearchPerfTest._buildProbes` | search_perf_test.dart:210 | `name IS NOT NULL LIMIT ?` | full scan (benchmark sampler). |
| `logRefreshQueryPlans` probes | sql.dart:131 / 140 / 147 | EXPLAIN QUERY PLAN only (`__plan_probe__`) | no row mutation; logging only. |

---

## 3. Coverage gaps / risks

**A. Browse path is the worst — the tier composites are dropped mid-refresh, so browse falls to `index_channel_source_id` + TEMP B-TREE.** Both the `cat_enabled=1` ungrouped browse (sql.dart:1113) and the `group_id=?` grouped browse (sql.dart:1105) were observed using only `SEARCH … index_channel_source_id (source_id=?)` + `USE TEMP B-TREE FOR ORDER BY` — 12–14s, once **77s** (`pvt_…22-51.log` 1514-1516, branch=no-query rows=36 sql=77250ms @2026-06-30 23:52:27) and 7.5–15s for the grouped variant (2413-2420 @2026-07-01 18:47:52). Root cause: `withDroppedBrowseIndexes` (sql.dart:480) physically DROPs every non-unique, non-kept channels index at refresh start and rebuilds them in `finally` (the 34 empty-PLAN `CREATE INDEX` lines, `pvt_…22-51.log` 200-273, incl. `idx_channels_browse_tier` @00:03:20 taking 19396ms). **Any browse concurrent with a refresh has no tier index at all** → temp B-tree on ~150k–450k rows/source (~1.16M total). The forced `INDEXED BY` hints (fix419/fix526/fix627) are self-defeating here: `_indexExists` (sql.dart:473) sees the index is gone mid-refresh and **withholds** the hint, so the query silently degrades instead of crashing — correct for stability, but it is exactly why the slow plans appear.

**B. EPG-unmatched select never uses its purpose-built partial index.** `getChannelsNeedingEpgMatch` (sql.dart:3034) has the exact predicate of `idx_epg_unmatched` (`media_type=0 AND epg_manual_override IS NULL AND epg_channel_id IS NULL`), yet the observed plan is **unstable**: `idx_channels_epg_id (epg_channel_id=?)` (13–21s, `pvt_…22-51.log` 600-661) or `index_channel_source_id (source_id=?)` (2.4–7.2s, `onn_epg_refresh.log` 33-94) — never `idx_epg_unmatched`. Likely stale/absent stats (the index is dropped/recreated each refresh and may not be re-`ANALYZE`d) or the partial-index-vs-`IS NULL` planner heuristic. `getLiveChannelsByEpg` (sql.dart:2914) similarly applies `epg_channel_id IN(…)` as a residual after a `source_id` seek (3.7s, `pvt_…22-51.log` 1817-1819) instead of using `idx_channels_epg_id`.

**C. Groups-rebuild GROUP BY and preserve UPDATE have no serving index.** The `INSERT INTO groups … SELECT … GROUP BY group_name, media_type` uses `index_channel_source_id` + `USE TEMP B-TREE FOR GROUP BY` (no `(source_id, group_name, media_type)` index; `pvt_…22-51.log` 56-186). `restorePreserve` (sql.dart:2401) does a **full `SCAN channels`** as the join driver (10.6–11.7s; `pvt_…22-51.log` 108-150) — `index_channel_name_source` only indexes the temp side of the join. Both are row-count-bounded rather than pathological, but they are unindexed by design.

**D. Dead-weight / write-cost indexes.** None of the 9 dead indexes (§1d) is used by any current query. Five (`idx_browse_cat`, `idx_browse_cat_safe`, `index_channel_name`, `index_channel_divider`, `index_channel_adult`) were dropped by fix537 for exactly this reason (never beat the `*_safe` / `_name_source` variants), and three (`index_channel_favorite`, `index_channel_media_type`, `index_channels_browse_order`) by mig 36/fix523. `idx_browse_cat`/`_cat_safe` are the notable "built but never selected" pair — the planner always preferred `idx_channels_browse_mt_safe` for category-sort. Every one of these was pure write-amplification (each `insertChannelsBulk` of up to 1000 rows had to maintain them) until removed. Remaining live-but-rarely-hit-in-logs: `index_channels_stream_id`, `index_channels_group_name`, `idx_channel_src_media_url`, `idx_channel_lastwatched_media` — retained as canonical; no device plan confirms usage in these datasets *(inferred: low-frequency lookup/history paths)*.

**E. Averaged-stats / skew hazard.** The device is a 2GB onn 4K Plus (`DeviceMemory totalMb=1925`) → `safeMode=true`, which appends the 8-term blocklist to every browse and forces the `*_safe` partial indexes. fix418 stats (`pvt_…` @2026-06-30 23:51:41) show `src=5 mt=1 n=286702`, per-source totals **149k–450k** — highly skewed. SQLite's `sqlite_stat1` after `ANALYZE` records only average rows-per-key; with a `source_id` cardinality of ~5 but wildly uneven partition sizes, the planner's cost estimate for a `source_id` seek is an average that badly misprices the 450k-row source. This makes the choice between `index_channel_source_id`-only and a tier composite fragile — and explains the unstable EPG-match plan (B) and why the tier composites can lose even when present.

**F. fix627 / fix628 context.** fix627 added the `idx_browse_src_grp` forced hint (sql.dart:1105) so category browse seeks straight to `(source_id, group_id)` instead of scanning the source partition + temp B-tree. fix628 introduced `_canonicalChannelIndexes` (sql.dart:1630, the 20-entry CREATE-IF-NOT-EXISTS map) + `ensureBrowseIndexesPresent()` startup self-heal: if a refresh is **killed/cancelled between DROP and the `finally` recreate**, the browse-tier indexes would be permanently missing; the self-heal replays them on next cold start. Its browse partials are the **cat_enabled-free** (post-fix537) shape. Note the self-heal does NOT cover `channels_unique_stream`/`_series` (UNIQUE, can't be lost by refresh) or `index_channel_source_id` (kept during refresh) — those are intentionally outside the canonical map. `withDroppedBrowseIndexes` also persists captured DDL to `app_meta 'pending_browse_index_ddl'` (fix628) so an interrupted refresh can still recreate them verbatim.

---

## 4. Notes

- **The observed device was mid-broken-refresh — the cross-reference above distinguishes OBSERVED (defective, indexes dropped) from INTENDED (healthy, all indexes present).** The 12–77s browse plans and the `index_channel_source_id + TEMP B-TREE` fallbacks in §2 reflect a state where `withDroppedBrowseIndexes` had dropped the tier composites and had not yet recreated them (the 34 empty-PLAN `CREATE INDEX` lines confirm rebuild was in flight). On a device at rest with the full canonical set present, `idx_browse_src_mt` / `idx_browse_src_grp` / `idx_channels_browse_mt(_safe)` serve those ORDER BYs with **no temp B-tree** — that is the intended mapping.
- Any row marked **(inferred)** is reasoned from WHERE/ORDER BY vs the index's leading columns and collation (browse composites use `name COLLATE NOCASE`, matching `BrowseOrder`'s `c.name COLLATE NOCASE`), not backed by a `fix418 PLAN:` log line. Rows citing a specific `.log` line and timestamp are ground-truth observed plans.
- Partial-WHERE caveat: for the 7 fix537-rebuilt browse indexes the **current** predicate has `cat_enabled` removed (§1a). A device that has **not** yet run `runPendingIndexMaintenance` (gated by `app_meta 'fix537_index_rebuild_done'`) still has the original `AND cat_enabled=1` predicate live — on such a device the browse's `cat_enabled=1` is served by the partial index itself rather than as a residual.
- `channels_unique`, `channels_unique_stream`, `channels_unique_series` are the only channels indexes that survive a refresh untouched (UNIQUE, excluded from the drop query by `UPPER(sql) NOT LIKE 'CREATE UNIQUE%'`); `index_channel_source_id` is the only **non-unique** channels index kept during refresh (`_keepIndexesDuringRefresh`, sql.dart:465).
- Files with **no** raw channels SQL (confirmed): `epg_service.dart` (its one query hits the EPG `programmes` table), `utils.dart`, `xtream.dart`, `m3u.dart`, `channel_search_cache.dart`, `settings_io.dart`, and all view/widget files — they all route through `Sql.*` / `ChannelSearchCache`.