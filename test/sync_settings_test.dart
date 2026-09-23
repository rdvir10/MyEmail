import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/sync/background_worker.dart';
import 'package:myemail/data/sync/sync_state_store.dart';
import 'package:myemail/domain/sync_prefs.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_providers.dart';
import 'package:myemail/ui/settings/notifications_screen.dart';
import 'package:myemail/ui/settings/sync_screen.dart';

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  late MemorySyncStateStore state;
  late FakeMailNotifier notifier;
  late FakeBackgroundScheduler scheduler;
  late MailEngine engine;

  setUp(() {
    state = MemorySyncStateStore();
    notifier = FakeMailNotifier();
    scheduler = FakeBackgroundScheduler();
    engine = SampleMailEngine();
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        mailEngineProvider.overrideWithValue(engine),
        mailNotifierProvider.overrideWithValue(notifier),
        syncStateStoreProvider.overrideWithValue(state),
        backgroundSchedulerProvider.overrideWithValue(scheduler),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<ProviderContainer> pump(WidgetTester tester, Widget screen) async {
    _tall(tester);
    final c = container();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  group('sync and notifications are separate settings', () {
    test('sync is off by default and notifications are not its switch', () {
      const prefs = SyncPrefs();
      expect(prefs.syncs, isFalse);
      expect(prefs.notify, isTrue,
          reason: 'someone turning sync on almost always wants to be told');
      expect(prefs.notifiesFor('a'), isFalse,
          reason: 'but nothing can announce what nothing is finding');
    });

    test('turning notifications off leaves sync running', () async {
      final c = container();
      await c.read(syncSettingsProvider.future);
      await c.read(syncSettingsProvider.notifier).setMode(SyncMode.periodic);

      await c.read(syncSettingsProvider.notifier).setNotify(false);

      final saved = await state.readPrefs();
      expect(saved.syncs, isTrue, reason: 'the app still keeps itself current');
      expect(saved.notify, isFalse);
      expect(scheduler.last?.syncs, isTrue,
          reason: 'and the schedule is still in place');
    });

    test('turning sync off leaves the notification preference alone', () async {
      final c = container();
      await c.read(syncSettingsProvider.future);
      await c.read(syncSettingsProvider.notifier).setMode(SyncMode.periodic);

      await c.read(syncSettingsProvider.notifier).setMode(SyncMode.off);

      final saved = await state.readPrefs();
      expect(saved.notify, isTrue,
          reason: 'turning sync back on should not need the switch set again');
      expect(scheduler.last?.syncs, isFalse);
      expect(notifier.batches, isEmpty, reason: 'and what was showing is gone');
    });

    test('the occasional mode asks, since it is to announce what it finds',
        () async {
      // Notifications are on from the start. Never asked, a new phone
      // dropped every one of them without a word.
      notifier.permitted = false;
      final c = container();
      await c.read(syncSettingsProvider.future);

      final ok = await c
          .read(syncSettingsProvider.notifier)
          .setMode(SyncMode.periodic);

      expect(notifier.permissionRequests, 1);
      expect(ok, isTrue, reason: 'a no stops the announcing, not the syncing');
      expect((await state.readPrefs()).mode, SyncMode.periodic);
    });

    test('but not when it is only to keep the app current', () async {
      final c = container();
      await c.read(syncSettingsProvider.future);
      await c.read(syncSettingsProvider.notifier).setNotify(false);
      notifier.permissionRequests = 0;

      await c.read(syncSettingsProvider.notifier).setMode(SyncMode.periodic);

      expect(notifier.permissionRequests, 0);
    });

    test('a foreground mode does ask, because Android insists on a permanent '
        'notification', () async {
      notifier.permitted = false;
      final c = container();
      await c.read(syncSettingsProvider.future);

      final ok = await c
          .read(syncSettingsProvider.notifier)
          .setMode(SyncMode.realtime);

      expect(ok, isFalse);
      expect((await state.readPrefs()).mode, SyncMode.off,
          reason: 'refused means nothing changed');
    });

    test('a refused notification switch stays off', () async {
      notifier.permitted = false;
      final c = container();
      await c.read(syncSettingsProvider.future);
      await c.read(syncSettingsProvider.notifier).setMode(SyncMode.periodic);

      expect(
        await c.read(syncSettingsProvider.notifier).setNotify(true),
        isFalse,
      );
    });

    test('the interval is saved and rescheduled', () async {
      final c = container();
      await c.read(syncSettingsProvider.future);
      await c.read(syncSettingsProvider.notifier).setInterval(60);

      expect((await state.readPrefs()).intervalMinutes, 60);
      expect(scheduler.last?.interval, const Duration(minutes: 60));
    });

    test('muting one account leaves the rest notified', () async {
      final c = container();
      await c.read(syncSettingsProvider.future);
      await c.read(syncSettingsProvider.notifier).setMode(SyncMode.periodic);
      await c
          .read(syncSettingsProvider.notifier)
          .setAccountMuted('acct-personal', true);

      final saved = await state.readPrefs();
      expect(saved.notifiesFor('acct-personal'), isFalse);
      expect(saved.notifiesFor('acct-side'), isTrue);
    });

    test('settings survive a reload, because they are read back from the store',
        () async {
      final first = container();
      await first.read(syncSettingsProvider.future);
      await first.read(syncSettingsProvider.notifier).setInterval(180);

      final second = container();
      expect(
        (await second.read(syncSettingsProvider.future)).intervalMinutes,
        180,
      );
    });
  });

  group('Sync screen', () {
    testWidgets('offers every mode with its battery cost', (tester) async {
      await pump(tester, const SyncScreen());

      for (final mode in SyncMode.values) {
        expect(find.text(mode.label), findsOneWidget, reason: mode.name);
        expect(find.text(mode.cost), findsOneWidget, reason: mode.name);
      }
    });

    testWidgets('the interval only appears for the mode it applies to',
        (tester) async {
      final c = await pump(tester, const SyncScreen());
      expect(find.text('How often'), findsNothing,
          reason: 'off has no interval');

      await tester.tap(find.text(SyncMode.periodic.label));
      await tester.pumpAndSettle();
      expect(find.text('How often'), findsOneWidget);

      await c.read(syncSettingsProvider.notifier).setMode(SyncMode.realtime);
      await tester.pumpAndSettle();
      expect(find.text('How often'), findsNothing,
          reason: 'push has no interval either');
    });

    testWidgets('choosing a mode saves it and reschedules', (tester) async {
      await pump(tester, const SyncScreen());

      await tester.tap(find.text(SyncMode.frequent.label));
      await tester.pumpAndSettle();

      expect((await state.readPrefs()).mode, SyncMode.frequent);
      expect(scheduler.last?.mode, SyncMode.frequent);
    });

    testWidgets('a foreground mode warns about the permanent notification',
        (tester) async {
      await pump(tester, const SyncScreen());

      await tester.tap(find.text(SyncMode.realtime.label));
      await tester.pumpAndSettle();

      expect(find.textContaining('permanent'), findsWidgets);
    });

    testWidgets('off says plainly that nothing will reach you', (tester) async {
      await pump(tester, const SyncScreen());
      expect(find.textContaining('No background work'), findsOneWidget);
    });

    testWidgets('a refused foreground mode says why and changes nothing',
        (tester) async {
      notifier.permitted = false;
      await pump(tester, const SyncScreen());

      await tester.tap(find.text(SyncMode.realtime.label));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('needs notification permission'),
        findsOneWidget,
      );
      expect((await state.readPrefs()).mode, SyncMode.off);
    });
  });

  group('Notifications screen', () {
    testWidgets('says that off still syncs', (tester) async {
      await pump(tester, const NotificationsScreen());
      expect(
        find.textContaining('still syncs in the background'),
        findsOneWidget,
      );
    });

    testWidgets('warns when it is on but nothing is syncing', (tester) async {
      // An on switch above a phone that will stay silent is a lie.
      await pump(tester, const NotificationsScreen());

      expect(
        find.textContaining('Nothing is checking for mail'),
        findsOneWidget,
      );
      expect(find.text('Set up sync'), findsOneWidget);
    });

    testWidgets('the warning goes once sync is on', (tester) async {
      state = MemorySyncStateStore(
        prefs: const SyncPrefs(mode: SyncMode.periodic),
      );
      await pump(tester, const NotificationsScreen());

      expect(find.textContaining('Nothing is checking for mail'), findsNothing);
    });

    testWidgets('a blocked OS permission is called out rather than hidden',
        (tester) async {
      state = MemorySyncStateStore(
        prefs: const SyncPrefs(mode: SyncMode.periodic),
      );
      notifier.permitted = false;
      await pump(tester, const NotificationsScreen());

      expect(find.textContaining('Android is blocking'), findsOneWidget);
    });

    testWidgets('turning it off silences what is showing', (tester) async {
      state = MemorySyncStateStore(
        prefs: const SyncPrefs(mode: SyncMode.periodic),
      );
      await pump(tester, const NotificationsScreen());

      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();

      expect((await state.readPrefs()).notify, isFalse);
      expect(notifier.batches, isEmpty);
    });

    testWidgets('turning an account off mutes it', (tester) async {
      state = MemorySyncStateStore(
        prefs: const SyncPrefs(mode: SyncMode.periodic),
      );
      await pump(tester, const NotificationsScreen());

      final account = find.byType(SwitchListTile).at(1);
      await tester.ensureVisible(account);
      await tester.pumpAndSettle();
      await tester.tap(account);
      await tester.pumpAndSettle();

      expect((await state.readPrefs()).mutedAccountIds, isNotEmpty);
    });

    testWidgets('says a muted account still syncs', (tester) async {
      await pump(tester, const NotificationsScreen());
      expect(find.textContaining('muted account still syncs'), findsOneWidget);
    });
  });
}
