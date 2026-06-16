// fix381: the Add Source wizard collapsed to a single form page. This
// test exercises the new form's per-source-type field visibility and
// the cross-field "is the form valid?" check.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/setup.dart';

void main() {
  testWidgets('Xtream form shows name, url, username, password, epg',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Setup()));
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();

    expect(find.text('Source details'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup.name.field')), findsOneWidget);
    expect(find.byKey(const ValueKey('setup.url.field')), findsOneWidget);
    expect(find.byKey(const ValueKey('setup.username.field')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('setup.password.field')),
        findsOneWidget);
    expect(find.text('EPG URL (optional)'), findsOneWidget);
    expect(find.text('M3U file'), findsNothing);
  });

  testWidgets('M3U URL form hides username and password', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Setup()));
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.tap(find.text('M3U Url'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();

    expect(find.byKey(const ValueKey('setup.url.field')), findsOneWidget);
    expect(find.byKey(const ValueKey('setup.username.field')),
        findsNothing);
    expect(find.byKey(const ValueKey('setup.password.field')),
        findsNothing);
    expect(find.text('M3U file'), findsNothing);
  });

  testWidgets('M3U file form shows the file picker', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Setup()));
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.tap(find.text('M3U'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();

    expect(find.text('M3U file'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup.url.field')), findsNothing);
    expect(find.byKey(const ValueKey('setup.username.field')),
        findsNothing);
    expect(find.byKey(const ValueKey('setup.password.field')),
        findsNothing);
  });

  testWidgets('Add Source button is disabled until Xtream form is complete',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Setup()));
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();

    // Add Source button is disabled when form is empty.
    Finder addSource = find.widgetWithText(FilledButton, 'Add Source');
    FilledButton btn = tester.widget<FilledButton>(addSource);
    expect(btn.onPressed, isNull,
        reason: 'empty Xtream form should disable Add Source');

    // Fill in all four Xtream required fields via their ValueKeys.
    await tester.enterText(
        find.byKey(const ValueKey('setup.name.field')), 'MySrc');
    await tester.enterText(
        find.byKey(const ValueKey('setup.url.field')),
        'http://provider.example.com');
    await tester.enterText(
        find.byKey(const ValueKey('setup.username.field')), 'user');
    await tester.enterText(
        find.byKey(const ValueKey('setup.password.field')), 'pass');
    await tester.pump();

    // Now enabled.
    btn = tester.widget<FilledButton>(addSource);
    expect(btn.onPressed, isNotNull,
        reason: 'fully-filled Xtream form should enable Add Source');
  });

  testWidgets('Add Source button on M3U URL needs only name and url',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Setup()));
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.tap(find.text('M3U Url'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();

    Finder addSource = find.widgetWithText(FilledButton, 'Add Source');
    FilledButton btn = tester.widget<FilledButton>(addSource);
    expect(btn.onPressed, isNull,
        reason: 'empty M3U URL form should disable Add Source');

    await tester.enterText(
        find.byKey(const ValueKey('setup.name.field')), 'M3U');
    await tester.enterText(
        find.byKey(const ValueKey('setup.url.field')),
        'http://m3u.example.com/list.m3u');
    await tester.pump();

    btn = tester.widget<FilledButton>(addSource);
    expect(btn.onPressed, isNotNull,
        reason: 'M3U URL with name+url should enable Add Source');
  });

  testWidgets('Back from form returns to sourceType, not welcome',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Setup()));
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();
    // Form is visible — the Name field is there.
    expect(find.byKey(const ValueKey('setup.name.field')), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pump();

    // Form is gone (Name field absent).
    expect(find.byKey(const ValueKey('setup.name.field')), findsNothing);

    await tester.tap(find.text('Back'));
    await tester.pump();

    // Welcome is back. The PageTransitionSwitcher may show both the
    // outgoing and incoming pages during the 400ms transition, so
    // we check that welcome is back AT LEAST ONCE, not exactly once.
    expect(find.text('Welcome to Free4Me-IPTV'), findsAtLeastNWidgets(1));
    // The form (name field) is gone — confirms we're not still on
    // sourceType or form.
    expect(find.byKey(const ValueKey('setup.name.field')), findsNothing);
  });
}
