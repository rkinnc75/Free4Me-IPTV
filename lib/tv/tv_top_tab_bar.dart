import 'package:flutter/material.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/tv/focus/tv_focusable.dart'; // fix702 (TV GUI redesign)
import 'package:open_tv/tv/theme/f4_motion.dart'; // fix702
import 'package:open_tv/tv/theme/f4_tokens.dart'; // fix702

/// fix500: a single tab in the TV shell's top bar.
///
/// Colors are COPIED from `bottom_nav.dart`'s per-section palette — we copy the
/// consts rather than reuse the phone-only `BottomNav` widget, so phone mode is
/// untouched.
class TvTab {
  final String label;
  final Color color;
  final List<MediaType> mediaTypes;
  final ViewType viewType;
  final bool isSearch;
  // fix607: this tab has a held-OK long-press action (Live TV → diagnostic
  // report; History → clear history). Only these tabs get the held-OK detector;
  // the rest keep plain quick-switch (so a held OK still switches them — fixes
  // the "held-OK on Movies/Series swallowed, tab fails to switch" regression).
  final bool longPress;

  /// fix669: this tab mounts the Scheduled Recording list (RecordingsView),
  /// not the Home browse body.
  final bool isRecordings;

  const TvTab({
    required this.label,
    required this.color,
    required this.mediaTypes,
    required this.viewType,
    this.isSearch = false,
    this.longPress = false,
    this.isRecordings = false,
  });
}

/// fix500: the persistent top tab bar — brand · tabs · Settings gear.
/// D-pad: tabs are a horizontal [FocusTraversalGroup]; the active tab is
/// highlighted with its section color and the focused tab draws the accent ring
/// (fix702: via [TvFocusable], replacing the flat yellow border). Down from a
/// tab enters the body.
class TvTopTabBar extends StatelessWidget {
  final List<TvTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onSettings;

  /// fix524: optional long-press per tab index (TV History tab → clear all).
  final ValueChanged<int>? onLongPress;

  const TvTopTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    required this.onSettings,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // fix529: the real app icon, not the placeholder green TV icon.
                // fix558: dimmed to 40% opacity — at full strength it competed
                // visually with the tabs/Settings gear in the header row.
                Opacity(
                  opacity: 0.4,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.asset('assets/icon.png',
                        width: 28, height: 28, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Free4Me',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: FocusTraversalGroup(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int i = 0; i < tabs.length; i++)
                    _TabButton(
                      tab: tabs[i],
                      selected: i == selectedIndex,
                      autofocus: i == selectedIndex,
                      onTap: () => onSelected(i),
                      // fix607: only tabs that declare a long-press action get
                      // one — otherwise a held OK on Movies/Series/etc. would be
                      // swallowed (no switch). Tabs without it use plain
                      // quick-switch (the held-OK detector isn't installed).
                      onLongPress: (onLongPress == null || !tabs[i].longPress)
                          ? null
                          : () => onLongPress!(i),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

/// fix702: a single tab, now on the shared [TvFocusable] — accent focus ring +
/// 1.05× lift + the unified fire-on-release held-OK. The selected pill keeps its
/// section-identity fill (our win). Held-OK is only wired for tabs that declare
/// a long-press action (Live TV → diagnostic report; History → clear); other
/// tabs pass `onHeldOk: null`, so a held OK still fires `onTap` (switches) —
/// preserving the fix607 "held-OK on Movies/Series must still switch" behaviour.
///
/// Touch note (fix607): the old code withheld touch `onLongPress` to avoid a
/// touch long-press silently firing the diagnostic POST / clear. [TvFocusable]
/// does wire touch `onLongPress → onHeldOk`, but this tab bar is a TV-only
/// surface (the shell renders only on `!hasTouchScreen`; touch devices use the
/// phone `BottomNav`), so no touchscreen ever reaches it — the guard is moot.
class _TabButton extends StatelessWidget {
  final TvTab tab;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _TabButton({
    required this.tab,
    required this.selected,
    required this.autofocus,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = F4.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TvFocusable(
        autofocus: autofocus,
        onTap: onTap,
        onHeldOk: onLongPress, // null → held OK still switches (fix607)
        outlineWidth: tokens.focus.ringChrome,
        borderRadius: tokens.radius.pill,
        // Keep the tab's established 600ms hold (fix607) rather than the 500ms
        // default, so the diagnostic/clear feel is unchanged.
        holdThreshold: const Duration(milliseconds: 600),
        builder: (context, isFocused) {
          final bg = selected ? tab.color : Colors.transparent;
          final fg = selected ? Colors.black : tokens.colors.textSecondary;
          return AnimatedContainer(
            duration: F4Motion.fast,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(tokens.radius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tab.isSearch) ...[
                  Icon(Icons.search, size: 18, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  tab.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
