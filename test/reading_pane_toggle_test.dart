import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/ribbon.dart';

import 'fakes/fake_webview.dart';

/// Moving the reading pane from the ribbon, without going into Settings.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<ProviderContainer> pump(WidgetTester tester) async {
    useSize(tester, const Size(1400, 900));
    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  Finder paneButton() => find.descendant(
    of: find.byType(Ribbon),
    matching: find.textContaining('Pane '),
  );

  testWidgets('the ribbon carries a pane button', (tester) async {
    await pump(tester);

    expect(paneButton(), findsOneWidget);
    // The label names where the pane is now, so the button reads as a state
    // as well as a control.
    expect(find.text('Pane right'), findsOneWidget);
  });

  testWidgets('pressing it cycles right, bottom, off and back', (tester) async {
    final c = await pump(tester);
    ReadingPanePosition where() => c.read(displayProvider).readingPane;

    expect(where(), ReadingPanePosition.right);

    for (final expected in [
      ReadingPanePosition.bottom,
      ReadingPanePosition.off,
      ReadingPanePosition.right,
    ]) {
      await tester.tap(paneButton());
      await tester.pumpAndSettle();
      expect(where(), expected);
      expect(find.text('Pane ${expected.label.toLowerCase()}'), findsOneWidget);
    }
  });

  testWidgets('the layout follows the button', (tester) async {
    // The point of the button is the layout, not the setting: pressing it to
    // "off" has to actually take the pane off the screen.
    await pump(tester);
    expect(find.byType(ReadingPane), findsOneWidget);

    await tester.tap(paneButton()); // bottom
    await tester.pumpAndSettle();
    expect(find.byType(ReadingPane), findsOneWidget);

    await tester.tap(paneButton()); // off
    await tester.pumpAndSettle();
    expect(find.byType(ReadingPane), findsNothing);
  });

  testWidgets('the choice outlives a restart', (tester) async {
    // Same store behind both runs, which is what the real one does.
    final store = MemoryUiStateStore();
    useSize(tester, const Size(1400, 900));

    for (var run = 0; run < 2; run++) {
      final c = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(store)],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();

      if (run == 0) {
        await tester.tap(paneButton());
        await tester.pumpAndSettle();
      } else {
        expect(c.read(displayProvider).readingPane, ReadingPanePosition.bottom);
      }
      c.dispose();
    }
  });
}
