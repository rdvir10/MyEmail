import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/data/widget/widget_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/mailbox_counts.dart';
import 'package:myemail/state/folder_tree.dart' show kUnifiedInboxId;
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/widget_providers.dart';
import 'package:myemail/ui/shell/mailbox_widget_keeper.dart';
import 'package:myemail/ui/settings/home_widgets_screen.dart';
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

  testWidgets('changed from Settings, Done comes back to the list',
      (tester) async {
    // The way back was a test that was always true, so nothing closed and
    // the screen sat on "Saving…".
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store.mailboxes['7'] = const WidgetMailbox(
      folderId: kUnifiedInboxId,
      label: 'On the kitchen tablet',
    );
    // Android's answer to which widgets are on the home screen.
    const channel = MethodChannel('mailtree/widget');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => <String>['7']);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container(),
        child: const MaterialApp(home: HomeWidgetsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('On the kitchen tablet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All inboxes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.byType(MailboxWidgetSetup), findsNothing);
    expect(find.text('Saving…'), findsNothing);
    expect(find.byType(HomeWidgetsScreen), findsOneWidget);
  });

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


    testWidgets('a colour can be chosen', (tester) async {
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

    testWidgets('All inboxes, left alone, is orange: it has no account colour',
        (tester) async {
      await pumpSetup(tester);
      await reachTheLastStep(tester);

      expect(find.byTooltip('Same as Personal'), findsNothing);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(surface.values['widget.42.colour'], WidgetColour.orange.argb);
    });

    Future<void> reachAnInbox(WidgetTester tester) async {
      await tester.tap(find.text('Personal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inbox'));
      await tester.pumpAndSettle();
    }

    testWidgets("an account's widget starts in the account's colour",
        (tester) async {
      await pumpSetup(tester);
      await reachAnInbox(tester);

      expect(find.byTooltip('Same as Personal'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      // Null, not a copy of the colour, so it follows a recolour later.
      expect(store.mailboxes['42']?.colour, isNull);
      expect(surface.values['widget.42.colour'], 0xFF0F6CBD.toSigned(32));
    });

    testWidgets("a colour picked over the account's is kept", (tester) async {
      await pumpSetup(tester);
      await reachAnInbox(tester);

      await tester.tap(find.byTooltip('Teal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(store.mailboxes['42']?.colour, WidgetColour.teal);
      expect(surface.values['widget.42.colour'], WidgetColour.teal.argb);
    });

    testWidgets("and can be taken back to the account's", (tester) async {
      await pumpSetup(tester);
      await reachAnInbox(tester);

      await tester.tap(find.byTooltip('Teal'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Same as Personal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(store.mailboxes['42']?.colour, isNull);
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

    testWidgets('coming back counts once, and leaving syncs nothing',
        (tester) async {
      // Each resume and pause ran the refresh twice, and each run synced
      // every widget folder over the network alongside the app's own sync.
      final engine = _CountingEngine();
      final inbox = (await tester.runAsync(
        () => engine.loadFolders('acct-personal'),
      ))!
          .firstWhere((f) => f.role == FolderRole.inbox)
          .id;
      store.mailboxes['7'] = WidgetMailbox(folderId: inbox);
      const channel = MethodChannel('mailtree/widget');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => <String>['7']);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final c = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          homeScreenSurfaceProvider.overrideWithValue(surface),
          widgetStateStoreProvider.overrideWithValue(store),
          mailEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: MailboxWidgetKeeper(child: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      engine.synced.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(engine.synced, [inbox], reason: 'one refresh, not two');

      engine.synced.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(engine.synced, isEmpty,
          reason: 'on the way out the counts come from the cache');
      expect(surface.values['widget.7.folder'], inbox);
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

/// Sample mail that notes each folder it is asked to sync.
class _CountingEngine extends SampleMailEngine {
  final List<String> synced = [];

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) {
    synced.add(folderId);
    return super.loadMessages(folderId, offset: offset, limit: limit);
  }
}
