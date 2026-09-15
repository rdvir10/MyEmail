import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/ui/messages/reading_pane.dart';
import 'package:mailtree/ui/shell/app_shell.dart';

void main() {
  testWidgets('Pixel Tablet landscape gets the three-pane layout',
      (tester) async {
    // 2560x1600 at density 2.0 = 1280x800 logical, above wideBreakpoint 1200.
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AppShell())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search folders'), findsOneWidget, reason: 'tree pane');
    expect(find.text('Search mail'), findsOneWidget, reason: 'list pane');
    expect(find.textContaining('Select a message'), findsOneWidget,
        reason: 'reading pane');
    expect(find.byTooltip('Open navigation menu'), findsNothing);
  });

  testWidgets('Pixel Tablet portrait gets tree and list, not a drawer',
      (tester) async {
    // Rotated: 1600x2560 physical = 800x1280 logical. An 840dp breakpoint
    // put an 11-inch tablet on the phone layout; 600dp is why it does not.
    tester.view.physicalSize = const Size(1600, 2560);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AppShell())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search folders'), findsOneWidget,
        reason: 'the tree is a pane, not behind a hamburger');
    expect(find.byTooltip('Open navigation menu'), findsNothing);
    expect(find.byType(ReadingPane), findsNothing,
        reason: '800dp is below the 1200dp three-pane breakpoint');
  });

  testWidgets('a phone in portrait still gets the drawer', (tester) async {
    // Pixel 7: 1080x2400 at 2.625 = 411x914 logical.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AppShell())),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    expect(find.text('Search folders'), findsNothing,
        reason: '411dp is below 600dp, so the tree stays in the drawer');
  });
}
