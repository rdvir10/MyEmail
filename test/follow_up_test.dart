import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/imap/imap_mapping.dart' show messageIdCriteria;
import 'package:myemail/data/mail_engine.dart' show FindsByMessageId;
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/follow_up.dart';
import 'package:myemail/domain/mail_message.dart';
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

  test("Gmail's flagged mail: each star's headers once, then its flags",
      () async {
    // All Mail is seldom synced, so each refresh fetched every star's
    // headers again, and never kept them: with Flagged open, up to 500 a
    // minute on the account's one connection.
    final server = FakeImapTransport()
      ..folder('INBOX', role: FolderRole.inbox)
      ..folder('[Gmail]/All Mail', role: FolderRole.archive);
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
    const allMail = '[Gmail]/All Mail';
    final all = server.folder(allMail);
    final starred = [
      for (var i = 0; i < 3; i++) all.deliver(subject: 'Starred $i')
        ..isFlagged = true,
    ];
    expect(await engine.flaggedMessages(account.id), hasLength(3));

    // Read on the PC, one more starred, and one unstarred.
    starred[0].isRead = true;
    starred[1].isFlagged = false;
    final later = all.deliver(subject: 'Starred later')..isFlagged = true;
    server.calls.clear();
    final again = await engine.flaggedMessages(account.id);

    expect(again.map((m) => m.subject).toSet(),
        {'Starred 0', 'Starred 2', 'Starred later'});
    expect(again.firstWhere((m) => m.subject == 'Starred 0').isRead, isTrue);
    expect(
      server.calls.where((call) =>
          call.startsWith('UID FETCH $allMail') && !call.endsWith('FLAGS')),
      ['UID FETCH $allMail ${later.uid}'],
      reason: 'headers for the new star alone',
    );
  });

  group('a reminder for a message filed since', () {
    // The usual flag-then-file. The reminder opens the message by its id in
    // the app, which has its folder in it, and a move gives it a new one:
    // the tap opened the folder it had left, with nothing in it, and on
    // the phone nothing at all.
    late FakeImapTransport server;
    late FakeImapTransport other;
    late CachedImapEngine engine;
    late Account account;
    late FakeMailNotifier notifier;
    late ProviderContainer c;
    const subject = 'Re: Quote for 6063-T5';

    /// A message in the Inbox with a reminder set, and the reminder's
    /// payload. [other] is a second account's server.
    Future<(MailMessage, String)> reminded() async {
      FakeImapTransport mailbox() => FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox)
        ..folder('Receipts')
        ..folder('[Gmail]/Trash', role: FolderRole.deleted);
      server = mailbox();
      other = mailbox();
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (a, _) =>
            a.emailAddress == 'p@example.com' ? server : other,
      );
      account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      await engine.loadFolders(account.id);
      server.folder('INBOX').deliver(subject: subject).isFlagged = true;
      final message =
          (await engine.loadMessages('${account.id}:INBOX')).single;
      notifier = FakeMailNotifier();
      c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        mailNotifierProvider.overrideWithValue(notifier),
      ]);
      addTearDown(c.dispose);
      await c.read(followUpsProvider.notifier).setReminder(
            message,
            DateTime.now().add(const Duration(days: 1)),
          );
      return (message, notifier.reminders.values.single.payload);
    }

    Future<ReminderTarget> whereNow(String payload) =>
        c.read(followUpsProvider.notifier).whereNow(payload);

    Future<String> fileInReceipts(MailMessage message) async =>
        (await engine.moveMessages([message.id], '${account.id}:Receipts'))
            .single
            .movedIds
            .single;

    test('opens it where it is now', () async {
      final (message, payload) = await reminded();
      expect(payload, message.id);

      final filed = await fileInReceipts(message);

      expect((await whereNow(payload)).id, filed);
    });

    test('filed where the device holds the mail, finds it there without '
        'asking the server', () async {
      final (message, payload) = await reminded();
      await engine.loadMessages('${account.id}:Receipts');
      final filed = await fileInReceipts(message);
      // Hours on, when the reminder comes: the sync behind the move into
      // Receipts long done (see CachedImapEngine._syncBehind).
      await engine.loadMessages('${account.id}:Receipts');
      server.calls.clear();

      expect((await whereNow(payload)).id, filed);
      expect(server.calls.where((call) => call.contains('Message-ID')),
          isEmpty);
    });

    test('found by its Message-ID, though a hundred more share its subject',
        () async {
      // The account was searched for the subject's words, and only the
      // newest hundred hits looked at.
      final (message, payload) = await reminded();
      final filed = await fileInReceipts(message);
      for (var i = 0; i < 120; i++) {
        server.folder('Receipts').deliver(subject: subject);
      }

      expect((await whereNow(payload)).id, filed);
    });

    test("a copy in the other account does not stand in for it", () async {
      // The device's own copies were looked at, every account's, before
      // its own account's server: a copy in the other account that the
      // device held won over the message itself, filed where it held
      // nothing.
      final (message, payload) = await reminded();
      final second = await engine.addAccount(
        displayName: 'Q',
        emailAddress: 'q@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      await engine.loadFolders(second.id);
      other.folder('INBOX').deliver(
            subject: subject,
            messageId: server.folder('INBOX').messages.values.single.messageId,
          );
      await engine.loadMessages('${second.id}:INBOX');
      final filed = await fileInReceipts(message);

      expect((await whereNow(payload)).id, filed);
    });

    test('where it has not moved, opens it as it was', () async {
      final (_, payload) = await reminded();

      expect((await whereNow(payload)).id, payload);
    });

    test('deleted: looked for, and nowhere', () async {
      final (message, payload) = await reminded();

      await engine.deleteMessages([message.id]);

      final target = await whereNow(payload);
      expect(target.id, isNull);
      expect(target.failed, isNull);
    });

    test('asked of the server exactly: Microsoft in one request, IMAP by '
        'the header', () async {
      late Uri asked;
      final api = GraphMailApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          asked = request.url;
          return http.Response(jsonEncode({'value': []}), 200);
        }),
      );
      await api.withMessageIdEverywhere("<o'brien@example.com>");
      expect(asked.path, endsWith('/me/messages'));
      expect(asked.queryParameters[r'$filter'],
          "internetMessageId eq '<o''brien@example.com>'");
      expect(asked.queryParameters[r'$select'], contains('parentFolderId'));

      expect(messageIdCriteria('a"b@example.com'),
          r'HEADER Message-ID "a\"b@example.com"');
    });

    test('with no connection, could not be looked for, which is not gone',
        () async {
      final (message, payload) = await reminded();
      await fileInReceipts(message);
      server.offline = true;

      final target = await whereNow(payload);
      expect(target.id, isNull);
      expect(target.failed, isNotNull);
    });
  });

  test('Flagged holds every flagged message of an account, not the newest '
      'page of them', () async {
    // It was asked for a page, as a folder is, with no row under it to ask
    // for more: the older flags, the overdue ones among them, never showed,
    // and soonest due first sorted only the newest fifty.
    final engine = SampleMailEngine();
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      mailEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(c.dispose);
    await c.read(foldersProvider.future);
    const account = 'acct-personal';
    final mail = await engine.loadMessages('$account:INBOX', limit: 500);
    final many = Messages.pageSize + 10;
    expect(mail.length, greaterThanOrEqualTo(many));
    await engine.setMessagesFlagged(
        [for (final m in mail.take(many)) m.id], true);
    final flagged = {
      for (final m in await engine.cachedFlagged(account, limit: 1000)) m.id,
    };
    expect(flagged.length, greaterThanOrEqualTo(many));

    c.listen(messagesProvider(kFlaggedId), (_, _) {});
    await c.read(messagesProvider(kFlaggedId).future);

    expect({
      for (final m in c.read(sortedMessagesProvider(kFlaggedId)))
        if (m.accountId == account) m.id,
    }, flagged);
  });

  test('a Gmail account with nothing starred answers an empty list',
      () async {
    final server = FakeImapTransport()
      ..folder('INBOX', role: FolderRole.inbox)
      ..folder('[Gmail]/All Mail', role: FolderRole.archive);
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
    server.folder('[Gmail]/All Mail').deliver(subject: 'Plain');

    // Not an error: on one the list fell back to the cached flags, where the
    // Inbox's copy of a message unflagged in Flagged was still flagged.
    expect(await engine.flaggedMessages(account.id), isEmpty);
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

    /// A reminder set on the Inbox's first message, as the real engines
    /// have it, with a Message-ID; the message itself, and the reminder's
    /// payload.
    Future<(MailMessage, String)> remind(
      WidgetTester tester,
      ProviderContainer c,
      SampleMailEngine engine,
    ) async {
      final message = (await tester
              .runAsync(() => engine.loadMessages('acct-personal:INBOX')))!
          .first;
      await c.read(followUpsProvider.notifier).setReminder(
            MailMessage(
              id: message.id,
              accountId: message.accountId,
              folderId: message.folderId,
              uid: message.uid,
              subject: message.subject,
              preview: '',
              from: message.from,
              to: message.to,
              date: message.date,
              messageId: 'quote@example.com',
            ),
            DateTime.now().add(const Duration(days: 1)),
          );
      return (message, notifier.reminders.values.single.payload);
    }

    /// The reminder tapped from the shade, over the app.
    Future<void> tap(WidgetTester tester, String payload) async {
      notifier.launchPayload = payload;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('a reminder for a message filed since opens it where it is '
        'now', (tester) async {
      final engine = _FindsMoved();
      final c = await pump(tester, engine: engine);
      final (message, payload) = await remind(tester, c, engine);
      const travel = 'acct-personal:Travel';
      final moves = (await tester
          .runAsync(() => engine.moveMessages([message.id], travel)))!;
      engine.found = moves.single.movedIds.single;

      await tap(tester, payload);

      expect(c.read(selectedFolderIdProvider), travel);
      expect(c.read(selectedMessageIdProvider), engine.found);
    });

    testWidgets('and one for a message gone says so', (tester) async {
      final engine = _FindsMoved();
      final c = await pump(tester, engine: engine);
      final (message, payload) = await remind(tester, c, engine);
      final folder = c.read(effectiveSelectedFolderIdProvider);
      await tester.runAsync(() => engine.deleteMessages([message.id]));

      await tap(tester, payload);

      expect(find.textContaining('may have been deleted'), findsOneWidget);
      expect(c.read(effectiveSelectedFolderIdProvider), folder);
    });

    testWidgets('and one that could not be looked for says that, not that it '
        'has gone', (tester) async {
      final engine = _FindsMoved();
      final c = await pump(tester, engine: engine);
      final (message, payload) = await remind(tester, c, engine);
      final folder = c.read(effectiveSelectedFolderIdProvider);
      await tester.runAsync(() =>
          engine.moveMessages([message.id], 'acct-personal:Travel'));
      engine.failure = StateError('no signal');

      await tap(tester, payload);

      expect(find.textContaining('could not be looked for'), findsOneWidget);
      expect(find.textContaining('may have been deleted'), findsNothing);
      expect(c.read(effectiveSelectedFolderIdProvider), folder);
    });
  });
}

/// The sample engine, finding a message by its Message-ID wherever a test
/// says it has gone, and failing to ask as a test says; the sample mail has
/// none to find it by.
class _FindsMoved extends SampleMailEngine implements FindsByMessageId {
  /// Where the server has it now.
  String? found;

  /// Why the server could not be asked.
  Object? failure;

  @override
  Future<String?> messageWithId(
    String messageId, {
    required String accountId,
  }) async =>
      null;

  @override
  Future<String?> messageWithIdOnServer(
    String messageId, {
    required String accountId,
  }) async {
    if (failure case final e?) throw e;
    return found;
  }
}
