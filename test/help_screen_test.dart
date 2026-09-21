import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/settings/about_screen.dart';
import 'package:myemail/ui/settings/help_screen.dart';

import 'fakes/fake_webview.dart';

/// The manual and the feature list, carried inside the app.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  test('both documents are bundled and are the real thing', () async {
    for (final page in HelpPage.values) {
      final html = await rootBundle.loadString(page.asset);
      expect(html, startsWith('<!doctype html>'), reason: page.asset);
      expect(html, contains('MyEmail'), reason: page.asset);
      // Self-contained: nothing to fetch, so they open with no signal.
      expect(html, isNot(contains('src="http')), reason: page.asset);
      expect(html, isNot(contains('<script')), reason: page.asset);
    }
    expect(
      await rootBundle.loadString(HelpPage.manual.asset),
      contains('Keyboard'),
    );
  });

  test('a link between the two documents is recognised', () {
    expect(HelpPage.forLink('file:///x/User%20manual.html'), HelpPage.manual);
    expect(HelpPage.forLink('Features.html'), HelpPage.features);
    expect(HelpPage.forLink('https://example.com/page.html'), isNull);
  });

  testWidgets('About offers them, and opens the one asked for', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = FakeWebViewPlatform.install();
    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AboutScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('User manual'), findsOneWidget);
    expect(find.text('What it can do'), findsOneWidget);

    // Reading a document out of the asset bundle is real IO, which a
    // widget test's fake clock never lets finish.
    await open(tester, find.text('User manual'));

    expect(find.byType(HelpScreen), findsOneWidget);
    expect(platform.loadedHtml.last, contains('User manual'));
    // The other document is one tap away from here.
    expect(find.text('What it can do'), findsOneWidget);

    platform.loadedHtml.clear();
    await open(tester, find.text('What it can do'));
    expect(platform.loadedHtml.last, contains('What it can do'));
  });
}

/// Tap something that leads to a document being read from the bundle, and
/// give that read the real time it needs.
Future<void> open(WidgetTester tester, Finder target) async {
  await tester.runAsync(() async {
    await tester.tap(target);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  });
  await tester.pumpAndSettle();
}
