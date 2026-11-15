import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/sync/background_sync.dart';
import 'package:myemail/data/sync/sync_state_store.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/sync_prefs.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_providers.dart';
import 'package:myemail/ui/messages/person_card.dart';
import 'package:myemail/ui/settings/account_notifications_screen.dart';
import 'package:myemail/ui/settings/notifications_screen.dart';

import 'fakes/fake_imap_transport.dart';

/// Do Not Disturb (#44), and VIPs and folders besides the Inbox (#45): what
/// is announced, worked out in the background pass and set on screen.
void main() {
  group('Do Not Disturb', () {
    test('until a time, every evening, and on the days off', () {
      final hour = QuietRule(until: DateTime(2026, 10, 28, 10));
      expect(hour.isQuiet(DateTime(2026, 10, 28, 9, 30)), isTrue);
      expect(hour.isQuiet(DateTime(2026, 10, 28, 10, 1)), isFalse);

      const evenings = QuietRule(evenings: true, from: 18, to: 8);
      expect(evenings.isQuiet(DateTime(2026, 10, 28, 22)), isTrue);
      expect(evenings.isQuiet(DateTime(2026, 10, 28, 7, 59)), isTrue);
      expect(evenings.isQuiet(DateTime(2026, 10, 28, 12)), isFalse);

      const office = QuietRule(evenings: true, from: 9, to: 17);
      expect(office.isQuiet(DateTime(2026, 10, 28, 10)), isTrue);
      expect(office.isQuiet(DateTime(2026, 10, 28, 18)), isFalse);

      const weekends = QuietRule(
          weekends: true, daysOff: {DateTime.friday, DateTime.saturday});
      expect(weekends.isQuiet(DateTime(2026, 10, 30, 12)), isTrue,
          reason: 'a Friday off');
      expect(weekends.isQuiet(DateTime(2026, 11, 1, 12)), isFalse);
      expect(const QuietRule().isEmpty, isTrue);
    });

    test('kept with the rest, and read back whatever is wrong with it', () {
      final prefs = const SyncPrefs(mode: SyncMode.periodic)
          .withQuiet(
              'a',
              QuietRule(
                  until: DateTime(2026, 10, 28, 10),
                  evenings: true,
                  from: 20,
                  to: 7))
          .copyWith(
            vips: {'boss@example.com'},
            vipOnlyAccountIds: {'b'},
            watchedFolderIds: {'a:Work'},
          );

      expect(SyncPrefs.fromJson(prefs.toJson()), prefs);
      expect(prefs.quietFor('a', DateTime(2026, 10, 28, 9)), isTrue);
      expect(prefs.announcesFrom('b', 'Boss@Example.com'), isTrue);
      expect(prefs.announcesFrom('b', 'other@example.com'), isFalse);
      expect(prefs.announcesFrom('a', 'other@example.com'), isTrue);
      expect(
        SyncPrefs.fromJson({
          'mode': 'periodic',
          'quiet': {
            'a': {'from': 99, 'evenings': 'yes'},
          },
          'vips': 7,
        }).quiet['a'],
        const QuietRule(),
      );
      expect(prefs.withQuiet('a', const QuietRule()).quiet, isEmpty,
          reason: 'nothing set is no rule');
    });

    // Quiet while you are in a meeting (#70).
    test('while in a meeting: off at first, kept, and a rule of its own',
        () {
      expect(const QuietRule().meetings, isFalse);
      expect(const QuietRule().toJson(), isNot(contains('meetings')),
          reason: 'kept as before for anyone who does not switch it on');
      const meetings = QuietRule(meetings: true);
      expect(meetings.isEmpty, isFalse);
      expect(meetings.isQuiet(DateTime(2026, 10, 28, 10)), isFalse,
          reason: 'not quiet by the clock');
      final prefs =
          const SyncPrefs(mode: SyncMode.periodic).withQuiet('a', meetings);
      expect(SyncPrefs.fromJson(prefs.toJson()), prefs);
      expect(prefs.quietInMeetings('a'), isTrue);
      expect(prefs.quietInMeetings('b'), isFalse);
      expect(
          SyncPrefs.fromJson({
            'mode': 'periodic',
            'quiet': {
              'a': {'meetings': 'yes'},
            },
          }).quietInMeetings('a'),
          isFalse);
      expect(meetings.copyWith(meetings: false).isEmpty, isTrue);
    });
  });

  group('in the background pass', () {
    late FakeImapTransport server;
    late MemorySyncStateStore state;
    late FakeMailNotifier notifier;
    late CachedImapEngine engine;
    late Account account;
    final now = DateTime(2026, 9, 14, 9);

    setUp(() async {
      server = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox)
        ..folder('Work');
      state = MemorySyncStateStore(
        prefs: const SyncPrefs(mode: SyncMode.periodic),
      );
      notifier = FakeMailNotifier();
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
      );
      account = await engine.addAccount(
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
    });

    Future<BackgroundSyncReport> pass() => BackgroundSync(
          engine: engine,
          notifier: notifier,
          state: state,
          clock: () => now,
        ).run();

    void deliver(String subject,
        {String folder = 'INBOX', String from = 'someone@example.com'}) {
      server.folder(folder).deliver(
            subject: subject,
            from: from,
            date: now.subtract(const Duration(minutes: 5)),
          );
    }

    Future<void> prefs(SyncPrefs Function(SyncPrefs p) change) async =>
        state.writePrefs(change(await state.readPrefs()));

    /// The subjects announced: each notification's body starts with it.
    List<String> posted() =>
        [for (final n in notifier.posted) n.body.split('\n').first];

    test('quiet: synced, and not announced, then or after', () async {
      await pass(); // The first look only marks where it got to.
      await prefs((p) => p.withQuiet(
          account.id, QuietRule(until: now.add(const Duration(hours: 1)))));
      deliver('While quiet');

      final quiet = await pass();
      expect(quiet.posted, 0);

      await prefs((p) => p.withQuiet(account.id, null));
      deliver('After');
      await pass();
      expect(posted(), ['After'],
          reason: 'what came in while it was quiet is not announced later');
    });

    group('while in a meeting (#70)', () {
      late bool meetingOn;
      late List<DateTime> asked;

      setUp(() {
        meetingOn = true;
        asked = [];
      });

      Future<BackgroundSyncReport> meetingPass() => BackgroundSync(
            engine: engine,
            notifier: notifier,
            state: state,
            clock: () => now,
            inMeeting: (at) async {
              asked.add(at);
              return meetingOn;
            },
          ).run();

      test('mail is posted silently, not left unannounced', () async {
        await meetingPass();
        await prefs((p) =>
            p.withQuiet(account.id, const QuietRule(meetings: true)));
        deliver('In the meeting');

        final report = await meetingPass();

        expect(report.posted, 1);
        expect(notifier.posted.single.silent, isTrue);
        expect(asked, [now]);
      });

      test('out of a meeting, mail sounds as ever', () async {
        await meetingPass();
        await prefs((p) =>
            p.withQuiet(account.id, const QuietRule(meetings: true)));
        meetingOn = false;
        deliver('After the meeting');

        await meetingPass();

        expect(notifier.posted.single.silent, isFalse);
      });

      test('switched off, nothing is looked up and mail sounds', () async {
        await meetingPass();
        deliver('Ordinary');

        await meetingPass();

        expect(notifier.posted.single.silent, isFalse);
        expect(asked, isEmpty,
            reason: 'nothing more is read for anyone without it');
      });

      test('the other quiet choices win: nothing is announced', () async {
        await meetingPass();
        await prefs((p) => p.withQuiet(
              account.id,
              QuietRule(
                meetings: true,
                until: now.add(const Duration(hours: 1)),
              ),
            ));
        deliver('Quiet hour');

        final report = await meetingPass();

        expect(report.posted, 0);
        expect(notifier.posted, isEmpty);
      });

      test('snoozed mail back in a meeting is posted silently too', () async {
        await meetingPass();
        await prefs((p) =>
            p.withQuiet(account.id, const QuietRule(meetings: true)));
        deliver('Later today');
        final message =
            (await engine.loadMessages('${account.id}:INBOX')).single;
        await engine.snooze([message.id], DateTime(2000));

        await meetingPass();

        expect(notifier.posted.single.silent, isTrue);
      });
    });

    test('VIPs only: their mail announced, and no one else\'s', () async {
      await pass();
      await prefs((p) => p.copyWith(
            vips: {'boss@example.com'},
            vipOnlyAccountIds: {account.id},
          ));
      deliver('From the boss', from: 'Boss@Example.com');
      deliver('From anyone', from: 'anyone@example.com');

      await pass();

      expect(posted(), ['From the boss']);
    });

    test('a folder chosen is checked beside the Inbox, and announced',
        () async {
      await pass();
      await prefs((p) => p.copyWith(watchedFolderIds: {'${account.id}:Work'}));
      await pass(); // Its first look marks where it got to.
      deliver('Filed', folder: 'Work');

      final report = await pass();

      expect(report.foldersScanned, 2);
      expect(posted(), ['Filed']);
    });
  });

  group('on screen', () {
    late MemorySyncStateStore state;

    Future<ProviderContainer> pump(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      state = MemorySyncStateStore(
        prefs: const SyncPrefs(mode: SyncMode.periodic),
      );
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        syncStateStoreProvider.overrideWithValue(state),
        mailNotifierProvider.overrideWithValue(FakeMailNotifier()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: home),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('an account opens its own page: Do Not Disturb, VIPs only, '
        'and folders', (tester) async {
      final c = await pump(tester, const NotificationsScreen());
      await tester.tap(find.byKey(const ValueKey('notify-account:acct-personal')));
      await tester.pumpAndSettle();
      expect(find.byType(AccountNotificationsScreen), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('quiet-hour')));
      await tester.pumpAndSettle();
      final until = (await state.readPrefs()).quiet['acct-personal']!.until!;
      expect(until.difference(DateTime.now()).inMinutes, inInclusiveRange(58, 60));
      expect(find.textContaining('Quiet until'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quiet-end')));
      await tester.pumpAndSettle();
      expect((await state.readPrefs()).quiet, isEmpty);

      await tester.tap(find.byKey(const ValueKey('quiet-evenings')));
      await tester.pumpAndSettle();
      expect((await state.readPrefs()).quiet['acct-personal']?.evenings, isTrue);

      // Quiet while you are in a meeting (#70): off at first.
      final meetings = find.byKey(const ValueKey('quiet-meetings'));
      await tester.scrollUntilVisible(meetings, 200,
          scrollable: find.byType(Scrollable).first);
      expect(tester.widget<SwitchListTile>(meetings).value, isFalse);
      await tester.tap(meetings);
      await tester.pumpAndSettle();
      expect((await state.readPrefs()).quiet['acct-personal']?.meetings,
          isTrue);
      expect(
          notificationStatus(
              await state.readPrefs(), 'acct-personal', DateTime.now(),
              use24h: true),
          contains('Quiet in meetings'));

      await tester.tap(find.byKey(const ValueKey('notify-vips')));
      await tester.pumpAndSettle();
      expect((await state.readPrefs()).vipOnlyAccountIds, {'acct-personal'});

      final travel = find.byKey(const ValueKey('watch:acct-personal:Travel'));
      await tester.scrollUntilVisible(travel, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(travel);
      await tester.pumpAndSettle();
      expect((await state.readPrefs()).watchedFolderIds,
          {'acct-personal:Travel'});
      expect(c.read(syncSettingsProvider).value?.watchedFolderIds,
          {'acct-personal:Travel'});
    });

    testWidgets('VIPs: added from a person\'s card, listed, and taken off',
        (tester) async {
      final c = await pump(
        tester,
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showPersonCard(
                context,
                ref,
                const MailAddress(email: 'Boss@Example.com', name: 'The Boss'),
                accountId: 'acct-personal',
              ),
              child: const Text('card'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('card'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('person-vip-on')));
      await tester.pumpAndSettle();

      expect((await state.readPrefs()).vips, {'boss@example.com'});
      expect(find.text('The Boss is a VIP.'), findsOneWidget);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: VipsScreen()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('boss@example.com'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect((await state.readPrefs()).vips, isEmpty);
    });
  });

  test('the sample account has the folder the screen test switches on',
      () async {
    final folders = await SampleMailEngine().loadFolders('acct-personal');
    expect(folders.map((f) => f.id), contains('acct-personal:Travel'));
  });
}
