import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mailtree/data/mail_engine.dart';
import 'package:mailtree/data/notifications/mail_notifier.dart';
import 'package:mailtree/data/sample/sample_mail_engine.dart';
import 'package:mailtree/data/sync/background_worker.dart';
import 'package:mailtree/data/sync/sync_state_store.dart';
import 'package:mailtree/domain/notification_prefs.dart';
import 'package:mailtree/state/notification_providers.dart';
import 'package:mailtree/state/providers.dart';
import 'package:mailtree/ui/settings/notifications_screen.dart';

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

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container(),
        child: const MaterialApp(home: NotificationsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('NotificationSettings', () {
    test('turning it on saves and reschedules together', () async {
      final c = container();
      await c.read(notificationSettingsProvider.future);

      final ok = await c.read(notificationSettingsProvider.notifier).setEnabled(true);

      expect(ok, isTrue);
      expect((await state.readPrefs()).enabled, isTrue);
      expect(scheduler.last?.enabled, isTrue,
          reason: 'a setting saved without rescheduling is a screen that lies');
    });

    test('refused permission leaves it off and saves nothing', () async {
      notifier.permitted = false;
      final c = container();
      await c.read(notificationSettingsProvider.future);

      final ok = await c.read(notificationSettingsProvider.notifier).setEnabled(true);

      expect(ok, isFalse);
      expect((await state.readPrefs()).enabled, isFalse);
      expect(scheduler.applied, isEmpty);
    });

    test('turning it off cancels the schedule and clears what is showing',
        () async {
      final c = container();
      await c.read(notificationSettingsProvider.future);
      await c.read(notificationSettingsProvider.notifier).setEnabled(true);
      final account = (await engine.loadAccounts()).first;
      await notifier.showNewMail(
        account: account,
        folder: (await engine.loadFolders(account.id)).first,
        notifications: const [],
      );

      await c.read(notificationSettingsProvider.notifier).setEnabled(false);

      expect(scheduler.last?.enabled, isFalse);
      expect(notifier.batches, isEmpty);
    });

    test('the interval is saved and rescheduled', () async {
      final c = container();
      await c.read(notificationSettingsProvider.future);
      await c.read(notificationSettingsProvider.notifier).setInterval(60);

      expect((await state.readPrefs()).intervalMinutes, 60);
      expect(scheduler.last?.interval, const Duration(minutes: 60));
    });

    test('muting one account leaves the rest notified', () async {
      final c = container();
      await c.read(notificationSettingsProvider.future);
      await c.read(notificationSettingsProvider.notifier).setEnabled(true);
      await c
          .read(notificationSettingsProvider.notifier)
          .setAccountMuted('acct-personal', true);

      final saved = await state.readPrefs();
      expect(saved.notifiesFor('acct-personal'), isFalse);
      expect(saved.notifiesFor('acct-side'), isTrue);
    });

    test('settings survive a reload, because they are read back from the store',
        () async {
      final first = container();
      await first.read(notificationSettingsProvider.future);
      await first.read(notificationSettingsProvider.notifier).setInterval(180);

      final second = container();
      final reloaded = await second.read(notificationSettingsProvider.future);
      expect(reloaded.intervalMinutes, 180);
    });
  });

  group('Notifications screen', () {
    testWidgets('the master switch turns the feature on', (tester) async {
      await pump(tester);

      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();

      expect((await state.readPrefs()).enabled, isTrue);
      expect(scheduler.last?.enabled, isTrue);
    });

    testWidgets('a refusal leaves the switch off and says why', (tester) async {
      notifier.permitted = false;
      await pump(tester);

      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();

      expect((await state.readPrefs()).enabled, isFalse);
      expect(find.textContaining('Android refused permission'), findsOneWidget);
    });

    testWidgets('per-account switches are inert until the feature is on',
        (tester) async {
      await pump(tester);

      final master = tester.widget<SwitchListTile>(
        find.byType(SwitchListTile).first,
      );
      expect(master.value, isFalse);
      // Every account row below it is disabled, so the screen cannot promise
      // per-account behaviour it is not delivering.
      final rows = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .skip(1);
      expect(rows, isNotEmpty);
      expect(rows.every((s) => s.onChanged == null), isTrue);
    });

    testWidgets('turning an account off mutes it', (tester) async {
      await pump(tester);
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SwitchListTile).at(1));
      await tester.pumpAndSettle();

      expect((await state.readPrefs()).mutedAccountIds, isNotEmpty);
    });

    testWidgets('a blocked OS permission is called out rather than hidden',
        (tester) async {
      state = MemorySyncStateStore(
        prefs: const NotificationPrefs(enabled: true),
      );
      notifier.permitted = false;
      await pump(tester);

      expect(find.textContaining('Android is blocking'), findsOneWidget);
    });

    testWidgets('the interval reads in words, not minutes', (tester) async {
      state = MemorySyncStateStore(
        prefs: const NotificationPrefs(enabled: true, intervalMinutes: 180),
      );
      await pump(tester);

      expect(find.text('About every 3 hours'), findsOneWidget);
    });
  });
}
