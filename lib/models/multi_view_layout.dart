/// Layout format for the multi-view screen.
///
/// [none]     — multi-view disabled (default).
/// [oneByTwo] — two streams side-by-side (landscape).
/// [twoByTwo] — four streams in a 2×2 grid.
enum MultiViewLayout {
  none,
  oneByTwo,
  twoByTwo;

  String toJson() => name;

  static MultiViewLayout fromJson(String? v) => switch (v) {
        'oneByTwo' => oneByTwo,
        'twoByTwo' => twoByTwo,
        _ => none,
      };

  String get label => switch (this) {
        none => 'Disabled',
        oneByTwo => '1×2  Side by side',
        twoByTwo => '2×2  Quad grid',
      };

  int get cellCount => switch (this) {
        none => 0,
        oneByTwo => 2,
        twoByTwo => 4,
      };
}
