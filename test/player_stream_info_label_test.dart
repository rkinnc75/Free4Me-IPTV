import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/widgets/player_stream_info_label.dart';

// fix522: the on-device failure was a listener-race — the engine emitted the
// stream-info label before media_kit's topButtonBar-owning widget mounted, so
// the broadcast event was dropped (hasListener=false in the fix516 log) and the
// label stayed blank forever. The fix latches the last label on the engine and
// seeds the widget from it at mount. These tests lock in both paths:
// (1) a label already present at mount renders immediately (the race case), and
// (2) a label arriving later via the stream still updates (the non-race case).
void main() {
  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: child,
      ),
    );
  }

  testWidgets('seeds from initialLabel at mount (listener-race case)',
      (tester) async {
    final ctrl = StreamController<String>.broadcast();
    addTearDown(ctrl.close);

    await pump(
      tester,
      PlayerStreamInfoLabel(
        streamInfoStream: ctrl.stream,
        initialLabel: '720p H.264',
      ),
    );

    // Rendered from the latch alone — no stream event was ever delivered,
    // exactly as on-device where the emission landed before this mount.
    expect(find.text('720p H.264'), findsOneWidget);
  });

  testWidgets('renders nothing when no latch and no event yet', (tester) async {
    final ctrl = StreamController<String>.broadcast();
    addTearDown(ctrl.close);

    await pump(tester, PlayerStreamInfoLabel(streamInfoStream: ctrl.stream));

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('updates from a later stream event', (tester) async {
    final ctrl = StreamController<String>.broadcast();
    addTearDown(ctrl.close);

    await pump(tester, PlayerStreamInfoLabel(streamInfoStream: ctrl.stream));
    expect(find.byType(Text), findsNothing);

    ctrl.add('1080p H.265');
    await tester.pump(Duration.zero); // flush broadcast delivery
    await tester.pump();

    expect(find.text('1080p H.265'), findsOneWidget);
  });

  testWidgets('a later stream event overrides the seeded latch',
      (tester) async {
    final ctrl = StreamController<String>.broadcast();
    addTearDown(ctrl.close);

    await pump(
      tester,
      PlayerStreamInfoLabel(
        streamInfoStream: ctrl.stream,
        initialLabel: '720p H.264',
      ),
    );
    expect(find.text('720p H.264'), findsOneWidget);

    ctrl.add('2160p H.265');
    await tester.pump(Duration.zero); // flush broadcast delivery
    await tester.pump();

    expect(find.text('2160p H.265'), findsOneWidget);
    expect(find.text('720p H.264'), findsNothing);
  });
}
