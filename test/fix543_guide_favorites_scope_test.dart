// fix543: the Live guide's Favorites filter must apply ONLY to the top-level
// "All channels" view (groupId == null). Inside a selected category the user
// explicitly drilled in and wants that category's channels regardless of the
// Favorites toggle — otherwise (with fix539's _favOnly=true default and no live
// favorites) every category showed "No channels". This test pins the exact
// filter rule that _visibleChannels implements.
import 'package:flutter_test/flutter_test.dart';

// Mirror of TvGuideViewState._visibleChannels' rule, kept tiny and pure so it
// can be unit-tested without the full widget/DB.
List<_Ch> _visibleChannels(List<_Ch> all,
    {required bool favOnly, required int? selectedGroupId}) {
  return (favOnly && selectedGroupId == null)
      ? all.where((c) => c.favorite).toList()
      : all;
}

class _Ch {
  final String name;
  final bool favorite;
  const _Ch(this.name, this.favorite);
}

void main() {
  const cbs = _Ch('CBS Local', false);
  const espn = _Ch('ESPN', true); // a favorite
  const all = [cbs, espn];

  test('All view + favOnly → only favorites (the landing default)', () {
    final v = _visibleChannels(all, favOnly: true, selectedGroupId: null);
    expect(v.map((c) => c.name), ['ESPN']);
  });

  test('All view + favOnly OFF → everything', () {
    final v = _visibleChannels(all, favOnly: false, selectedGroupId: null);
    expect(v.length, 2);
  });

  test('selected category + favOnly → STILL shows the category (the fix)', () {
    // The user drilled into "USA CBS Locals"; favOnly must NOT strip it.
    final v = _visibleChannels(all, favOnly: true, selectedGroupId: 42);
    expect(v.map((c) => c.name), ['CBS Local', 'ESPN'],
        reason: 'category drill-down ignores the favorites filter');
  });

  test('selected category + favOnly OFF → shows the category', () {
    final v = _visibleChannels(all, favOnly: false, selectedGroupId: 42);
    expect(v.length, 2);
  });
}
