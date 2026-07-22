// fix760: phone-mode zap-latency work.
//  • Tap-down prewarm (ChannelTile): pendingPrewarm() exposes the in-flight
//    redirect resolution so the Player can await it (bounded) instead of
//    racing it. When nothing is resolving, it must return null — the Player
//    takes the fast path with zero added latency.
//  • Opt-in demuxer probe tunables: 0 is a sentinel meaning "property never
//    set" (libmpv keeps its defaults), and non-defaults must survive the
//    settings backup round-trip like every other Developer field (the fix573
//    dropped-field class of bug).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/settings_io.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/models/settings.dart';

void main() {
  test('fix760: pendingPrewarm returns null when no resolution is in flight',
      () {
    // No prewarm has been started anywhere in this process — the Player's
    // bounded-wait branch must see null and skip the await entirely.
    expect(ChannelTile.pendingPrewarm(123456), isNull);
  });

  test('fix760: probe tunables default to 0 (sentinel — property not set)',
      () {
    final s = Settings.defaults();
    expect(s.devDemuxerLavfAnalyzeDurationSecs, 0);
    expect(s.devDemuxerLavfProbeSizeKiB, 0);
  });

  test('fix760: probe tunables survive backup round-trip', () {
    final s = Settings.defaults()
      ..devDemuxerLavfAnalyzeDurationSecs = 1.5 // default 0
      ..devDemuxerLavfProbeSizeKiB = 512; // default 0

    final r = SettingsIo.roundTripForTest(s);

    expect(r.devDemuxerLavfAnalyzeDurationSecs, 1.5);
    expect(r.devDemuxerLavfProbeSizeKiB, 512);
  });
}
