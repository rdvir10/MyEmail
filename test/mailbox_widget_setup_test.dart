import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/data/widget/widget_state_store.dart';
import 'package:myemail/domain/mailbox_counts.dart';
import 'package:myemail/state/folder_tree.dart' show kUnifiedInboxId;
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/widget_providers.dart';
import 'package:myemail/ui/shell/mailbox_widget_keeper.dart';
import 'package:myemail/ui/widgets/mailbox_widget_setup.dart';

/// Placing a widget: being asked whose mail, which folder, and how it should
/// look, in that order.
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
    // Tall, so a step's whole list is built and the test is not accidentally
    // about how much fits on a phone.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

  group('step one: whose mail', () {
    testWidgets('lists the accounts, not their folders', (tester) async {
      // Every folder of every account in one list is how this started out,
      // and with three accounts it is hundreds of rows.
      final c = await pumpSetup(tester);

      for (final account in c.read(accountsProvider).value!) {
        expect(find.text(account.displayName), findsOneWidget);
      }
      expect(find.text('Inbox'), findsNothing);
    });

    testWidgets('offers the accounts added together', (tester) async {
      await pumpSetup(tester);

      expect(find.text('All inboxes'), findsOneWidget);
    });
  });

  group('step two: which folder', () {
    Future<void> openAnAccount(WidgetTester tester, ProviderContainer c) async {
      final account = c.read(accountsProvider).value!.first;
      await tester.tap(find.text(account.displayName));
      await tester.pumpAndSettle();
    }

    Future<void> expand(WidgetTester tester, String folder) async {
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, folder),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('is a tree, closed to begin with', (tester) async {
      final c = await pumpSetup(tester);
      await openAnAccount(tester, c);

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Family'), findsOneWidget);
      // A child folder, behind its parent until the parent is opened.
      expect(find.text('Photos'), findsNothing);
    });

    testWidgets('a parent opens to show what is under it', (tester) async {
      final c = await pumpSetup(tester);
      await openAnAccount(tester, c);

      await expand(tester, 'Family');

      expect(find.text('Photos'), findsOneWidget);
    });

    testWidgets('a child sits further in than its parent', (tester) async {
      // Indentation is the whole difference between a tree and a list.
      final c = await pumpSetup(tester);
      await openAnAccount(tester, c);
      await expand(tester, 'Family');

      expect(
        tester.getTopLeft(find.text('Photos')).dx,
        greaterThan(tester.getTopLeft(find.text('Family')).dx),
      );
    });

    testWidgets('folders with no children still line up', (tester) async {
      // The arrow column is held open, or the names of childless folders
      // slide left and the tree reads as ragged.
      final c = await pumpSetup(tester);
      await openAnAccount(tester, c);

      expect(
        tester.getTopLeft(find.text('Inbox')).dx,
        tester.getTopLeft(find.text('Family')).dx,
      );
    });
  });

  group('step three: how it should look', () {
    Future<void> reachTheLastStep(WidgetTester tester) async {
      await tester.tap(find.text('All inboxes'));
      await tester.pumpAndSettle();
    }

    testWidgets('offers all messages or only unread', (tester) async {
      await pumpSetup(tester);
      await reachTheLastStep(tester);

      expect(find.text('All messages'), findsOneWidget);
      expect(find.text('Unread only'), findsOneWidget);
    });

    testWidgets('finishing writes the mailbox, the mode and both counts',
        (tester) async {
      await pumpSetup(tester);
      await reachTheLastStep(tester);

      await tester.tap(find.text('Unread only'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(store.mailboxes['42']?.folderId, kUnifiedInboxId);
      expect(store.mailboxes['42']?.counts, WidgetCount.unread);
      expect(surface.values['widget.42.mode'], 'unread');
      // Both are written whatever the mode, so changing it later redraws
      // without waiting for a sync.
      expect(surface.values['count.$kUnifiedInboxId.unread'], isA<int>());
      expect(surface.values['count.$kUnifiedInboxId.total'], isA<int>());
    });

    testWidgets('a name of its own is kept and sent to the widget',
        (tester) async {
      await pumpSetup(tester);
      await reachTheLastStep(tester);

      await tester.enterText(find.byType(TextField), 'Hadco');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(store.mailboxes['42']?.label, 'Hadco');
      expect(surface.values['widget.42.label'], 'Hadco');
    });

    testWidgets('an empty name means the folder and the account',
        (tester) async {
      await pumpSetup(tester);
      await reachTheLastStep(tester);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(store.mailboxes['42']?.label, isNull);
      expect(surface.values['widget.42.label'], isNull);
    });


    testWidgets('a colour can be chosen, and orange is where it starts',
        (tester) async {
      await pumpSetup(tester);
      await reachTheLastStep(tester);

      await tester.tap(find.byTooltip('Teal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(store.mailboxes['42']?.colour, WidgetColour.teal);
      // argb, not value: what Android is sent has to fit in a Java int.
      expect(surface.values['widget.42.colour'], WidgetColour.teal.argb);
    });

    testWidgets('left alone, it stays the colour of the app', (tester) async {
      await pumpSetup(tester);
      await reachTheLastStep(tester);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(store.mailboxes['42']?.colour, WidgetColour.orange);
    });

    testWidgets('nothing is remembered until the last step', (tester) async {
      // Backing out has to leave no half-configured widget behind, which is
      // also what Android does with the placement itself.
      await pumpSetup(tester);
      await reachTheLastStep(tester);

      expect(store.mailboxes, isEmpty);
      expect(surface.values, isEmpty);
    });
  });

  group('the mark that "new" counts from', () {
    Future<void> pumpKeeper(WidgetTester tester) async {
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
    }

    testWidgets('opening the app moves it', (tester) async {
      await pumpKeeper(tester);

      expect(store.openedAt, isNotNull);
    });

    testWidgets('and so does leaving', (tester) async {
      // Otherwise "new since you last looked" would count the mail you read
      // just before putting the phone down.
      await pumpKeeper(tester);
      store.openedAt = null;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();

      expect(store.openedAt, isNotNull);
    });
  });
}
