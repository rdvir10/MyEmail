import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/filter_bar.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/folder_bar_layout.dart';

import 'fakes/fake_webview.dart';

/// The bar over a tablet's list: the folder's name, and the list's All /
/// Unread / Filter and By Date beside it where the list is wide enough,
/// under it where it is not.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Size size, {
    ReadingPanePosition pane = ReadingPanePosition.bottom,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ],
    );
    addTearDown(c.dispose);
    c.read(displayProvider.notifier).setReadingPane(pane);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  RenderFolderBar bar(WidgetTester tester) =>
      tester.renderObject<RenderFolderBar>(find.byType(FolderBarLayout));

  double middleOf(WidgetTester tester, Finder f) => tester.getCenter(f).dy;

  // The bar's own, not the ribbon's.
  final search = find.descendant(
    of: find.byType(FolderBarLayout),
    matching: find.byTooltip('Search'),
  );

  testWidgets('a wide list has the filters beside the folder, on one line',
      (tester) async {
    await pump(tester, const Size(1400, 900));

    expect(bar(tester).oneLine, isTrue);
    final line = middleOf(tester, search);
    expect(middleOf(tester, find.text('All')), closeTo(line, 4));
    expect(middleOf(tester, find.text('By Date')), closeTo(line, 4));
    // In the folder's bar, not a bar of their own over the list.
    expect(find.byType(ListFilterBar), findsNothing);
    expect(find.byType(ListFilterChoices), findsOneWidget);
    // After the name, and By Date before Search.
    expect(
      tester.getTopLeft(find.text('All')).dx,
      greaterThan(tester.getTopRight(find.text('Inbox').first).dx),
    );
    expect(
      tester.getTopRight(find.text('By Date')).dx,
      lessThan(tester.getTopLeft(search).dx),
    );
  });

  testWidgets('beside the reading pane they go under it, as two lines',
      (tester) async {
    await pump(tester, const Size(1400, 900), pane: ReadingPanePosition.right);

    expect(bar(tester).oneLine, isFalse);
    final first = middleOf(tester, search);
    expect(middleOf(tester, find.text('All')), greaterThan(first + 20));
    expect(
      middleOf(tester, find.text('By Date')),
      closeTo(middleOf(tester, find.text('All')), 4),
    );
    expect(find.byType(ListFilterBar), findsNothing);
  });

  testWidgets('selecting, the selection bar has their place', (tester) async {
    final c = await pump(tester, const Size(1400, 900));
    final folder = c.read(effectiveSelectedFolderIdProvider)!;
    final first = c.read(sortedMessagesProvider(folder)).first;

    c.read(selectedMessageIdsProvider.notifier).toggle(first.id);
    await tester.pumpAndSettle();
    expect(find.byType(ListFilterChoices), findsNothing);
    expect(find.text('By Date'), findsNothing);

    c.read(selectedMessageIdsProvider.notifier).clear();
    await tester.pumpAndSettle();
    expect(find.byType(ListFilterChoices), findsOneWidget);
  });

  testWidgets('large text moves them under the name rather than cutting',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester, const Size(1400, 900));

    expect(bar(tester).oneLine, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone keeps them over the list', (tester) async {
    await pump(tester, const Size(400, 900));

    expect(find.byType(FolderBarLayout), findsNothing);
    expect(find.byType(ListFilterBar), findsOneWidget);
    expect(find.text('By Date'), findsOneWidget);
  });
}
