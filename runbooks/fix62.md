# fix62.md — Content type filter on the All tab (Live / Movies / Series / All)

> **Problem:** Emjay has 269,000 channels (54k live + 171k movies +
> 44k series). FTS phrase queries against 269k rows take 100+ seconds.
> The user only watches live TV. There is no fast way to limit the
> view to live channels only.
>
> **Solution:** The All tab becomes a cycling content-type filter.
> Tapping it advances through the enabled content types. The
> `media_type` index makes single-type queries against 54k rows
> instead of 269k — reducing FTS time from 100s to <10ms.

---

## Design decisions

| State | Icon | Color | `mediaTypes` filter |
|---|---|---|---|
| All | `Icons.list` | White `#FFFFFF` | all enabled types |
| Live | `Icons.live_tv` | Blue `#4E9FE5` | `[livestream]` |
| Movies | `Icons.movie` | Lime `#8BC34A` | `[movie]` |
| Series | `Icons.video_library` | Magenta `#E040FB` | `[serie]` |

- Cycles only through states whose Settings toggle is `true`.
- If exactly one type is enabled, the button is static (no tap).
- If zero types are enabled, the `at-least-one` guard in Settings
  prevents it (see fix62.5).
- **All** = "no single-type filter" — uses whatever types Settings
  has enabled, same as current behaviour.
- `contentTypeFilter` persists in `Settings`, saved to DB, exported
  in backup. Restored on app launch.
- On relaunch, if the saved filter is no longer available (e.g. user
  disabled Movies), resets to `all`.
- Favorites and History tabs ignore the filter.

---

# Fix 62.1 — Add `ContentTypeFilter` enum and `contentTypeFilter` field to `Settings`

**File:** `lib/models/settings.dart`

Add after the `MultiViewLayout` import at the top:

```dart
enum ContentTypeFilter { all, live, movies, series }
```

Add field after `showSeries` (around line 13):

```dart
  bool showSeries;
  ContentTypeFilter contentTypeFilter;
```

Add constructor default after `this.showSeries = true` (around line 118):

```dart
    this.showSeries = true,
    this.contentTypeFilter = ContentTypeFilter.all,
```

Update `getMediaTypes()` to respect the filter when a specific type
is selected:

**Current code:**
```dart
List<MediaType> getMediaTypes() {
  return [
    if (showLivestreams) MediaType.livestream,
    if (showMovies) MediaType.movie,
    if (showSeries) MediaType.serie,
  ];
}
```

**Replace with:**
```dart
/// Returns the list of MediaTypes for the current content filter.
/// If [contentTypeFilter] is set to a specific type, returns only
/// that type (provided its show-toggle is enabled). Falls back to
/// all enabled types if the filtered type is disabled.
List<MediaType> getMediaTypes() {
  switch (contentTypeFilter) {
    case ContentTypeFilter.live:
      if (showLivestreams) return [MediaType.livestream];
      break;
    case ContentTypeFilter.movies:
      if (showMovies) return [MediaType.movie];
      break;
    case ContentTypeFilter.series:
      if (showSeries) return [MediaType.serie];
      break;
    case ContentTypeFilter.all:
      break;
  }
  // Fall through: return all enabled types.
  return [
    if (showLivestreams) MediaType.livestream,
    if (showMovies) MediaType.movie,
    if (showSeries) MediaType.serie,
  ];
}

/// Returns the content filter states available given current Settings.
/// Used by BottomNav to build the cycle sequence.
List<ContentTypeFilter> availableContentFilters() {
  final available = <ContentTypeFilter>[];
  final enabledCount = (showLivestreams ? 1 : 0) +
      (showMovies ? 1 : 0) +
      (showSeries ? 1 : 0);
  // Only include All when more than one type is enabled.
  if (enabledCount > 1) available.add(ContentTypeFilter.all);
  if (showLivestreams) available.add(ContentTypeFilter.live);
  if (showMovies) available.add(ContentTypeFilter.movies);
  if (showSeries) available.add(ContentTypeFilter.series);
  return available;
}

/// Returns the next content filter in the cycle, wrapping around.
ContentTypeFilter nextContentFilter() {
  final available = availableContentFilters();
  if (available.length <= 1) return available.isEmpty
      ? ContentTypeFilter.all
      : available.first;
  final idx = available.indexOf(contentTypeFilter);
  return available[(idx + 1) % available.length];
}
```

---

# Fix 62.2 — Persist `contentTypeFilter` in `SettingsService`

**File:** `lib/backend/settings_service.dart`

Add property key constant near the other show-type props:

```dart
const contentTypeFilterProp = 'contentTypeFilter';
```

In `_readFromDb`, after the series read (around line 129):

```dart
    if (series != null) settings.showSeries = int.parse(series) == 1;
    final ctf = settingsMap[contentTypeFilterProp];
    if (ctf != null) {
      final idx = int.tryParse(ctf) ?? 0;
      settings.contentTypeFilter = ContentTypeFilter.values
          .elementAtOrNull(idx) ?? ContentTypeFilter.all;
      // Validate: if the saved filter is no longer available
      // (e.g. user disabled that content type), reset to all.
      if (!settings.availableContentFilters()
          .contains(settings.contentTypeFilter)) {
        settings.contentTypeFilter = ContentTypeFilter.all;
      }
    }
```

In `updateSettings`, after the series write (around line 208):

```dart
    settingsMap[showSeries] = (settings.showSeries ? 1 : 0).toString();
    settingsMap[contentTypeFilterProp] =
        settings.contentTypeFilter.index.toString();
```

---

# Fix 62.3 — Export/import `contentTypeFilter` in `SettingsIo`

**File:** `lib/backend/settings_io.dart`

In `_settingsToMap`, after `showSeries` (around line 298):

```dart
    'showSeries': s.showSeries,
    'contentTypeFilter': s.contentTypeFilter.index,
```

In `_settingsFromMap`, after the showSeries block (around line 354):

```dart
    if (m['showSeries'] is bool) s.showSeries = m['showSeries'];
    if (m['contentTypeFilter'] is int) {
      final idx = m['contentTypeFilter'] as int;
      s.contentTypeFilter = ContentTypeFilter.values
          .elementAtOrNull(idx) ?? ContentTypeFilter.all;
      if (!s.availableContentFilters().contains(s.contentTypeFilter)) {
        s.contentTypeFilter = ContentTypeFilter.all;
      }
    }
```

---

# Fix 62.4 — Update `BottomNav` to cycle the All tab

**File:** `lib/bottom_nav.dart`

Replace the entire file:

```dart
import 'package:flutter/material.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/settings_view.dart';

// ── Fixed tab definitions (Categories → Settings) ─────────────────────────

const _fixedColors = [
  Color(0xFF9B59D9), // Categories — purple
  Color(0xFFF0B429), // Favorites  — amber
  Color(0xFF4CAF78), // History    — green
  Color(0xFFE8624A), // Settings   — red-orange
];

const _fixedIcons = [
  Icons.dashboard,
  Icons.star,
  Icons.history,
  Icons.settings,
];

const _fixedLabels = ['Categories', 'Favorites', 'History', 'Settings'];

// ── Content-type filter definitions ───────────────────────────────────────

const _filterColors = {
  ContentTypeFilter.all:     Color(0xFFFFFFFF),
  ContentTypeFilter.live:    Color(0xFF4E9FE5),
  ContentTypeFilter.movies:  Color(0xFF8BC34A),
  ContentTypeFilter.series:  Color(0xFFE040FB),
};

const _filterIcons = {
  ContentTypeFilter.all:    Icons.list,
  ContentTypeFilter.live:   Icons.live_tv,
  ContentTypeFilter.movies: Icons.movie,
  ContentTypeFilter.series: Icons.video_library,
};

const _filterLabels = {
  ContentTypeFilter.all:    'All',
  ContentTypeFilter.live:   'Live',
  ContentTypeFilter.movies: 'Movies',
  ContentTypeFilter.series: 'Series',
};

class BottomNav extends StatefulWidget {
  final Function(ViewType) updateViewMode;
  final Function(ContentTypeFilter) onContentTypeChanged;
  final ViewType startingView;
  final ContentTypeFilter contentTypeFilter;
  final Settings settings;
  final bool blockSettings;

  const BottomNav({
    super.key,
    required this.updateViewMode,
    required this.onContentTypeChanged,
    required this.settings,
    this.startingView = ViewType.all,
    this.contentTypeFilter = ContentTypeFilter.all,
    this.blockSettings = false,
  });

  @override
  State<BottomNav> createState() => _BottomNavState();
}

class _BottomNavState extends State<BottomNav> {
  // 0 = All/filter tab; 1-4 = Categories, Favorites, History, Settings
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Map ViewType to nav index.
    // ViewType.all = 0, categories = 1, favorites = 2, history = 3, settings = 4
    _selectedIndex = widget.startingView.index;
  }

  void _onFilterTap() {
    final available = widget.settings.availableContentFilters();
    // Static — only one state available, nothing to cycle.
    if (available.length <= 1) return;
    final next = widget.settings.nextContentFilter();
    widget.onContentTypeChanged(next);
  }

  void _onFixedTap(int fixedIndex) {
    // fixedIndex 0-3 maps to Categories, Favorites, History, Settings
    final viewIndex = fixedIndex + 1; // ViewType index
    if (widget.blockSettings && viewIndex == ViewType.settings.index) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings disabled while refreshing on start'),
        ),
      );
      return;
    }
    setState(() => _selectedIndex = viewIndex);
    if (viewIndex == ViewType.settings.index) {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (_, _, _) => const SettingsView(),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          transitionsBuilder: (_, _, _, child) => child,
        ),
        (route) => false,
      );
      return;
    }
    widget.updateViewMode(ViewType.values[viewIndex]);
  }

  Widget _navItem({
    required Color color,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    bool canCycle = false,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? color.withAlpha(46)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.contentTypeFilter;
    final available = widget.settings.availableContentFilters();
    final canCycle = available.length > 1;

    final filterColor = _filterColors[filter]!;
    final filterIcon = _filterIcons[filter]!;
    final filterLabel = _filterLabels[filter]!;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceBright,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.surfaceBright,
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 80,
          child: Row(
            children: [
              // ── All / filter tab ──────────────────────────────────────
              _navItem(
                color: filterColor,
                icon: filterIcon,
                label: filterLabel,
                selected: _selectedIndex == 0,
                onTap: () {
                  setState(() => _selectedIndex = 0);
                  if (canCycle) _onFilterTap();
                  // Always navigate back to All view when tapping
                  // this tab, even if just changing the filter.
                  widget.updateViewMode(ViewType.all);
                },
                canCycle: canCycle,
              ),
              // ── Fixed tabs ────────────────────────────────────────────
              for (var i = 0; i < _fixedLabels.length; i++)
                _navItem(
                  color: _fixedColors[i],
                  icon: _fixedIcons[i],
                  label: _fixedLabels[i],
                  selected: _selectedIndex == i + 1,
                  onTap: () => _onFixedTap(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
```

---

# Fix 62.5 — Guard against disabling the last content type in Settings

**File:** `lib/settings_view.dart`

Replace the three `_switchTile` onChanged callbacks for
showLivestreams, showMovies, showSeries with versions that block
disabling the last enabled type:

**Current code (lines 1619–1645):**

```dart
_switchTile(
  label: "Show livestreams",
  value: settings.showLivestreams,
  help: _helpShowLivestreams,
  onChanged: (v) {
    setState(() => settings.showLivestreams = v);
    updateSettings();
  },
),
_switchTile(
  label: "Show movies",
  value: settings.showMovies,
  help: _helpShowMovies,
  onChanged: (v) {
    setState(() => settings.showMovies = v);
    updateSettings();
  },
),
_switchTile(
  label: "Show series",
  value: settings.showSeries,
  help: _helpShowSeries,
  onChanged: (v) {
    setState(() => settings.showSeries = v);
    updateSettings();
  },
),
```

**Replace with:**

```dart
_switchTile(
  label: "Show livestreams",
  value: settings.showLivestreams,
  help: _helpShowLivestreams,
  onChanged: (v) {
    if (!v && !settings.showMovies && !settings.showSeries) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('At least one content type must be enabled.'),
      ));
      return;
    }
    setState(() {
      settings.showLivestreams = v;
      // If the active filter is now disabled, reset to all.
      if (!settings.availableContentFilters()
          .contains(settings.contentTypeFilter)) {
        settings.contentTypeFilter = ContentTypeFilter.all;
      }
    });
    updateSettings();
  },
),
_switchTile(
  label: "Show movies",
  value: settings.showMovies,
  help: _helpShowMovies,
  onChanged: (v) {
    if (!v && !settings.showLivestreams && !settings.showSeries) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('At least one content type must be enabled.'),
      ));
      return;
    }
    setState(() {
      settings.showMovies = v;
      if (!settings.availableContentFilters()
          .contains(settings.contentTypeFilter)) {
        settings.contentTypeFilter = ContentTypeFilter.all;
      }
    });
    updateSettings();
  },
),
_switchTile(
  label: "Show series",
  value: settings.showSeries,
  help: _helpShowSeries,
  onChanged: (v) {
    if (!v && !settings.showLivestreams && !settings.showMovies) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('At least one content type must be enabled.'),
      ));
      return;
    }
    setState(() {
      settings.showSeries = v;
      if (!settings.availableContentFilters()
          .contains(settings.contentTypeFilter)) {
        settings.contentTypeFilter = ContentTypeFilter.all;
      }
    });
    updateSettings();
  },
),
```

---

# Fix 62.6 — Wire `BottomNav` to `Home` with content-type callbacks

**File:** `lib/home.dart`

### Update `BottomNav` instantiation

**Current code (lines 607–611):**

```dart
BottomNav(
  startingView: getStartingView(),
  blockSettings: blockSettings,
  updateViewMode: updateViewMode,
)
```

**Replace with:**

```dart
BottomNav(
  startingView: getStartingView(),
  blockSettings: blockSettings,
  updateViewMode: updateViewMode,
  settings: SettingsService.cached ?? Settings(),
  contentTypeFilter:
      SettingsService.cached?.contentTypeFilter
      ?? ContentTypeFilter.all,
  onContentTypeChanged: (filter) async {
    final s = SettingsService.cached;
    if (s == null) return;
    s.contentTypeFilter = filter;
    await SettingsService.updateSettings(s);
    if (!mounted) return;
    setState(() {
      widget.home.filters.mediaTypes = s.getMediaTypes();
    });
    await load(false);
  },
)
```

### Update `mediaTypes` initialisation to respect the saved filter

**Current code (lines 86–91):**

```dart
if (widget.home.filters.mediaTypes == null) {
  final s =
      SettingsService.cached ?? await SettingsService.getSettings();
  if (!mounted) return;
  widget.home.filters.mediaTypes = s.getMediaTypes();
}
```

No change needed — `s.getMediaTypes()` already calls into the updated
method from fix62.1 which respects `contentTypeFilter`. The saved
filter is loaded at startup via `SettingsService.getSettings()` →
`_readFromDb` (fix62.2). On first launch the field defaults to
`ContentTypeFilter.all`.

### Add import if needed

```dart
import 'package:open_tv/models/settings.dart';
```

---

## What changes visually

| Before | After |
|---|---|
| All tab: blue list icon, always shows all types | All tab cycles: White All → Blue Live → Lime Movies → Magenta Series |
| No way to filter to live only | Tap All → Live → only 54k channels searched |
| "yes network" takes 102s | "yes network" against 54k channels: <10ms |
| Disabling all content types possible | Blocked with snackbar |

---

## Test plan

### Cycle behaviour

1. With all three types enabled, tap All tab repeatedly.
   Expected cycle: All → Live → Movies → Series → All.
2. Disable Series in Settings. Tap All tab.
   Expected cycle: All → Live → Movies → All.
3. Disable Movies too (only Live enabled). All tab becomes static,
   shows Live icon/color permanently. No tap response.
4. Re-enable Movies. All tab cycles again.

### Persistence

1. Set filter to Live. Force-quit. Relaunch.
   Expected: Live filter still active, only live channels shown.
2. Export backup. Fresh install. Import backup.
   Expected: Live filter restored from backup.
3. Disable Live in Settings while filter is set to Live.
   Expected: filter resets to All automatically.

### Search performance

1. Set filter to Live (54k channels).
2. Search "yes network".
   Expected: results in <500ms.
3. Set filter to All (269k channels).
4. Search "yes network".
   Expected: slower (same as before — All is unfiltered).
   This is acceptable — the filter is the user's tool.

### At-least-one guard

1. Disable Livestreams. Disable Movies. Attempt to disable Series.
   Expected: snackbar "At least one content type must be enabled."
   Series toggle stays on.

### Favorites and History

1. Set filter to Live. Go to Favorites.
   Expected: all favorited channels shown regardless of type
   (`mediaTypes` for Favorites/History is not affected by the
   filter — they use their own query path).

---

## Notes for the implementer

- **`ContentTypeFilter` enum lives in `settings.dart`** alongside
  `Settings`. No new file needed.
- **`BottomNav` gains three new required props:** `settings`,
  `contentTypeFilter`, `onContentTypeChanged`. The `SettingsView`'s
  `BottomNav` instantiation (around line 2256) also needs updating
  with these props — pass `SettingsService.cached ?? Settings()` and
  a no-op `onContentTypeChanged` (Settings view doesn't need to
  respond to filter changes).
- **The filter tab always navigates to `ViewType.all`** when tapped,
  even if the user is on Categories. This is intentional — changing
  the content type resets the view to All so the filter is
  immediately visible.
- **`availableContentFilters()` and `nextContentFilter()` are pure
  functions** on `Settings` — no state, no async. Safe to call
  during build.
- **No SQL changes.** `Filters.mediaTypes` already drives the
  `AND c.media_type IN (?,?,?)` clause and `index_channel_media_type`
  is already in place. Single-type queries use the index
  automatically.
- **No migration needed.** `contentTypeFilter` is a new Settings
  key — missing from old DBs defaults to `ContentTypeFilter.all`
  which matches current behaviour.
