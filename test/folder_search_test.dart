import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/put_away_providers.dart';
import 'package:myemail/ui/folder_tree/folder_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// The box above the folders and the filter it drives say the same thing,
/// whatever happened to the pane in between.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late StreamController<void> putAway;

  Future<ProviderContainer> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    putAway = StreamController<void>.broadcast();
    addTearDown(putAway.close);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      appPutAwayProvider.overrideWithValue(putAway.stream),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: AppShell()),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  Finder box() => find.widgetWithText(TextField, 'Search folders');

  String inBox(WidgetTester tester) =>
      tester.widget<TextField>(box()).controller!.text;

  testWidgets('on the phone, the drawer opens again on the search it was '
      'left with', (tester) async {
    // Choosing a folder closes the drawer, which throws its contents away.
    // It came back with an empty box over a tree still showing only the
    // folders that matched, so most of them seemed to be gone.
    final c = await pump(tester, const Size(400, 900));
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.enterText(box(), 'fam');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FolderTile, 'Family').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();

    expect(c.read(folderSearchQueryProvider), 'fam');
    expect(inBox(tester), 'fam');
  });

  testWidgets('on the tablet, put away, the box is emptied with the filter',
      (tester) async {
    final c = await pump(tester, const Size(1400, 900));
    await tester.enterText(box(), 'fam');
    await tester.pumpAndSettle();

    putAway.add(null);
    await tester.pumpAndSettle();

    expect(c.read(folderSearchQueryProvider), isEmpty);
    expect(inBox(tester), isEmpty);
  });
}
