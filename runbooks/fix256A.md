# fix256 — Preserve provider channel order (per-source toggle: provider order vs alphabetical)

> **Version:** build = highest fix number; patch = next available. Tag = next immutable.
> **Builds on:** current source **1.25.4+246** (migrations top at 19). Adds migration 20.
> **Bug (Z2U / barfik.org Xtream import):** the provider ships channels in a curated order using `#### SECTION ####` entries as inline headers (e.g. `#### ABC ####` immediately followed by ABC Alabama, ABC Alaska, …). After import ALL the `####` headers clustered at the TOP and the real channels sank far below. Cause: browse views sort by `name COLLATE NOCASE`, and `#` (0x23) sorts before letters/digits, so every header floats up as a block. The provider's `num` order was never captured, so there was nothing else to sort by.
> **Fix:** capture the provider's order (`num`) at import into a new `channels.provider_order` column, and add a per-source `sort_mode` ('provider' | 'alpha', default alpha) chosen via a toggle in the source edit dialog. Browse views (Live / Movies / Series / All) sort by provider order when the source is in 'provider' mode, else alphabetical — per source, so existing sources are unaffected.

## Verified behavior (real sqlite_async, seeded with #### headers + provider_order)
- `alpha` (default): reproduces the bug — `#### ABC ####`, `#### COSMOTE ####`, `#### CW ####` all on top, channels below.
- `provider`: restores intended interleave — `#### ABC ####` → ABC Alabama → ABC Alaska → `#### CW ####` → CW Florida → CW Georgia → `#### COSMOTE ####` → Cosmote Sport 1.

## Layers (all compiled, full app clean — 2 tolerated INFOs)
1. **Migration 20** — `channels.provider_order INTEGER` + `sources.sort_mode TEXT`.
2. **Parser** — `XtreamStream` reads `num` (as `providerNum`; `num` collides with the Dart type).
3. **Model** — `Channel.providerOrder`, `Source.sortMode`.
4. **Import** — `xtreamToChannel` sets `providerOrder`; bulk insert writes `provider_order`.
5. **Read** — `rowToChannel` maps column 19; `rowToSource` maps column 11.
6. **Sort** — browse `ORDER BY` is mode-aware via a correlated subquery on `sources.sort_mode`.
7. **UI** — toggle "Use provider channel order" in the source edit dialog; `updateSource` persists `sort_mode` (also fixes a latent bug where edit wiped `color`).

> Column indices verified by replaying the migration order: `provider_order` is channels col **19**; `sort_mode` is sources col **11**.

## Fix 256.1 — `lib/backend/db_factory.dart`: migration 20
### Current code (verbatim)
```dart
      ..add(SqliteMigration(19, (tx) async {
        await tx.execute(
            'CREATE INDEX IF NOT EXISTS idx_epg_unmatched '
            'ON channels(source_id) '
            'WHERE media_type = 0 AND epg_manual_override IS NULL '
            'AND epg_channel_id IS NULL;');
      }));
    await migrations.migrate(db);
```
### Replacement code (verbatim)
```dart
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
      }));
    await migrations.migrate(db);
```

## Fix 256.2 — `lib/models/xtream_types.dart`: parse `num`
> NOTE: the field is named `providerNum`, NOT `num` — `num` is a built-in Dart type and shadowing it breaks `v is num` checks elsewhere in the file.

### Current code (verbatim)
```dart
  final int? tvArchive; // 1 = catchup available, 0 / missing = not
  final int? tvArchiveDuration; // days, when tvArchive == 1

  XtreamStream({
    this.streamId,
    this.name,
    this.categoryId,
    this.streamIcon,
    this.seriesId,
    this.cover,
    this.containerExtension,
    this.tvArchive,
    this.tvArchiveDuration,
  });
```
### Replacement code (verbatim)
```dart
  final int? tvArchive; // 1 = catchup available, 0 / missing = not
  final int? tvArchiveDuration; // days, when tvArchive == 1
  final int? providerNum; // fix256: provider's intended display order

  XtreamStream({
    this.streamId,
    this.name,
    this.categoryId,
    this.streamIcon,
    this.seriesId,
    this.cover,
    this.containerExtension,
    this.tvArchive,
    this.tvArchiveDuration,
    this.providerNum,
  });
```
### Current code (verbatim)
```dart
      tvArchive: asInt(json['tv_archive']),
      tvArchiveDuration: asInt(json['tv_archive_duration']),
    );
```
### Replacement code (verbatim)
```dart
      tvArchive: asInt(json['tv_archive']),
      tvArchiveDuration: asInt(json['tv_archive_duration']),
      providerNum: asInt(json['num']),
    );
```

## Fix 256.3 — `lib/models/channel.dart`: add `providerOrder`
### Current code (verbatim)
```dart
  /// Result of the most recent StreamScanner probe.
  /// null = never scanned, true = valid media, false = invalid/unreachable.
  bool? streamValidated;

  Channel({
```
### Replacement code (verbatim)
```dart
  /// Result of the most recent StreamScanner probe.
  /// null = never scanned, true = valid media, false = invalid/unreachable.
  bool? streamValidated;

  /// fix256: the provider's intended display order (Xtream `num`, or import
  /// sequence). Null for sources imported before this existed. Used to sort
  /// browse views when the source's sort_mode is 'provider'.
  int? providerOrder;

  Channel({
```
### Current code (verbatim)
```dart
    this.lastWatched,
    this.streamValidated,
```
### Replacement code (verbatim)
```dart
    this.lastWatched,
    this.streamValidated,
    this.providerOrder,
```

## Fix 256.4 — `lib/backend/xtream.dart`: set `providerOrder`
### Current code (verbatim)
```dart
    streamId: int.tryParse(stream.streamId ?? "") ?? -1,
    catchupType: hasCatchup ? 'xc' : null,
    catchupDays: hasCatchup ? stream.tvArchiveDuration : null,
  );
```
### Replacement code (verbatim)
```dart
    streamId: int.tryParse(stream.streamId ?? "") ?? -1,
    catchupType: hasCatchup ? 'xc' : null,
    catchupDays: hasCatchup ? stream.tvArchiveDuration : null,
    providerOrder: stream.providerNum, // fix256: preserve provider display order
  );
```

## Fix 256.5 — `lib/backend/sql.dart`: SINGLE-row `insertChannel` writes `provider_order` (M3U/series path)
> This is the `insertChannel(Channel channel)` method (used by the M3U importer and series episodes). The Xtream importer uses `insertChannelsBulk` — see 256.5b; BOTH must be edited.
### Current code (verbatim)
```dart
        INSERT INTO channels (
          name, image, url, source_id, media_type, series_id, favorite,
          stream_id, group_name, epg_channel_id,
          catchup_type, catchup_source, catchup_days
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT DO UPDATE SET
          url = excluded.url,
          group_name = excluded.group_name,
          media_type = excluded.media_type,
          stream_id = excluded.stream_id,
          image = excluded.image,
          series_id = excluded.series_id,
          -- preserve any user-set epg_channel_id; only fill when the new
          -- import carries one and we have nothing stored yet
          epg_channel_id = COALESCE(channels.epg_channel_id, excluded.epg_channel_id),
          catchup_type = excluded.catchup_type,
          catchup_source = excluded.catchup_source,
          catchup_days = excluded.catchup_days
          -- engine_override intentionally omitted: preserve any user override
          ;
      ''', [
        channel.name,
        channel.image,
        channel.url,
        channel.sourceId == -1
            ? int.parse(memory['sourceId']!)
            : channel.sourceId,
        channel.mediaType.index,
        channel.seriesId,
        channel.favorite,
        channel.streamId,
        channel.group,
        channel.epgChannelId,
        channel.catchupType,
        channel.catchupSource,
        channel.catchupDays,
      ]);
```
### Replacement code (verbatim)
```dart
        INSERT INTO channels (
          name, image, url, source_id, media_type, series_id, favorite,
          stream_id, group_name, epg_channel_id,
          catchup_type, catchup_source, catchup_days, provider_order
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT DO UPDATE SET
          url = excluded.url,
          group_name = excluded.group_name,
          media_type = excluded.media_type,
          stream_id = excluded.stream_id,
          image = excluded.image,
          series_id = excluded.series_id,
          -- preserve any user-set epg_channel_id; only fill when the new
          -- import carries one and we have nothing stored yet
          epg_channel_id = COALESCE(channels.epg_channel_id, excluded.epg_channel_id),
          catchup_type = excluded.catchup_type,
          catchup_source = excluded.catchup_source,
          catchup_days = excluded.catchup_days,
          provider_order = excluded.provider_order
          -- engine_override intentionally omitted: preserve any user override
          ;
      ''', [
        channel.name,
        channel.image,
        channel.url,
        channel.sourceId == -1
            ? int.parse(memory['sourceId']!)
            : channel.sourceId,
        channel.mediaType.index,
        channel.seriesId,
        channel.favorite,
        channel.streamId,
        channel.group,
        channel.epgChannelId,
        channel.catchupType,
        channel.catchupSource,
        channel.catchupDays,
        channel.providerOrder,
      ]);
```

## Fix 256.5b — `lib/backend/sql.dart`: BULK `insertChannelsBulk` writes `provider_order` (Xtream path)
> CRITICAL: the Xtream importer uses this bulk path, NOT the single insert above. Without this edit, provider order is never stored for Xtream sources (the exact case this fix targets). Edit BOTH inserts.

### Current code (verbatim — match exactly)
```dart
      if (channels.isEmpty) return;
      final sourceId = int.parse(memory['sourceId']!);
      const cols = 13;
      final rowPlaceholder = '(${List.filled(cols, '?').join(', ')})';
      final values = List.filled(channels.length, rowPlaceholder).join(', ');
      final params = <Object?>[];
      for (final ch in channels) {
        params.addAll([
          ch.name, ch.image, ch.url,
          ch.sourceId == -1 ? sourceId : ch.sourceId,
          ch.mediaType.index, ch.seriesId, ch.favorite,
          ch.streamId, ch.group, ch.epgChannelId,
          ch.catchupType, ch.catchupSource, ch.catchupDays,
        ]);
      }
      await tx.execute('''
        INSERT INTO channels (
          name, image, url, source_id, media_type, series_id, favorite,
          stream_id, group_name, epg_channel_id,
          catchup_type, catchup_source, catchup_days
        )
        VALUES $values
        ON CONFLICT DO UPDATE SET
          url = excluded.url,
          group_name = excluded.group_name,
          media_type = excluded.media_type,
          stream_id = excluded.stream_id,
          image = excluded.image,
          series_id = excluded.series_id,
          epg_channel_id = COALESCE(channels.epg_channel_id, excluded.epg_channel_id),
          catchup_type = excluded.catchup_type,
          catchup_source = excluded.catchup_source,
          catchup_days = excluded.catchup_days;
      ''', params);
```
### Replacement code (verbatim)
```dart
      if (channels.isEmpty) return;
      final sourceId = int.parse(memory['sourceId']!);
      const cols = 14; // fix256: +provider_order
      final rowPlaceholder = '(${List.filled(cols, '?').join(', ')})';
      final values = List.filled(channels.length, rowPlaceholder).join(', ');
      final params = <Object?>[];
      for (final ch in channels) {
        params.addAll([
          ch.name, ch.image, ch.url,
          ch.sourceId == -1 ? sourceId : ch.sourceId,
          ch.mediaType.index, ch.seriesId, ch.favorite,
          ch.streamId, ch.group, ch.epgChannelId,
          ch.catchupType, ch.catchupSource, ch.catchupDays,
          ch.providerOrder, // fix256
        ]);
      }
      await tx.execute('''
        INSERT INTO channels (
          name, image, url, source_id, media_type, series_id, favorite,
          stream_id, group_name, epg_channel_id,
          catchup_type, catchup_source, catchup_days, provider_order
        )
        VALUES $values
        ON CONFLICT DO UPDATE SET
          url = excluded.url,
          group_name = excluded.group_name,
          media_type = excluded.media_type,
          stream_id = excluded.stream_id,
          image = excluded.image,
          series_id = excluded.series_id,
          epg_channel_id = COALESCE(channels.epg_channel_id, excluded.epg_channel_id),
          catchup_type = excluded.catchup_type,
          catchup_source = excluded.catchup_source,
          catchup_days = excluded.catchup_days,
          provider_order = excluded.provider_order;
      ''', params);
```

## Fix 256.6 — `lib/backend/sql.dart`: `rowToChannel` maps `provider_order` (col 19)
### Current code (verbatim)
```dart
      engineOverride: EngineType.fromJson(row.columnAt(17) as String?),
      streamValidated: sv == null ? null : sv == 1,
    );
  }
```
### Replacement code (verbatim)
```dart
      engineOverride: EngineType.fromJson(row.columnAt(17) as String?),
      streamValidated: sv == null ? null : sv == 1,
      // fix256: provider_order is the last column added (migration 20).
      providerOrder: row.columnAt(19) as int?,
    );
  }
```

## Fix 256.7 — `lib/backend/sql.dart`: mode-aware browse ORDER BY
### Current code (verbatim)
```dart
      // fix138: 6-tier sort matching _channelTier in channel_picker_screen.
      // Applies to ALL media-type browse views (Live/Movies/Series/All).
      sqlQuery += "\nORDER BY"
          " CASE"
          "   WHEN COALESCE(c.favorite,0)=1 AND COALESCE(c.stream_validated,0)=1 THEN 0"
          "   WHEN COALESCE(c.favorite,0)=1 THEN 1"
          "   WHEN c.last_watched IS NOT NULL AND COALESCE(c.stream_validated,0)=1 THEN 2"
          "   WHEN c.last_watched IS NOT NULL THEN 3"
          "   WHEN COALESCE(c.stream_validated,0)=1 THEN 4"
          "   ELSE 5"
          " END ASC,"
          " c.name COLLATE NOCASE ASC";
```
### Replacement code (verbatim)
```dart
      // fix138: 6-tier sort matching _channelTier in channel_picker_screen.
      // Applies to ALL media-type browse views (Live/Movies/Series/All).
      // fix256: when the channel's source is in 'provider' sort mode, order by
      // the provider's intended order (provider_order) within each tier;
      // otherwise (default 'alpha') order by name. A correlated subquery reads
      // the per-source mode so multi-source views sort each source correctly
      // (NULLs last so un-numbered rows fall after numbered ones).
      sqlQuery += "\nORDER BY"
          " CASE"
          "   WHEN COALESCE(c.favorite,0)=1 AND COALESCE(c.stream_validated,0)=1 THEN 0"
          "   WHEN COALESCE(c.favorite,0)=1 THEN 1"
          "   WHEN c.last_watched IS NOT NULL AND COALESCE(c.stream_validated,0)=1 THEN 2"
          "   WHEN c.last_watched IS NOT NULL THEN 3"
          "   WHEN COALESCE(c.stream_validated,0)=1 THEN 4"
          "   ELSE 5"
          " END ASC,"
          " CASE WHEN (SELECT sort_mode FROM sources WHERE id = c.source_id) = 'provider'"
          "   THEN 0 ELSE 1 END ASC,"
          " CASE WHEN (SELECT sort_mode FROM sources WHERE id = c.source_id) = 'provider'"
          "   THEN c.provider_order END ASC,"
          " c.name COLLATE NOCASE ASC";
```

## Fix 256.8 — `lib/models/source.dart`: add `sortMode`
### Current code (verbatim)
```dart
  int? color;

  Source({
    this.id,
    required this.name,
    this.url,
    this.urlOrigin,
    this.username,
    this.password,
    required this.sourceType,
    this.enabled = true,
    this.epgUrl,
    this.defaultEngine,
    this.maxConnections,
    this.color,
```
### Replacement code (verbatim)
```dart
  int? color;

  /// fix256: per-source browse sort. 'provider' = use the provider's intended
  /// order (channels.provider_order); 'alpha' or null = alphabetical by name.
  String? sortMode;

  Source({
    this.id,
    required this.name,
    this.url,
    this.urlOrigin,
    this.username,
    this.password,
    required this.sourceType,
    this.enabled = true,
    this.epgUrl,
    this.defaultEngine,
    this.maxConnections,
    this.color,
    this.sortMode,
```

## Fix 256.9 — `lib/backend/sql.dart`: `rowToSource` maps `sort_mode` (col 11)
### Current code (verbatim)
```dart
      maxConnections: row.columnAt(9) as int?,
      color: row.columnAt(10) as int?,
    );
  }
```
### Replacement code (verbatim)
```dart
      maxConnections: row.columnAt(9) as int?,
      color: row.columnAt(10) as int?,
      sortMode: row.columnAt(11) as String?, // fix256 (migration 20 column)
    );
  }
```

## Fix 256.10 — `lib/backend/sql.dart`: `updateSource` persists `sort_mode`
### Current code (verbatim)
```dart
    await db.execute('''
      UPDATE sources
      SET url = ?, username = ?, password = ?, default_engine = ?,
          max_connections = ?, color = ?
      WHERE id = ?
    ''', [
      source.url,
      source.username,
      source.password,
      source.defaultEngine == null || source.defaultEngine == EngineType.auto
          ? null
          : source.defaultEngine!.toJson(),
      source.maxConnections,
      source.color,
      source.id,
    ]);
```
### Replacement code (verbatim)
```dart
    await db.execute('''
      UPDATE sources
      SET url = ?, username = ?, password = ?, default_engine = ?,
          max_connections = ?, color = ?, sort_mode = ?
      WHERE id = ?
    ''', [
      source.url,
      source.username,
      source.password,
      source.defaultEngine == null || source.defaultEngine == EngineType.auto
          ? null
          : source.defaultEngine!.toJson(),
      source.maxConnections,
      source.color,
      source.sortMode, // fix256
      source.id,
    ]);
```

## Fix 256.11 — `lib/edit_dialog.dart`: the toggle + carry settings through save

### Current code (verbatim — state field)
```dart
class _EditDialogState extends State<EditDialog> {
  final _formKey = GlobalKey<FormBuilderState>();

  @override
```
### Replacement code (verbatim)
```dart
class _EditDialogState extends State<EditDialog> {
  final _formKey = GlobalKey<FormBuilderState>();

  // fix256: per-source browse order. true = provider order, false = alphabetical.
  late bool _providerSort = widget.source.sortMode == 'provider';

  @override
```

### Current code (verbatim — the save's Source construction)
```dart
                      maxConnections: widget.source.maxConnections,
                      defaultEngine: widget.source.defaultEngine)),
```
### Replacement code (verbatim)
```dart
                      maxConnections: widget.source.maxConnections,
                      defaultEngine: widget.source.defaultEngine,
                      // fix256: persist the per-source browse order choice.
                      color: widget.source.color,
                      sortMode: _providerSort ? 'provider' : 'alpha')),
```
> The added `color:` also fixes a latent bug: edit previously omitted color, so `updateSource` wrote NULL and wiped a source's tint on every edit.

### Current code (verbatim — end of the form column)
```dart
                    name: 'password',
                  ))),
            ],
          ))),
    )));
  }
}
```
### Replacement code (verbatim)
```dart
                    name: 'password',
                  ))),
              const SizedBox(height: 10),
              // fix256: per-source channel order. Provider order preserves the
              // provider's intended sequence (incl. "#### SECTION ####" header
              // channels next to their channels); off = alphabetical by name.
              SwitchListTile(
                value: _providerSort,
                onChanged: (v) => setState(() => _providerSort = v),
                title: const Text('Use provider channel order'),
                subtitle: const Text(
                    'Keep the provider\'s order instead of sorting A–Z. '
                    'Applies to Live, Movies, Series and All.'),
                secondary: const Icon(Icons.sort),
              ),
            ],
          ))),
    )));
  }
}
```

## Fix 256.12 — `lib/backend/m3u.dart`: capture line order (M3U path)

M3U has no `num`, but the playlist's line sequence IS the provider's intended order. Maintain a counter incremented per committed channel and store it as `provider_order`, so the per-source toggle works for M3U sources too.

### Current code (verbatim — the parse loop)
```dart
  await for (var line in file) {
    final lineUpper = line.toUpperCase();
    if (lineUpper.startsWith("#EXTINF")) {
      if (channelLine != null &&
          lastLine != null &&
          lastLine.trim().isNotEmpty) {
        commitChannel(
          channelLine,
          lastLine,
          httpHeadersSet ? headers : null,
          batch,
        );
        if (batch.length >= importBatchSize) await flushBatch();
      }
      channelLine = line;
      lastLine = null;
      httpHeadersSet = false;
      headers = null;
    } else if (lineUpper.startsWith("#EXTVLCOPT")) {
      headers ??= ChannelHttpHeaders();
      if (setChannelHeaders(line, headers)) {
        httpHeadersSet = true;
      }
    } else {
      if (line.trim().isNotEmpty) {
        lastLine = line;
      }
    }
  }
  if (channelLine != null && lastLine != null && lastLine.trim().isNotEmpty) {
    commitChannel(channelLine, lastLine, headers, batch);
  }
```
### Replacement code (verbatim)
```dart
  // fix256: provider order for M3U = line sequence (the playlist lists
  // channels in the provider's intended order, the M3U analogue of Xtream's
  // `num`). Increment per committed channel and store as provider_order.
  var order = 0;
  await for (var line in file) {
    final lineUpper = line.toUpperCase();
    if (lineUpper.startsWith("#EXTINF")) {
      if (channelLine != null &&
          lastLine != null &&
          lastLine.trim().isNotEmpty) {
        commitChannel(
          channelLine,
          lastLine,
          httpHeadersSet ? headers : null,
          batch,
          order++,
        );
        if (batch.length >= importBatchSize) await flushBatch();
      }
      channelLine = line;
      lastLine = null;
      httpHeadersSet = false;
      headers = null;
    } else if (lineUpper.startsWith("#EXTVLCOPT")) {
      headers ??= ChannelHttpHeaders();
      if (setChannelHeaders(line, headers)) {
        httpHeadersSet = true;
      }
    } else {
      if (line.trim().isNotEmpty) {
        lastLine = line;
      }
    }
  }
  if (channelLine != null && lastLine != null && lastLine.trim().isNotEmpty) {
    commitChannel(channelLine, lastLine, headers, batch, order++);
  }
```

### Current code (verbatim — commitChannel)
```dart
void commitChannel(
  String l1,
  String last,
  ChannelHttpHeaders? headers,
  List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
  statements,
) {
  var channel = getChannelFromLines(l1, last);
  if (channel == null) return;
  statements.add(Sql.insertChannel(channel));
  if (headers != null) {
    statements.add(Sql.insertChannelHeaders(headers));
  }
}
```
### Replacement code (verbatim)
```dart
void commitChannel(
  String l1,
  String last,
  ChannelHttpHeaders? headers,
  List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
  statements,
  int order, // fix256: provider line order
) {
  var channel = getChannelFromLines(l1, last, order);
  if (channel == null) return;
  statements.add(Sql.insertChannel(channel));
  if (headers != null) {
    statements.add(Sql.insertChannelHeaders(headers));
  }
}
```

### Current code (verbatim — getChannelFromLines signature + Channel head)
```dart
Channel? getChannelFromLines(String l1, String last) {
  var url = last.trim();
  if (url.isEmpty) return null;

  var name = getName(l1)?.trim();
  if (name == null || name.isEmpty) return null;

  final epgId = idRegex.firstMatch(l1)?[1]?.trim();
  final catchupType = catchupTypeRegex.firstMatch(l1)?[1]?.trim();
  final catchupSource = catchupSourceRegex.firstMatch(l1)?[1]?.trim();
  final catchupDaysStr = catchupDaysRegex.firstMatch(l1)?[1]?.trim();

  return Channel(
    name: name,
    group: groupRegex.firstMatch(l1)?[1]?.trim(),
    image: logoRegex.firstMatch(l1)?[1]?.trim(),
    favorite: false,
    mediaType: getMediaType(url),
    sourceId: -1,
    url: url,
```
### Replacement code (verbatim)
```dart
Channel? getChannelFromLines(String l1, String last, int order) {
  var url = last.trim();
  if (url.isEmpty) return null;

  var name = getName(l1)?.trim();
  if (name == null || name.isEmpty) return null;

  final epgId = idRegex.firstMatch(l1)?[1]?.trim();
  final catchupType = catchupTypeRegex.firstMatch(l1)?[1]?.trim();
  final catchupSource = catchupSourceRegex.firstMatch(l1)?[1]?.trim();
  final catchupDaysStr = catchupDaysRegex.firstMatch(l1)?[1]?.trim();

  return Channel(
    name: name,
    group: groupRegex.firstMatch(l1)?[1]?.trim(),
    image: logoRegex.firstMatch(l1)?[1]?.trim(),
    favorite: false,
    mediaType: getMediaType(url),
    sourceId: -1,
    url: url,
    providerOrder: order, // fix256: M3U line sequence
```

## Summary table

| Item | Value |
|---|---|
| Files | `db_factory.dart`, `xtream_types.dart`, `xtream.dart`, `channel.dart`, `source.dart`, `sql.dart` (both inserts + sort + source r/w), `m3u.dart`, `edit_dialog.dart` |
| DB | migration 20: `channels.provider_order`, `sources.sort_mode` |
| Default | alphabetical (existing sources unchanged) |
| Toggle | source edit dialog → "Use provider channel order" |
| Scope | Live / Movies / Series / All (shared browse ORDER BY); both Xtream and M3U importers |
| Incidental fix | edit dialog no longer wipes per-source `color` |
| New analyzer issues | none (2 tolerated INFOs) |

## Pre-tag gate
1. Apply 256.1–256.12 (including 256.5b — the BULK insert for Xtream — and 256.12 — M3U line order).
2. `flutter analyze --no-fatal-infos` → 2 tolerated INFOs only.
3. Bump pubspec; **changelog per RELEASE-PROCEDURE.md** (run `build_and_release.sh` or `gen_changelog.py` + guard); commit; push main; Analyze green; tag.

## Test plan
1. Re-import the Z2U Xtream source (provider_order is captured on import; existing rows get it on the next refresh).
2. Edit the source → enable "Use provider channel order" → save.
3. Open Live: the `#### ABC ####` header now sits directly above ABC Alabama/Alaska/etc., not clustered with other headers. Check Movies/Series/All too.
4. Toggle off → returns to A–Z (headers cluster at top again — expected for alpha).
5. A DIFFERENT source left in default mode still sorts A–Z (per-source isolation).
6. Edit a source that had a tint color → save → color is preserved (incidental fix).

## Notes
- `provider_order` is populated for a source the first time it is imported/refreshed AFTER this ships. An existing source needs one manual refresh to backfill `provider_order` before 'provider' mode has data to sort by (until then those rows are NULL and fall back near name order).
- M3U import sets `provider_order` from line sequence (fix 256.12), so the toggle works for M3U sources too. Both importers are covered.
- Provider mode uses a correlated subquery per row for `sort_mode`; on very large single-source lists this is fine (SQLite caches the tiny sources lookup), and the existing tier CASE already dominates. If ever a concern, the sort could JOIN sources once instead.
