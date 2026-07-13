// fix741 (mock §4.3) — guide rail cells show a channel logo with a typographic
// initials fallback ("never a blank box"). Source checks.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
void main() {
  final g = File('lib/tv/tv_guide_view.dart').readAsStringSync();
  test('rail cell renders a logo widget', () {
    expect(g.contains('_railLogo(ch), // fix741'), isTrue);
    expect(g.contains('Widget _railLogo(Channel ch)'), isTrue);
  });
  test('logo falls back to typographic initials', () {
    expect(g.contains('String _channelInitials(String name)'), isTrue);
    expect(g.contains('placeholder: (c, u) => initials()'), isTrue);
    expect(g.contains('errorWidget: (c, u, e) => initials()'), isTrue);
  });
}
