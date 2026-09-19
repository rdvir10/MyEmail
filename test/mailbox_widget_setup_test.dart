import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/data/widget/widget_state_store.dart';
import 'package:myemail/state/folder_tree.dart' show kUnifiedInboxId;
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/widget_providers.dart';
import 'package:myemail/ui/shell/mailbox_widget_keeper.dart';
import 'package:myemail/ui/widgets/mailbox_widget_setup.dart';

/// Placing a widget: being asked which mailbox, and what happens afterwards.
void main() {
  late FakeHomeScreenSurface surface;
  late MemoryWidgetStateStore store;

  setUp(() {
    surface = FakeHomeScreenSurface();
    store = MemoryWidgetStateStore();
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        homeScreenSurfaceProvider.overrideWithValue(surface),
        widgetStateStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<ProviderContainer> pumpSetup(WidgetTester tester) async {
    final c = container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: MailboxWidgetSetup(appWidgetId: '42'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('the picker lists every account and its folders', (tester) async {
    final c = await pumpSetup(tester);
    final accounts = c.read(accountsProvider).value!;

    expect(find.text('Inbox'), findsWidgets);
    for (final account in accounts) {
      // Scrolled to: a phone-sized list only builds the rows it can show,
      // and the second account is below the fold.
      await tester.scrollUntilVisible(
        find.text(account.displayName),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(account.displayName), findsWidgets, reason: account.id);
    }
  });

  testWidgets('more than one account is offered them added together',
      (tester) async {
    await pumpSetup(tester);

    expect(find.text('All inboxes'), findsOneWidget);
  });

  testWidgets('choosing a mailbox remembers it and fills the widget in',
      (tester) async {
    await pumpSetup(tester);

    await tester.tap(find.text('All inboxes'));
    await tester.pumpAndSettle();

    expect(store.mailboxes['42'], kUnifiedInboxId);
    expect(surface.values['widget.42.folder'], kUnifiedInboxId);
    expect(surface.values['count.$kUnifiedInboxId.total'], isA<int>());
    expect(surface.redraws, greaterThan(0));
  });

  testWidgets('nothing is remembered until a mailbox is chosen',
      (tester) async {
    // Backing out has to leave no half-configured widget behind, which is
    // also what Android does with the placement itself.
    await pumpSetup(tester);

    expect(store.mailboxes, isEmpty);
    expect(surface.values, isEmpty);
  });

  testWidgets('opening the app marks you as caught up', (tester) async {
    final c = container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: MailboxWidgetKeeper(child: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(store.openedAt, isNotNull);
  });

  testWidgets('leaving the app marks you as caught up too', (tester) async {
    // Otherwise "new since you last looked" would count the mail you read
    // just before putting the phone down.
    final c = container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: MailboxWidgetKeeper(child: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Cleared, so what is found afterwards can only have come from the pause.
    store.openedAt = null;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();

    expect(store.openedAt, isNotNull);
  });
}
