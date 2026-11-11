import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/data/widget/mailbox_widgets.dart';
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

  group('what "new" counts from', () {
    // The keeper's own clock, which the test moves; DateTime.now() does not
    // follow the test's.
    late DateTime clock;
    late _CountingEngine engine;
    late String inbox;
    late ProviderContainer c;

    setUp(() {
      clock = DateTime.now();
      MailboxWidgetKeeper.now = () => clock;
    });
    tearDown(() => MailboxWidgetKeeper.now = DateTime.now);

    const away = [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ];
    const back = [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ];

    void go(WidgetTester tester, List<AppLifecycleState> states) {
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    /// Long enough for the sample engine's delays and a redraw.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// A widget on the Personal Inbox, its mail already fetched once so the
    /// cache has something to count, and the app opened on All inboxes.
    Future<void> pumpKeeper(WidgetTester tester) async {
      engine = _CountingEngine();
      inbox = (await tester.runAsync(
        () => engine.loadFolders('acct-personal'),
      ))!
          .firstWhere((f) => f.role == FolderRole.inbox)
          .id;
      await tester.runAsync(
        () => engine.loadMessages(inbox, limit: MailboxWidgets.window),
      );
      store.mailboxes['7'] = WidgetMailbox(folderId: inbox);
      const channel = MethodChannel('mailtree/widget');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => <String>['7']);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      c = ProviderContainer(
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
      await settle(tester);
      // And the redraw the folders arriving asked for.
      await tester.pump(MailboxWidgetKeeper.settle);
      await settle(tester);
      engine.synced.clear();
    }

    testWidgets('the first opening sets where it starts', (tester) async {
      await pumpKeeper(tester);

      expect(store.openedAt, isNotNull);
    });

    testWidgets('and opening the app again does not move it', (tester) async {
      // It was the one mark every widget counted from, moved each time the
      // app came to the front, which took every widget to zero.
      store.openedAt = DateTime.utc(2000);

      await pumpKeeper(tester);

      expect(store.openedAt, DateTime.utc(2000));
    });

    testWidgets('a mailbox chosen is looked at, and redrawn at once',
        (tester) async {
      store.openedAt = DateTime.utc(2000);
      await pumpKeeper(tester);
      expect(c.read(effectiveSelectedFolderIdProvider), kUnifiedInboxId);
      expect(surface.values['count.$inbox.new'], greaterThan(0));
      final redraws = surface.redraws;

      c.read(selectedFolderIdProvider.notifier).select(inbox);
      await settle(tester);

      expect(store.seen.keys, [inbox],
          reason: 'All inboxes was on screen for no time at all');
      expect(surface.values['count.$inbox.new'], 0);
      expect(surface.redraws, redraws + 1,
          reason: 'without waiting for the app to go away');
    });

    testWidgets('the one the app opens on, left at once, is not',
        (tester) async {
      await pumpKeeper(tester);

      go(tester, away);
      await settle(tester);

      expect(store.seen, isEmpty);
    });

    testWidgets('but one it stays on a moment is, as it goes', (tester) async {
      await pumpKeeper(tester);

      clock = clock.add(const Duration(seconds: 2));
      go(tester, away);
      await settle(tester);

      expect(store.seen, {kUnifiedInboxId: clock.toUtc()});
    });

    testWidgets('a widget tapped to come back is the mailbox looked at',
        (tester) async {
      // The app comes back on whatever it was left showing, and the tap
      // moves it a moment later. That moment was a look at every Inbox.
      await pumpKeeper(tester);
      clock = clock.add(const Duration(minutes: 1));
      go(tester, away);
      await settle(tester);
      final left = store.seen[kUnifiedInboxId];
      expect(left, isNotNull);

      clock = clock.add(const Duration(hours: 1));
      go(tester, back);
      // What the tap does once the app is in front.
      c.read(selectedFolderIdProvider.notifier).select(inbox);
      await settle(tester);

      expect(store.seen[kUnifiedInboxId], left);
      expect(store.seen[inbox], clock.toUtc());
    });

    testWidgets('neither leaving nor coming back syncs anything',
        (tester) async {
      // Each resume synced every widget's folder over the network, alongside
      // the app's own sync, for a widget nobody can see while the app is in
      // front.
      await pumpKeeper(tester);

      go(tester, away);
      await settle(tester);
      expect(engine.synced, isEmpty,
          reason: 'on the way out the counts come from the cache');
      expect(surface.values['widget.7.folder'], inbox);

      go(tester, back);
      await settle(tester);
      expect(engine.synced, isEmpty);
    });

    testWidgets('focus back without going away moves nothing',
        (tester) async {
      // The notification shade pushed back up, or the app tapped again in
      // split screen: the mail was on screen all along.
      await pumpKeeper(tester);
      clock = clock.add(const Duration(minutes: 1));

      go(tester, const [
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await settle(tester);

      expect(store.seen, isEmpty);
      expect(engine.synced, isEmpty);
    });

    testWidgets('counts that move while the app is used are redrawn',
        (tester) async {
      // So the widget is right by the time the home screen is back, rather
      // than a moment after.
      await pumpKeeper(tester);
      final redraws = surface.redraws;
      // Something for the redraw to change.
      surface.values.remove('widget.7.mode');

      c.read(foldersProvider.notifier).countUnread(inbox, -1);
      await tester.pump(MailboxWidgetKeeper.settle ~/ 2);
      expect(surface.redraws, redraws, reason: 'left to settle first');

      await tester.pump(MailboxWidgetKeeper.settle);
      await settle(tester);
      expect(surface.redraws, redraws + 1);
      expect(surface.values['widget.7.mode'], 'all');
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
