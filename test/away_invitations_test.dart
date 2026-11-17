import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/calendar_meeting.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/away_screen.dart';

import 'fakes/fake_webview.dart';

/// I am away clears the invitations of the meetings it declined from the
/// Inbox (calendar ideas #53 and #51), as Decline on a meeting's sheet
/// does, where Settings, Calendar says so: only the invitation the calendar
/// ties to a meeting declined that went, all in one line with one Undo.
/// Mail is moved from the most dangerous screen in the app.
void main() {
  setUp(FakeWebViewPlatform.install);

  final now = DateTime(2026, 11, 17, 10, 17);
  final wed = DateTime(2026, 11, 18), fri = DateTime(2026, 11, 20);
  DateTime at(int day, int h) => DateTime(2026, 11, day, h);
  const dana = MailAddress(email: 'dana@hadco.example', name: 'Dana Levi');
  const ron = MailAddress(email: 'ron@hadco.example', name: 'Ron');

  CalendarEvent meeting(
    Account a,
    String id,
    String title,
    DateTime start, {
    String? seriesId,
  }) =>
      CalendarEvent(
        id: id,
        accountId: a.id,
        title: title,
        start: start,
        end: start.add(const Duration(hours: 1)),
        organizer: dana,
        attendees: const [
          EventAttendee(dana, response: EventResponse.organizer),
          EventAttendee(ron, response: EventResponse.notResponded),
        ],
        response: EventResponse.notResponded,
        seriesId: seriesId,
      );

  /// Away for Wednesday to Friday, over a first screen, with Hadco's
  /// meetings and their invitations; [prepare] fills them.
  Future<(_AwayInbox, Account)> pump(
    WidgetTester tester, {
    bool delete = true,
    required void Function(_AwayInbox engine, Account hadco) prepare,
  }) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final engine = _AwayInbox();
    final hadco = (await tester.runAsync(() => engine.addOAuthAccount(
          displayName: 'Hadco',
          emailAddress: ron.email,
          provider: MailProvider.outlook,
          token: OAuthToken(
            accessToken: 'a',
            refreshToken: 'r',
            expiresAt: DateTime.utc(2030),
          ),
        )))!;
    engine.exchange.add(hadco.id);
    prepare(engine, hadco);
    final ui = MemoryUiStateStore();
    if (!delete) {
      await ui.writeString(
        UiStateKeys.calendarPrefs,
        jsonEncode(const CalendarPrefs()
            .copyWith(deleteAnsweredInvites: false)
            .toJson()),
      );
    }
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(ui),
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider
          .overrideWithValue(FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      meetingClockProvider.overrideWithValue(() => now),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open-away'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AwayScreen(first: wed, last: fri),
                  ),
                ),
                child: const Text('Away'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open-away')));
    await tester.pumpAndSettle();
    return (engine, hadco);
  }

  Finder rowOf(Account a, String id) =>
      find.byKey(ValueKey('away:${a.id}:$id'));

  /// Leaves [id]'s row unticked.
  Future<void> untick(WidgetTester tester, Account a, String id) async {
    await tester.scrollUntilVisible(rowOf(a, id), 200,
        scrollable: find
            .descendant(
                of: find.byKey(const ValueKey('away-list')),
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(rowOf(a, id));
    await tester.pump();
  }

  Future<void> press(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('away-go')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('away-go-sure')));
    await tester.pumpAndSettle();
  }

  /// Budget and Review declined, both with an invitation; Supplier
  /// unticked, with one; Planning refused by the calendar, with one; one
  /// meeting of the weekly series, whose invitation is the series'.
  void fill(_AwayInbox engine, Account hadco) {
    engine.events[hadco.id] = [
      meeting(hadco, 'budget', 'Budget', at(18, 10)),
      meeting(hadco, 'review', 'Review', at(18, 14)),
      meeting(hadco, 'supplier', 'Supplier', at(19, 10)),
      meeting(hadco, 'planning', 'Planning', at(19, 14)),
      meeting(hadco, 'weekly-19', 'Weekly', at(19, 16), seriesId: 'weekly'),
    ];
    for (final (n, uid, subject, eventId) in [
      (1, 'budget@x', 'Budget', 'budget'),
      (2, 'review@x', 'Review', 'review'),
      (3, 'supplier@x', 'Supplier', 'supplier'),
      (4, 'planning@x', 'Planning', 'planning'),
      (5, 'weekly@x', 'Weekly', 'weekly'),
    ]) {
      engine.invitation(hadco, n, uid: uid, subject: subject);
      engine.place(hadco, uid, eventId: eventId);
    }
    engine.refuse.add('planning');
  }

  testWidgets('only the invitations of meetings declined that went go to '
      'Deleted Items, said in one line with one Undo, which puts every one '
      'back', (tester) async {
    late Account hadco;
    final (engine, _) = await pump(tester, prepare: (engine, a) {
      hadco = a;
      fill(engine, a);
    });
    await untick(tester, hadco, 'supplier');
    await press(tester);

    expect(engine.calendarActions, [
      'respond budget declined',
      'respond review declined',
      'respond weekly-19 declined',
    ]);
    expect(engine.inboxOf(hadco).map((m) => m.subject).toSet(),
        {'Supplier', 'Planning', 'Weekly'},
        reason: 'unticked, refused, and a series of which one was declined');
    expect(find.text('2 invitations moved to Deleted Items.'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget, reason: 'one line');

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(engine.inboxOf(hadco).map((m) => m.subject).toSet(),
        {'Budget', 'Review', 'Supplier', 'Planning', 'Weekly'});
    expect(engine.calendarActions, hasLength(3),
        reason: 'Undo puts the invitations back, not the answers');
  });

  testWidgets('with Settings keeping answered invitations, nothing is '
      'looked for and nothing moves', (tester) async {
    late Account hadco;
    final (engine, _) = await pump(tester, delete: false,
        prepare: (engine, a) {
      hadco = a;
      fill(engine, a);
    });
    await press(tester);
    expect(engine.calendarActions, hasLength(4));
    expect(engine.searched, isEmpty);
    expect(engine.deleted, isEmpty);
    expect(engine.inboxOf(hadco), hasLength(5));
    expect(find.textContaining('Deleted Items'), findsNothing);
  });

  testWidgets('a move that fails leaves them, and says so', (tester) async {
    late Account hadco;
    final (engine, _) = await pump(tester, prepare: (engine, a) {
      hadco = a;
      fill(engine, a);
      engine.deleteFails = const ConnectionFailed('No connection.');
    });
    await press(tester);
    expect(engine.calendarActions, hasLength(4));
    expect(engine.inboxOf(hadco), hasLength(5));
    expect(
        find.text('The invitations could not be moved to Deleted Items: '
            'they are still in the Inbox.'),
        findsOneWidget);
  });

  testWidgets('a look that fails leaves them, and says so; the declines '
      'still go', (tester) async {
    late Account hadco;
    final (engine, _) = await pump(tester, prepare: (engine, a) {
      hadco = a;
      fill(engine, a);
      engine.foldersFail = const ConnectionFailed('No connection.');
    });
    await press(tester);
    expect(engine.calendarActions, hasLength(4));
    expect(engine.inboxOf(hadco), hasLength(5));
    expect(
        find.text('Some invitations could not be looked for: they are '
            'still in the Inbox.'),
        findsOneWidget);
  });
}

/// The sample engine with an Inbox a test fills, its messages' calendar
/// parts, and a calendar that places an invitation by its UID; Exchange's
/// way of taking a declined meeting off its calendar; and a meeting the
/// calendar refuses to answer ([refuse]). A smaller copy of
/// answered_invitation_test's own.
class _AwayInbox extends SampleMailEngine {
  final Map<String, List<MailMessage>> inboxes = {};
  final Map<String, String> parts = {};
  final Map<(String, String), CalendarMeeting> placed = {};
  final List<String> deleted = [];
  final List<String> searched = [];
  final Set<String> exchange = {};
  final Set<String> refuse = {};
  Exception? searchFails;
  Exception? deleteFails;

  /// What reading the account's folders throws, for a test: the look for
  /// invitations fails whole.
  Exception? foldersFail;

  @override
  Future<List<MailFolder>> cachedFolders(String accountId) async {
    final fails = foldersFail;
    if (fails != null) throw fails;
    return super.cachedFolders(accountId);
  }
  final Map<String, (String, MailMessage)> _trashed = {};

  String inboxIdOf(Account account) => MailFolder.idFor(account.id, 'INBOX');

  List<MailMessage> inboxOf(Account account) =>
      List.of(inboxes[inboxIdOf(account)] ?? const <MailMessage>[]);

  void invitation(
    Account account,
    int number, {
    required String uid,
    required String subject,
  }) {
    final message = MailMessage(
      id: MailMessage.idFor(inboxIdOf(account), number),
      accountId: account.id,
      folderId: inboxIdOf(account),
      uid: number,
      subject: subject,
      from: const MailAddress(email: 'dana@hadco.example', name: 'Dana Levi'),
      to: [MailAddress(email: account.emailAddress)],
      date: DateTime(2026, 11, 1).add(Duration(hours: number)),
      preview: '',
      isMeeting: true,
    );
    inboxes.putIfAbsent(inboxIdOf(account), () => [])
      ..add(message)
      ..sort((a, b) => b.date.compareTo(a.date));
    parts[message.id] = [
      'BEGIN:VCALENDAR',
      'METHOD:REQUEST',
      'BEGIN:VEVENT',
      'UID:$uid',
      'SUMMARY:$subject',
      'DTSTART:20261118T080000Z',
      'DTEND:20261118T090000Z',
      'ORGANIZER;CN=Dana Levi:mailto:dana@hadco.example',
      'ATTENDEE:mailto:${account.emailAddress}',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n');
  }

  void place(Account account, String uid, {required String eventId}) =>
      placed[(account.id, uid)] = CalendarMeeting(
        accountId: account.id,
        eventId: eventId,
        start: DateTime.utc(2026, 11, 18, 8),
      );

  MailMessage? _held(String messageId) {
    for (final list in inboxes.values) {
      for (final m in list) {
        if (m.id == messageId) return m;
      }
    }
    return null;
  }

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final inbox = inboxes[folderId];
    if (inbox == null) {
      return super.loadMessages(folderId, offset: offset, limit: limit);
    }
    return inbox.skip(offset).take(limit).toList();
  }

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) =>
      loadMessages(folderId, offset: offset, limit: limit);

  @override
  Future<MailMessage?> cachedMessage(String messageId) async =>
      _held(messageId) ?? await super.cachedMessage(messageId);

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  }) async {
    final inbox = scope.folderId == null ? null : inboxes[scope.folderId!];
    if (inbox == null) {
      return super.searchMessages(query, scope, limit: limit, field: field);
    }
    searched.add(query);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final fails = searchFails;
    if (fails != null) throw fails;
    final words = query.toLowerCase().split(RegExp(r'\s+'));
    return [
      for (final m in inbox)
        if (words.every(m.subject.toLowerCase().contains)) m,
    ].take(limit).toList();
  }

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    if (_held(messageId) == null) return super.loadMessageBody(messageId);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return MailBody(text: 'You are invited.', calendar: parts[messageId]);
  }

  @override
  Future<CalendarMeeting?> meetingOnCalendar(
    String messageId,
    CalendarInvite invite,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final accountId = messageId.substring(0, messageId.indexOf(':'));
    return placed[(accountId, invite.uid)];
  }

  @override
  Future<void> respondToEvent(
    CalendarEvent event,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
    bool wholeSeries = false,
  }) async {
    if (refuse.contains(event.id)) {
      throw const CalendarRefused('Exchange said no.');
    }
    await super.respondToEvent(event, response,
        note: note, send: send, proposal: proposal, wholeSeries: wholeSeries);
    // Exchange takes a declined meeting off: nothing is placed on it after.
    if (exchange.contains(event.accountId)) {
      placed.removeWhere((_, m) => m.eventId == event.id);
      events[event.accountId]!.removeWhere((e) => e.id == event.id);
    }
  }

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final refused = deleteFails;
    if (refused != null && messageIds.any((id) => _held(id) != null)) {
      throw refused;
    }
    final moves = <MessageMove>[];
    final rest = <String>[];
    for (final id in messageIds) {
      final message = _held(id);
      if (message == null) {
        rest.add(id);
        continue;
      }
      inboxes[message.folderId]!.removeWhere((m) => m.id == id);
      deleted.add(id);
      final trash = MailFolder.idFor(message.accountId, 'Deleted Items');
      final there = MailMessage.idFor(trash, 1000 + _trashed.length);
      _trashed[there] = (message.folderId, message);
      moves.add(MessageMove(
        fromFolderId: message.folderId,
        toFolderId: trash,
        movedIds: [there],
      ));
    }
    return [
      ...moves,
      if (rest.isNotEmpty) ...await super.deleteMessages(rest),
    ];
  }

  @override
  Future<void> undoMoves(List<MessageMove> moves) async {
    final rest = <MessageMove>[];
    for (final move in moves) {
      final back = [for (final id in move.movedIds) ?_trashed.remove(id)];
      if (back.isEmpty) {
        rest.add(move);
        continue;
      }
      for (final (folderId, message) in back) {
        inboxes[folderId]!
          ..add(message)
          ..sort((a, b) => b.date.compareTo(a.date));
      }
    }
    if (rest.isNotEmpty) await super.undoMoves(rest);
  }
}
