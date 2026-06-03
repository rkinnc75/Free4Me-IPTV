# fix54.md — Per-item colors on the bottom navigation bar

> **Request:** apply distinct colors to each bottom nav item's icon
> and label, matching the screenshot. No gradient, no layout changes,
> no redesign — strictly colors on the existing icons and text.
>
> **Why a custom Row instead of `NavigationBarThemeData`:**
> Flutter's `NavigationBar` widget applies a single
> `iconTheme.color` and `labelTextStyle.color` across all
> destinations. There is no per-destination color API. The only
> way to give each item its own color while keeping the same
> visual structure (icon + label + selected pill) is to replace
> the `NavigationBar` with a `Row` of five hand-rolled items.
> The tap logic, routing, `blockSettings` guard, and
> `_selectedIndex` state are all unchanged.

---

## Colors

| Index | Tab | Icon | Color |
|---|---|---|---|
| 0 | All | `Icons.list` | `#4E9FE5` (blue) |
| 1 | Categories | `Icons.dashboard` | `#9B59D9` (purple) |
| 2 | Favorites | `Icons.star` | `#F0B429` (amber) |
| 3 | History | `Icons.history` | `#4CAF78` (green) |
| 4 | Settings | `Icons.settings` | `#E8624A` (red-orange) |

---

## Fix 54.1 — Replace `bottom_nav.dart`

**File:** `lib/bottom_nav.dart`

**Replace the entire file with:**

```dart
import 'package:flutter/material.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/settings_view.dart';

// Per-item colors matching the design screenshot.
const _navColors = [
  Color(0xFF4E9FE5), // All — blue
  Color(0xFF9B59D9), // Categories — purple
  Color(0xFFF0B429), // Favorites — amber
  Color(0xFF4CAF78), // History — green
  Color(0xFFE8624A), // Settings — red-orange
];

const _navIcons = [
  Icons.list,
  Icons.dashboard,
  Icons.star,
  Icons.history,
  Icons.settings,
];

const _navLabels = ['All', 'Categories', 'Favorites', 'History', 'Settings'];

class BottomNav extends StatefulWidget {
  final Function(ViewType) updateViewMode;
  final ViewType startingView;
  final bool blockSettings;
  const BottomNav({
    super.key,
    required this.updateViewMode,
    this.startingView = ViewType.all,
    this.blockSettings = false,
  });

  @override
  State<BottomNav> createState() => _BottomNavState();
}

class _BottomNavState extends State<BottomNav> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.startingView.index;
  }

  void onBarTapped(int index) {
    if (widget.blockSettings && index == ViewType.settings.index) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Settings disabled while refreshing on start"),
        ),
      );
      return;
    }
    setState(() => _selectedIndex = index);
    if (_selectedIndex == ViewType.settings.index) {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (_, _, _) => const SettingsView(),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) => child,
        ),
        (route) => false,
      );
      return;
    }
    widget.updateViewMode(ViewType.values[_selectedIndex]);
  }

  @override
  Widget build(BuildContext context) {
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
      // Match the height NavigationBar uses at its default size.
      height: 80,
      child: Row(
        children: List.generate(_navLabels.length, (i) {
          final color = _navColors[i];
          final selected = _selectedIndex == i;
          return Expanded(
            child: InkWell(
              onTap: () => onBarTapped(i),
              borderRadius: BorderRadius.circular(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Selected pill — same shape as Material 3 NavigationBar.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? color.withValues(alpha: 0.18)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      _navIcons[i],
                      color: color,
                      size: 24,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _navLabels[i],
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
```

---

## What changed vs the original

| | Before | After |
|---|---|---|
| Widget | `NavigationBar` | `Container` + `Row` |
| Icon color | Single theme color | Per-item from `_navColors` |
| Label color | Single theme color | Per-item from `_navColors` |
| Selected indicator | Material 3 full-width pill | Same shape, item color at 18% opacity |
| Selected label weight | Theme default | `FontWeight.w600` |
| Tap logic | Unchanged | Unchanged |
| Routing | Unchanged | Unchanged |
| `blockSettings` guard | Unchanged | Unchanged |
| Height | `NavigationBar` default (~80dp) | Explicit `80` to match |

The pill is animated (`AnimatedContainer`, 200ms ease-in-out) so
selecting a tab feels the same as the original Material 3 transition.

---

## Test plan

1. Apply fix54 and rebuild.
2. Open the app. Bottom nav should show five items with the colors
   from the screenshot — blue, purple, amber, green, red-orange.
3. Tap each tab. Active item icon and label should remain their
   color; the pill background should appear behind the active icon
   at 18% opacity of the same color.
4. Verify tap routing still works:
   - All / Categories / Favorites / History → updates the channel
     grid view.
   - Settings → navigates to `SettingsView` (pushAndRemoveUntil).
5. While refresh-on-start is running, tap Settings. Snackbar should
   appear: "Settings disabled while refreshing on start".
6. Check on TV (D-pad). The `InkWell` `borderRadius` should not
   interfere with focus traversal — if it does, wrap each item in
   a `Focus` widget with the existing focus handling.

---

## Notes for the implementer

- **`color.withValues(alpha: 0.18)`** — uses the newer API
  (`withValues`) instead of the deprecated `withOpacity`. If the
  Dart/Flutter version in this project doesn't have `withValues`,
  use `color.withAlpha((0.18 * 255).round())` instead.
- **Height `80`** — matches `NavigationBar`'s default height of
  80dp. If the existing nav appears at a different height in the
  running app, adjust this one value.
- **No imports added** — `bottom_nav.dart` already imports
  `Material`, `ViewType`, and `SettingsView`. The new file uses
  the same three imports.
- **TV focus:** `NavigationBar` had built-in focus handling for
  D-pad navigation. The `InkWell` doesn't. If TV users report
  focus issues, wrap each `Expanded` in a `Focus` widget or switch
  `InkWell` to `FilledButton.tonal` which has focus support built
  in. Out of scope unless reported.
- **No other files touched.** All color constants live in
  `bottom_nav.dart` so they're easy to tweak in one place.
