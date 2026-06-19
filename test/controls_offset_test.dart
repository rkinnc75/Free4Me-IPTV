// fix406: the single-cell centre control row is shifted down toward the bottom
// icon row. The offset is computed to land just above the bottom controls on a
// phone, capped so it never overshoots into them on a tall screen (TV), and
// floored at 0 so it never moves up.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player/controls_offset.dart';

void main() {
  group('fix406 loweredPrimaryBarOffset', () {
    test('moves the row down on a typical landscape phone', () {
      final dy = loweredPrimaryBarOffset(height: 412, isLive: true);
      expect(dy, greaterThan(40));
      // Stays in the upper-ish portion of the lower half (no collision).
      expect(dy, lessThan(412 * 0.32 + 0.001));
    });

    test('VOD reserves more (seek bar) so it sits a bit higher than live', () {
      final live = loweredPrimaryBarOffset(height: 412, isLive: true);
      final vod = loweredPrimaryBarOffset(height: 412, isLive: false);
      expect(vod, lessThan(live));
    });

    test('tall screens (TV) are capped at ~a third, never into the bottom row',
        () {
      final dy = loweredPrimaryBarOffset(height: 1080, isLive: true);
      expect(dy, lessThanOrEqualTo(1080 * 0.32 + 0.001));
    });

    test('tiny heights never push up (floored at 0)', () {
      expect(loweredPrimaryBarOffset(height: 200, isLive: false), 0.0);
    });
  });
}
