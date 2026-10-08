import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/conversations.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/date_format.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:enough_mail/enough_mail.dart' as em;

import 'fakes/fake_imap_transport.dart';
import 'fakes/fake_webview.dart';

/// What a list row knows before anything is opened.
///
/// All of it comes out of the header fetch the sync already makes: who else
/// a message went to, what its files weigh, and whether it is a meeting.
/// None of it costs a request, which is the only reason a list can show it.
void main() {
  group('the date bar', () {
    final now = DateTime(2026, 9, 22, 10, 30);

    test('names today and yesterday rather than dating them', () {
      expect(formatDateBar(DateTime(2026, 9, 22, 8), now: now),
          startsWith('Today'));
      expect(formatDateBar(DateTime(2026, 9, 21, 23), now: now),
          startsWith('Yesterday'));
    });

    test('dates the rest of this week, and groups the weeks before as '
        'Outlook does', () {
      // Ron, with Outlook beside the phone: the date is good for the last
      // few days, and past them "Last Week", "Three Weeks Ago", "Last
      // Month" and "Older" say more than a date does. His week starts on
      // Sunday; this is Tuesday 29 September.
      final tuesday = DateTime(2026, 9, 29, 11);
      String bar(DateTime d) => formatDateBar(d, now: tuesday);

      expect(bar(DateTime(2026, 9, 29, 9)), 'Today \u00b7 Tue 29 Sep');
      expect(bar(DateTime(2026, 9, 28, 16)), 'Yesterday \u00b7 Mon 28 Sep');
      expect(bar(DateTime(2026, 9, 27, 19)), 'Sun 27 Sep');
      expect(bar(DateTime(2026, 9, 26, 9)), 'Last Week');
      expect(bar(DateTime(2026, 9, 22, 16)), 'Last Week');
      expect(bar(DateTime(2026, 9, 15)), 'Two Weeks Ago');
      expect(bar(DateTime(2026, 9, 8, 9)), 'Three Weeks Ago');
      expect(bar(DateTime(2026, 9, 4, 9)), 'Earlier this Month');
      expect(bar(DateTime(2026, 9, 2, 15)), 'Earlier this Month');
      expect(bar(DateTime(2026, 8, 10)), 'Last Month');
      expect(bar(DateTime(2026, 6, 7)), 'Older');
      expect(bar(DateTime(2025, 12, 1)), 'Older');
    });

    test('a week starting on Monday puts Sunday in last week', () {
      // The app's weeks start on Sunday, as Ron's Outlook does; this is
      // the arithmetic for another start.
      final tuesday = DateTime(2026, 9, 29, 11);
      expect(
        formatDateBar(DateTime(2026, 9, 27), now: tuesday, firstDayOfWeek: 1),
        'Last Week',
      );
      expect(
        formatDateBar(DateTime(2026, 9, 27), now: tuesday),
        'Sun 27 Sep',
      );
    });

    test('yesterday stays yesterday on the first day of a week', () {
      final sunday = DateTime(2026, 9, 27, 9);
      expect(formatDateBar(DateTime(2026, 9, 26), now: sunday),
          startsWith('Yesterday'));
      expect(formatDateBar(DateTime(2026, 9, 25), now: sunday), 'Last Week');
    });

    test('three weeks back may reach into last month, and wins', () {
      final friday = DateTime(2026, 10, 2, 9);
      expect(formatDateBar(DateTime(2026, 9, 14), now: friday),
          'Two Weeks Ago');
      expect(formatDateBar(DateTime(2026, 9, 1), now: friday), 'Last Month');
    });

    test('mail stamped ahead is today\'s, under today\'s date', () {
      // The bar took the date of the first row under it, and a message
      // stamped tomorrow said today was tomorrow.
      expect(formatDateBar(DateTime(2026, 9, 23, 1), now: now),
          'Today · Tue 22 Sep');
      expect(formatDateBar(DateTime(2099, 1, 1), now: now),
          'Today · Tue 22 Sep');
    });

    test('in January, last month is last year\'s December', () {
      final january = DateTime(2027, 1, 30, 9);
      expect(formatDateBar(DateTime(2026, 12, 20), now: january),
          'Last Month');
      expect(formatDateBar(DateTime(2026, 11, 20), now: january), 'Older');
    });

    test('yesterday is yesterday the day after the clocks change', () {
      // Counted in hours between local midnights, the night the clocks go
      // forward is 23 hours long, so yesterday's mail got a second "Today"
      // bar and the day before said "Yesterday". Every day of a year, so
      // the change falls in it wherever the test runs; in a zone with no
      // daylight saving this passes either way.
      for (var day = DateTime(2026, 1, 3);
          day.year == 2026;
          day = DateTime(day.year, day.month, day.day + 1)) {
        final now = DateTime(day.year, day.month, day.day, 9);
        final yesterday = DateTime(day.year, day.month, day.day - 1, 12);
        final before = DateTime(day.year, day.month, day.day - 2, 12);
        expect(formatDateBar(yesterday, now: now), startsWith('Yesterday'),
            reason: 'on $day');
        expect(formatDateBar(before, now: now), isNot(contains('Yesterday')),
            reason: 'on $day');
      }
    });

    test('a new day is a new bar in the reader\'s own zone', () {
      final thursday = DateTime(2026, 9, 24, 10);
      DateGroup of(DateTime d) => DateGroup.of(d, now: thursday);
      // Earlier this week, where the bar is the day's own.
      expect(of(DateTime(2026, 9, 21, 23, 59)),
          isNot(of(DateTime(2026, 9, 22, 0, 1))));
      expect(of(DateTime(2026, 9, 21, 0, 1)), of(DateTime(2026, 9, 21, 23, 59)));
      expect(of(DateTime(2026, 9, 23, 23, 59)).key, 'yesterday');
      expect(of(DateTime(2026, 9, 24, 0, 1)).key, 'today');
      // And a span is one bar, whichever of its days.
      expect(of(DateTime(2026, 9, 14)), of(DateTime(2026, 9, 19)));
    });
  });

  group('the date bars on the list', () {
    setUpAll(FakeWebViewPlatform.install);

    testWidgets('an open thread from yesterday does not start today again',
        (tester) async {
      // The bar was decided against the row just above, which under an
      // open thread is its oldest message. Yesterday's, it put a second
      // "Today" over the next conversation, in the middle of today's mail.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(_OneInboxEngine()),
      ]);
      addTearDown(c.dispose);
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
      c.read(selectedFolderIdProvider.notifier).select(_OneInboxEngine.inbox);
      await tester.pumpAndSettle();
      final thread = groupIntoConversations(
        await tester.runAsync(() => _OneInboxEngine()
            .loadMessages(_OneInboxEngine.inbox)) as List<MailMessage>,
      ).firstWhere((t) => t.isThread);
      c.read(expandedConversationsProvider.notifier).toggle(thread.id);
      await tester.pumpAndSettle();

      expect(find.textContaining('Today'), findsOneWidget);
    });

    Future<ProviderContainer> showInbox(
      WidgetTester tester,
      _TwoDaysEngine engine,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      c.read(displayProvider.notifier).setConversations(false);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
      c.read(selectedFolderIdProvider.notifier).select(_TwoDaysEngine.inbox);
      await tester.pumpAndSettle();
      return c;
    }

    Finder tile(int uid) =>
        find.byKey(ValueKey('tile:${_TwoDaysEngine.id(uid)}'));
    final today = find.byKey(const ValueKey('bar:today'));
    final yesterday = find.byKey(const ValueKey('bar:yesterday'));

    testWidgets('a tap on a bar folds its day away, and another brings it back',
        (tester) async {
      await showInbox(tester, _TwoDaysEngine());
      expect(tile(2), findsOneWidget);
      expect(tile(1), findsOneWidget);

      await tester.tap(yesterday);
      await tester.pumpAndSettle();
      expect(tile(2), findsNothing);
      expect(tile(1), findsNothing);
      expect(tile(4), findsOneWidget, reason: 'today is still open');
      expect(find.descendant(of: yesterday, matching: find.text('2')),
          findsOneWidget,
          reason: 'a closed bar says how much is under it');

      await tester.tap(yesterday);
      await tester.pumpAndSettle();
      expect(tile(2), findsOneWidget);
      expect(tile(1), findsOneWidget);
    });

    testWidgets('a closed bar counts the unread under it', (tester) async {
      // A closed Today still takes the morning's mail.
      await showInbox(tester, _TwoDaysEngine(unread: {2}));
      await tester.tap(yesterday);
      await tester.pumpAndSettle();
      expect(find.descendant(of: yesterday, matching: find.text('1 unread · 2')),
          findsOneWidget);
    });

    testWidgets('a long press or a right click on a bar is its menu',
        (tester) async {
      final engine = _TwoDaysEngine();
      final c = await showInbox(tester, engine);
      final ids = {_TwoDaysEngine.id(2), _TwoDaysEngine.id(1)};

      await tester.longPress(yesterday);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all 2'));
      await tester.pumpAndSettle();
      expect(c.read(selectedMessageIdsProvider), ids);

      await tester.tap(yesterday, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark all 2 as unread'));
      await tester.pumpAndSettle();
      expect(engine.marked, {for (final id in ids) id: false});

      await tester.longPress(yesterday);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Collapse'));
      await tester.pumpAndSettle();
      expect(tile(2), findsNothing);

      await tester.longPress(yesterday);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expand'));
      await tester.pumpAndSettle();
      expect(tile(2), findsOneWidget);
    });

    testWidgets('a day all ticked offers Unselect, which takes the boxes away',
        (tester) async {
      final c = await showInbox(tester, _TwoDaysEngine());
      final ids = {_TwoDaysEngine.id(2), _TwoDaysEngine.id(1)};
      final ticks = c.read(selectedMessageIdsProvider.notifier);

      // Part ticked is not all: the item ticks the rest.
      ticks.addAll([_TwoDaysEngine.id(2)]);
      await tester.pumpAndSettle();
      await tester.longPress(yesterday);
      await tester.pumpAndSettle();
      expect(find.text('Unselect all 2'), findsNothing);
      await tester.tap(find.text('Select all 2'));
      await tester.pumpAndSettle();
      expect(c.read(selectedMessageIdsProvider), ids);
      expect(find.byType(Checkbox), findsWidgets);

      await tester.longPress(yesterday);
      await tester.pumpAndSettle();
      expect(find.text('Select all 2'), findsNothing);
      await tester.tap(find.text('Unselect all 2'));
      await tester.pumpAndSettle();
      expect(c.read(selectedMessageIdsProvider), isEmpty);
      expect(find.byType(Checkbox), findsNothing,
          reason: 'nothing ticked is no longer selecting');

      // A tick outside the day is not the day's to take.
      final lunch = _TwoDaysEngine.id(3);
      ticks.addAll([lunch, ...ids]);
      await tester.pumpAndSettle();
      await tester.longPress(yesterday);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unselect all 2'));
      await tester.pumpAndSettle();
      expect(c.read(selectedMessageIdsProvider), {lunch});
    });

    testWidgets('closing the day being read leaves it open, and the arrows '
        'step over the closed day', (tester) async {
      final c = await showInbox(tester, _TwoDaysEngine());
      final lunch = _TwoDaysEngine.id(3);
      c.read(selectedMessageIdProvider.notifier).select(lunch);
      await tester.pumpAndSettle();

      await tester.tap(today);
      await tester.pumpAndSettle();
      expect(c.read(selectedMessageIdProvider), lunch,
          reason: 'the reading pane stays where it was');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(c.read(selectedMessageIdProvider), _TwoDaysEngine.id(2));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(c.read(selectedMessageIdProvider), _TwoDaysEngine.id(2),
          reason: 'nothing is open above it');
    });

    testWidgets('a closed bar at the bottom waits for a tap to load more',
        (tester) async {
      // Left to load on its own, the paging row would sit on screen under
      // the bar and every page would vanish beneath it.
      final c = await showInbox(tester, _TwoDaysEngine(yesterday: 60));
      List<MailMessage> shown() =>
          c.read(messagesProvider(_TwoDaysEngine.inbox)).value!;
      expect(shown(), hasLength(Messages.pageSize));

      await tester.tap(yesterday);
      await tester.pumpAndSettle();
      expect(shown(), hasLength(Messages.pageSize));
      expect(find.text('Load older messages'), findsOneWidget);

      await tester.tap(find.text('Load older messages'));
      await tester.pumpAndSettle();
      expect(shown(), hasLength(62));
      expect(find.text('Load older messages'), findsOneWidget,
          reason: 'waiting to be asked again, not spinning');
    });
  });

  group('read from the message structure', () {
    em.MimeMessage withCalendarPart() {
      final builder = em.MessageBuilder.prepareMultipartAlternativeMessage(
        plainText: 'Please come.',
        htmlText: '<p>Please come.</p>',
      )..addText(
          'BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n',
          mediaType: em.MediaType.fromSubtype(em.MediaSubtype.textCalendar),
        );
      return builder.buildMimeMessage();
    }

    test('a calendar part makes it a meeting', () {
      expect(carriesInvitation(withCalendarPart()), isTrue);
    });

    test('so does an .ics the sender labelled as bytes', () {
      final builder = em.MessageBuilder()
        ..addTextHtml('<p>See you then.</p>')
        ..addBinary(
          _bytes('BEGIN:VCALENDAR'),
          em.MediaType.fromText('application/octet-stream'),
          filename: 'invite.ics',
        );
      expect(carriesInvitation(builder.buildMimeMessage()), isTrue);
    });

    test('ordinary mail is not a meeting', () {
      final builder = em.MessageBuilder()..addTextHtml('<p>Hello</p>');
      expect(carriesInvitation(builder.buildMimeMessage()), isFalse);
    });

    test('the size is the whole message, as the server gives it', () {
      // What Outlook shows for Gmail: RFC822.SIZE, fetched with the rows.
      final message = em.MessageBuilder()..addTextPlain('Hello');
      final fetched = message.buildMimeMessage()
        ..uid = 7
        ..size = 48213;
      expect(remoteHeaderFromMime(fetched).sizeBytes, 48213);
    });
  });

  group('what a sync keeps', () {
    late FakeImapTransport server;
    late MemoryCacheStore cache;

    setUp(() {
      server = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox);
      cache = MemoryCacheStore();
    });

    test('everyone copied survives the round trip', () async {
      const copied = [
        MailAddress(email: 'michal@example.com', name: 'Michal Raz'),
        MailAddress(email: 'nik@example.com', name: 'Nik Shatzir'),
      ];
      await cache.upsertMessages('a', 'INBOX', [
        CachedMessage(
          uid: 1,
          subject: 'Catalogue',
          from: const MailAddress(email: 'gilad@example.com'),
          to: const [MailAddress(email: 'itay@example.com')],
          cc: copied,
          date: DateTime(2026, 9, 22, 10, 45),
          isRead: false,
          isFlagged: false,
          hasAttachments: false,
        ),
      ]);

      final row = (await cache.readMessages('a', 'INBOX')).single;
      final message = row.toMailMessage(accountId: 'a', folderId: 'a:INBOX');

      expect(message.cc.map((x) => x.email),
          containsAll(<String>['michal@example.com', 'nik@example.com']));
    });

    test('a meeting and the weight of its files do too', () async {
      await cache.upsertMessages('a', 'INBOX', [
        CachedMessage(
          uid: 2,
          subject: 'Review',
          from: const MailAddress(email: 'gilad@example.com'),
          to: const [],
          date: DateTime(2026, 9, 22, 11),
          isRead: false,
          isFlagged: false,
          hasAttachments: true,
          sizeBytes: 2048,
          isMeeting: true,
        ),
      ]);

      final message = (await cache.readMessages('a', 'INBOX'))
          .single
          .toMailMessage(accountId: 'a', folderId: 'a:INBOX');

      expect(message.isMeeting, isTrue);
      expect(message.sizeBytes, 2048);
    });

    test('the server unused here still reports its folder', () async {
      expect(server.folder('INBOX').path, 'INBOX');
    });
  });

  group('the account a message is sent from', () {
    Account account({String? senderName}) => Account(
          id: 'a',
          displayName: 'Hadco',
          emailAddress: 'rdvir@hadco-metal.com',
          provider: MailProvider.outlook,
          authMethod: AuthMethod.oauth,
          colorValue: 0xFF0F6CBD,
          chosenSenderName: senderName,
        );

    test('sends under the folder-list name until one is chosen', () {
      expect(account().senderName, 'Hadco');
      expect(account().hasOwnSenderName, isFalse);
    });

    test('and under its own name once it is', () {
      final a = account(senderName: 'Ron Dvir');
      expect(a.senderName, 'Ron Dvir');
      expect(a.displayName, 'Hadco', reason: 'the tree label is untouched');
      expect(a.hasOwnSenderName, isTrue);
    });

    test('an empty choice is no choice, not an empty name', () {
      // Clearing the field has to put the fallback back, or a mistake there
      // would send mail with no name on it at all.
      final a = account(senderName: '   ');
      expect(a.senderName, 'Hadco');
      expect(a.hasOwnSenderName, isFalse);
    });
  });
}

/// enough_mail wants bytes; these tests would rather write text.
Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// An Inbox holding one thread that began yesterday and carried on this
/// morning, and one message of today's that is older than the thread's last.
class _OneInboxEngine extends SampleMailEngine {
  static const inbox = 'acct-personal:INBOX';

  static List<MailMessage> _mail() {
    final now = DateTime.now();
    DateTime at(int daysAgo, int hour) =>
        DateTime(now.year, now.month, now.day - daysAgo, hour);
    MailMessage m(int uid, String subject, DateTime date) => MailMessage(
          id: MailMessage.idFor(inbox, uid),
          accountId: 'acct-personal',
          folderId: inbox,
          uid: uid,
          subject: subject,
          preview: '',
          from: const MailAddress(email: 'dana@example.com'),
          to: const [],
          date: date,
          isRead: true,
        );
    return [
      m(4, 'Re: Plans', at(0, 0).add(const Duration(minutes: 3))),
      m(3, 'Lunch', at(0, 0).add(const Duration(minutes: 1))),
      m(2, 'Re: Plans', at(1, 12)),
      m(1, 'Plans', at(1, 9)),
    ];
  }

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      folderId == inbox && offset == 0 ? _mail() : const [];

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) =>
      loadMessages(folderId, offset: offset, limit: limit);
}

/// An Inbox of two days, with conversations nowhere in it: today's two
/// messages just after midnight, and [yesterday] more from yesterday noon
/// back, uids counting down from the newest. Read unless in [unread].
/// Marks are kept rather than refused, as the sample store refuses
/// messages it did not make.
class _TwoDaysEngine extends SampleMailEngine {
  _TwoDaysEngine({this.yesterday = 2, this.unread = const {}});

  static const inbox = 'acct-personal:INBOX';
  static String id(int uid) => MailMessage.idFor(inbox, uid);

  final int yesterday;
  final Set<int> unread;
  final marked = <String, bool>{};

  List<MailMessage> _mail() {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    final noon = DateTime(now.year, now.month, now.day - 1, 12);
    final newest = yesterday + 2;
    MailMessage m(int uid, DateTime date) => MailMessage(
          id: id(uid),
          accountId: 'acct-personal',
          folderId: inbox,
          uid: uid,
          subject: 'Message $uid',
          preview: '',
          from: const MailAddress(email: 'dana@example.com'),
          to: const [],
          date: date,
          isRead: !unread.contains(uid),
        );
    return [
      m(newest, midnight.add(const Duration(minutes: 3))),
      m(newest - 1, midnight.add(const Duration(minutes: 1))),
      for (var uid = yesterday; uid >= 1; uid--)
        m(uid, noon.subtract(Duration(minutes: yesterday - uid))),
    ];
  }

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      folderId == inbox
          ? _mail().skip(offset).take(limit).toList()
          : const [];

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) =>
      loadMessages(folderId, offset: offset, limit: limit);

  @override
  Future<void> setRead(String messageId, bool isRead) async =>
      marked[messageId] = isRead;
}
