import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/follow_up.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/follow_ups.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_imap_transport.dart';
import 'fakes/fake_webview.dart';

/// Outlook's Follow Up (#29) and the Flagged list across every account
/// (#30): the days the choices make, Graph's flag, the sheet, reminders,
/// and the list.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  group('the days', () {
    // Wednesday 28 October 2026.
    final wednesday = DateTime(2026, 10, 28, 15);

    test('in a Monday to Friday week', () {
      expect(dueFor(FollowUpChoice.today, wednesday), DateTime(2026, 10, 28));
      expect(dueFor(FollowUpChoice.tomorrow, wednesday), DateTime(2026, 10, 29));
      expect(dueFor(FollowUpChoice.thisWeek, wednesday), DateTime(2026, 10, 30));
      expect(dueFor(FollowUpChoice.nextWeek, wednesday), DateTime(2026, 11, 6));
      expect(dueFor(FollowUpChoice.noDate, wednesday), isNull);

      final friday = DateTime(2026, 10, 30, 9);
      expect(dueFor(FollowUpChoice.thisWeek, friday), DateTime(2026, 10, 30));
      expect(dueFor(FollowUpChoice.nextWeek, friday), DateTime(2026, 11, 6));

      final saturday = DateTime(2026, 10, 31, 9);
      expect(dueFor(FollowUpChoice.thisWeek, saturday), DateTime(2026, 10, 31),
          reason: 'on a day off, this week is today');
      expect(dueFor(FollowUpChoice.nextWeek, saturday), DateTime(2026, 11, 6));
    });

    test('in a week worked from Sunday to Thursday', () {
      const week = {
        DateTime.sunday,
        DateTime.monday,
        DateTime.tuesday,
        DateTime.wednesday,
        DateTime.thursday,
      };
      expect(dueFor(FollowUpChoice.thisWeek, wednesday, workWeek: week),
          DateTime(2026, 10, 29));
      expect(dueFor(FollowUpChoice.nextWeek, wednesday, workWeek: week),
          DateTime(2026, 11, 5));
    });

    test('how a day reads beside a message', () {
      final now = DateTime(2026, 10, 28, 15);
      expect(dueLabel(DateTime(2026, 10, 28), now), 'Due today');
      expect(dueLabel(DateTime(2026, 10, 29), now), 'Due tomorrow');
      expect(dueLabel(DateTime(2026, 10, 27), now), 'Overdue');
      expect(dueLabel(DateTime(2026, 10, 30), now), 'Due Fri 30 Oct');
    });

    test('a follow-up kept on the device reads back as it was', () {
      final record = FollowUpRecord(
        accountId: 'a',
        messageId: 'a:INBOX#3',
        subject: 'Quote',
        sender: 'Dana',
        due: DateTime(2026, 10, 30),
        remindAt: DateTime(2026, 10, 29, 9),
      );
      expect(FollowUpRecord.fromJson(record.toJson()), record);
      expect(FollowUpRecord.fromJson('nonsense'), isNull);
    });
  });

  group("Graph's flag", () {
    test('a day, no day, and complete', () {
      expect(GraphRequest.followUpFlag(due: DateTime(2026, 10, 30)), {
        'flagStatus': 'flagged',
        'startDateTime': {'dateTime': '2026-10-30T12:00:00', 'timeZone': 'UTC'},
        'dueDateTime': {'dateTime': '2026-10-30T12:00:00', 'timeZone': 'UTC'},
      });
      expect(GraphRequest.followUpFlag(), {'flagStatus': 'flagged'});
      expect(
        GraphRequest.followUpFlag(
            complete: true, now: DateTime.utc(2026, 10, 28, 8)),
        {
          'flagStatus': 'complete',
          'completedDateTime': {
            'dateTime': '2026-10-28T08:00:00.000',
            'timeZone': 'UTC',
          },
        },
      );
    });

    test('a due date read as the day it means', () {
      // Noon UTC, as set here: that day on any clock near it.
      expect(
        GraphMessage.dueDayOf(
            {'dateTime': '2026-10-30T12:00:00.0000000', 'timeZone': 'UTC'}),
        DateTime(2026, 10, 30),
      );
      // In a named zone, the day it says.
      expect(
        GraphMessage.dueDayOf({
          'dateTime': '2026-10-30T00:00:00.0000000',
          'timeZone': 'Eastern Standard Time',
        }),
        DateTime(2026, 10, 30),
      );
      expect(GraphMessage.dueDayOf(null), isNull);
    });

    test('a row: flagged with its day and folder; complete is not flagged',
        () {
      final flagged = GraphMessage.fromJson({
        'id': 'm1',
        'parentFolderId': 'f-inbox',
        'flag': {
          'flagStatus': 'flagged',
          'dueDateTime': {
            'dateTime': '2026-10-30T12:00:00.0000000',
            'timeZone': 'UTC',
          },
        },
      })!;
      expect(flagged.isFlagged, isTrue);
      expect(flagged.flagDue, DateTime(2026, 10, 30));
      expect(flagged.parentFolderId, 'f-inbox');

      final done = GraphMessage.fromJson({
        'id': 'm2',
        'flag': {'flagStatus': 'complete'},
      })!;
      expect(done.isFlagged, isFalse);
    });
  });

  test("Gmail's flagged mail is asked of All Mail once, whatever its labels",
      () async {
    final server = FakeImapTransport()
      ..folder('INBOX', role: FolderRole.inbox)
      ..folder('[Gmail]/All Mail', role: FolderRole.archive)
      ..folder('[Gmail]/Spam', role: FolderRole.junk);
    final engine = CachedImapEngine(
      accountStore: MemoryAccountStore(),
      credentialStore: MemoryCredentialStore(),
      cache: MemoryCacheStore(),
      transportFactory: (_, _) => server,
    );
    final account = await engine.addAccount(
      displayName: 'P',
      emailAddress: 'p@example.com',
      provider: MailProvider.gmail,
      secret: 'abcdabcdabcdabcd',
    );
    await engine.loadFolders(account.id);
    server.folder('INBOX').deliver(subject: 'In the Inbox').isFlagged = true;
    await engine.loadMessages('${account.id}:INBOX');
    final all = server.folder('[Gmail]/All Mail');
    all.deliver(subject: 'Starred').isFlagged = true;
    all.deliver(subject: 'Plain');

    final flagged = await engine.flaggedMessages(account.id);

    expect(flagged.map((m) => m.subject), ['Starred']);
    expect(flagged.single.folderId, '${account.id}:[Gmail]/All Mail');
    expect(server.calls, contains('UID SEARCH [Gmail]/All Mail filter flagged'));
    final stored = await engine.cachedFlagged(account.id);
    expect(stored.map((m) => m.subject), ['In the Inbox'],
        reason: 'what the device has, shown before the server answers');
  });

  group('on screen', () {
    late FakeMailNotifier notifier;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      SampleMailEngine? engine,
    }) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      notifier = FakeMailNotifier();
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailNotifierProvider.overrideWithValue(notifier),
        if (engine != null) mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
          home: const AppShell(),
        ),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    Future<void> followUp(WidgetTester tester, String key) async {
      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Follow up…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('Tomorrow flags it for tomorrow, and the row says so',
        (tester) async {
      final engine = SampleMailEngine();
      final c = await pump(tester, engine: engine);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final message = c.read(selectedMessageProvider)!;

      await followUp(tester, 'follow-up-tomorrow');

      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      expect(engine.followUps.last.ids, [message.id]);
      expect(engine.followUps.last.due, tomorrow);
      expect(c.read(followUpsProvider)[followUpKey(message)]?.due, tomorrow);
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
              (w) => w is MessageTile && w.message.id == message.id),
          matching: find.text('Due tomorrow'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a reminder is set with Android for the day and the time, '
        'and Mark complete takes it back', (tester) async {
      final engine = SampleMailEngine();
      final c = await pump(tester, engine: engine);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final message = c.read(selectedMessageProvider)!;

      await followUp(tester, 'follow-up-reminder');
      // Tomorrow, the day offered, at nine, the time offered.
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final at = DateTime(now.year, now.month, now.day + 1, 9);
      final id = reminderIdFor(followUpKey(message));
      expect(notifier.reminders[id]?.at, at);
      expect(notifier.reminders[id]?.payload, message.id);
      expect(notifier.reminders[id]?.title, message.subject);
      expect(find.textContaining('Reminder set for'), findsOneWidget);
      expect(engine.followUps.single.ids, [message.id],
          reason: 'a reminder flags what it is about');

      await followUp(tester, 'follow-up-complete');

      expect(engine.followUps.last.complete, isTrue);
      expect(notifier.reminders, isEmpty);
      expect(c.read(followUpsProvider), isEmpty);
    });

    testWidgets('the flag taken off takes its day and reminder with it',
        (tester) async {
      final c = await pump(tester);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final message = c.read(selectedMessageProvider)!;
      await followUp(tester, 'follow-up-today');
      await c
          .read(followUpsProvider.notifier)
          .setReminder(message, DateTime.now().add(const Duration(hours: 2)));
      expect(notifier.reminders, hasLength(1));

      await followUp(tester, 'follow-up-clear');

      expect(c.read(followUpsProvider), isEmpty);
      expect(notifier.reminders, isEmpty);
    });

    testWidgets('Flagged, under All Inboxes: every account\'s flagged mail, '
        'soonest due first', (tester) async {
      final engine = SampleMailEngine();
      final c = await pump(tester, engine: engine);
      c.read(selectedFolderIdProvider.notifier).select(kFlaggedId);
      await tester.pumpAndSettle();

      final rows = c.read(sortedMessagesProvider(kFlaggedId));
      expect(rows, isNotEmpty);
      expect(rows.every((m) => m.isFlagged), isTrue);
      expect({for (final m in rows) m.accountId},
          containsAll(['acct-personal', 'acct-side']));

      // The oldest flagged one, due today: to the top.
      final last = rows.last;
      final today = DateTime.now();
      await tester.runAsync(() => engine.setFollowUp([last.id],
          due: DateTime(today.year, today.month, today.day)));
      c.invalidate(messagesProvider(kFlaggedId));
      await tester.pumpAndSettle();
      expect(c.read(sortedMessagesProvider(kFlaggedId)).first.id, last.id);
      expect(find.text('Due today'), findsWidgets);
    });

    testWidgets('unflagged there, it leaves the list', (tester) async {
      final c = await pump(tester);
      c.read(selectedFolderIdProvider.notifier).select(kFlaggedId);
      await tester.pumpAndSettle();
      final first = c.read(sortedMessagesProvider(kFlaggedId)).first;

      await tester.tap(find.byWidgetPredicate(
          (w) => w is MessageTile && w.message.id == first.id));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('Remove flag'),
      ));
      await tester.pumpAndSettle();

      expect(
        c.read(sortedMessagesProvider(kFlaggedId)).map((m) => m.id),
        isNot(contains(first.id)),
      );
    });

    testWidgets('Flagged is in the folder tree', (tester) async {
      await pump(tester);

      expect(find.text('Flagged'), findsWidgets);
    });
  });
}
