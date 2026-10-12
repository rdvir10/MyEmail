import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/calendar_meeting.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/invite_card.dart';

/// The card under meeting mail that is not a plain invitation, on screen:
/// a meeting cancelled or moved since, a new time proposed to you as its
/// organiser, an answer. What it says depends on where the account's own
/// calendar has the meeting now, and what it offers on what can be done.
void main() {
  const uid = '040000008200E00074C5B7101A82E00800000000AB12';

  /// Exchange's definition of the zone it names.
  const eastern = 'BEGIN:VTIMEZONE\r\n'
      'TZID:Eastern Standard Time\r\n'
      'BEGIN:STANDARD\r\nDTSTART:16010101T020000\r\nTZOFFSETFROM:-0400\r\n'
      'TZOFFSETTO:-0500\r\nRRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11\r\n'
      'END:STANDARD\r\n'
      'BEGIN:DAYLIGHT\r\nDTSTART:16010101T020000\r\nTZOFFSETFROM:-0500\r\n'
      'TZOFFSETTO:-0400\r\nRRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3\r\n'
      'END:DAYLIGHT\r\n'
      'END:VTIMEZONE\r\n';

  /// Meeting mail of [method] about one meeting, 7:30 to 8:30 in New York
  /// on Friday 16 October 2026 (11:30 UTC, the same Friday on any phone's
  /// clock), with [extra] lines in its event.
  String mail(
    String method, {
    String start = '20261016T073000',
    String end = '20261016T083000',
    String extra = '',
  }) =>
      'BEGIN:VCALENDAR\r\nMETHOD:$method\r\n$eastern'
      'BEGIN:VEVENT\r\n'
      'UID:$uid\r\n'
      'SUMMARY:Ron and Dana\r\n'
      'DTSTART;TZID=Eastern Standard Time:$start\r\n'
      'DTEND;TZID=Eastern Standard Time:$end\r\n'
      'LOCATION:Room 4\r\n'
      '$extra'
      'END:VEVENT\r\nEND:VCALENDAR\r\n';

  const organisedByDana = 'ORGANIZER;CN=Dana Levi:mailto:dana@example.com\r\n';
  const organisedByMe = 'ORGANIZER;CN=Ron Dvir:mailto:personal@example.com\r\n';

  /// What Outlook sends you when Dana proposes 8:30 to 9:00 for a meeting at
  /// 7:30 to 8:00 ([now] to [nowEnd]), declining it.
  String proposal({
    String now = '20261016T073000',
    String nowEnd = '20261016T080000',
  }) =>
      mail(
        'COUNTER',
        start: '20261016T083000',
        end: '20261016T090000',
        extra: '$organisedByMe'
            'ATTENDEE;PARTSTAT=DECLINED;CN=Dana Levi:mailto:dana@example.com\r\n'
            'X-MS-OLK-ORIGINALSTART;TZID=Eastern Standard Time:$now\r\n'
            'X-MS-OLK-ORIGINALEND;TZID=Eastern Standard Time:$nowEnd\r\n',
      );

  /// The meeting as the account's calendar has it: 7:30 to 8:00 New York
  /// time unless said otherwise.
  CalendarMeeting onCalendar({
    DateTime? start,
    DateTime? end,
    bool cancelled = false,
    bool organiser = false,
  }) =>
      CalendarMeeting(
        accountId: 'acct-personal',
        eventId: 'e-1',
        start: start ?? DateTime.utc(2026, 10, 16, 11, 30),
        end: end ?? DateTime.utc(2026, 10, 16, 12),
        isCancelled: cancelled,
        isOrganizer: organiser,
      );

  final message = MailMessage(
    id: 'acct-personal:INBOX#7',
    accountId: 'acct-personal',
    folderId: 'acct-personal:INBOX',
    uid: 7,
    subject: 'Meeting',
    from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
    to: const [MailAddress(email: 'personal@example.com')],
    date: DateTime(2026, 10, 11),
    preview: '',
  );

  late FakeDeviceCalendar calendar;

  setUp(() => calendar = FakeDeviceCalendar());

  /// The card for [engine]'s message, settled.
  Future<void> show(WidgetTester tester, _MeetingMail engine) async {
    tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
    addTearDown(tester.platformDispatcher.clearAlwaysUse24HourTestValue);
    final c = ProviderContainer(overrides: [
      mailEngineProvider.overrideWithValue(engine),
      deviceCalendarProvider.overrideWithValue(calendar),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: InviteCard(
              message: message,
              invite: CalendarInvite.parse(engine.ics)!,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('a meeting cancelled', () {
    testWidgets('and still on your calendar is taken off with one tap',
        (tester) async {
      final engine = _MeetingMail(mail('CANCEL', extra: organisedByDana))
        ..calendar[uid] = onCalendar(cancelled: true);
      await show(tester, engine);

      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.text('Still on your calendar.'), findsOneWidget);
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Add to calendar'), findsNothing);

      await tester.tap(find.text('Remove from calendar'));
      await tester.pumpAndSettle();

      expect(engine.removedFromCalendar.single.eventId, 'e-1');
      expect(find.text('Removed from your calendar.'), findsWidgets);
      expect(find.text('Remove from calendar'), findsNothing);
    });

    testWidgets('and no longer on your calendar offers nothing',
        (tester) async {
      await show(tester, _MeetingMail(mail('CANCEL', extra: organisedByDana)));

      expect(find.text('Not on your calendar.'), findsOneWidget);
      expect(find.text('Remove from calendar'), findsNothing);
      expect(find.text('Add to calendar'), findsNothing);
    });

    testWidgets('on a calendar the app cannot reach says where instead',
        (tester) async {
      final engine = _MeetingMail(mail('CANCEL', extra: organisedByDana))
        ..lookupFailure = const CalendarUnavailable('No calendar.');
      await show(tester, engine);

      expect(find.textContaining('Remove it in your calendar app.'),
          findsOneWidget);
      expect(find.text('Try again'), findsNothing,
          reason: 'asking again would get the same answer');
      expect(engine.lookups, 1,
          reason: 'said at once, not asked ten times over half a minute');
    });

    testWidgets('when the calendar could not be asked, asks again',
        (tester) async {
      final engine = _MeetingMail(mail('CANCEL', extra: organisedByDana))
        ..lookupFailure = const ConnectionFailed('No connection.');
      await show(tester, engine);

      expect(find.textContaining('Could not check your calendar.'),
          findsOneWidget);
      expect(find.text('Remove from calendar'), findsNothing);

      engine
        ..lookupFailure = null
        ..calendar[uid] = onCalendar(cancelled: true);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('Still on your calendar.'), findsOneWidget);
      expect(find.text('Remove from calendar'), findsOneWidget);
    });

    testWidgets('that you organised is never offered for taking off',
        (tester) async {
      // On the organiser's calendar a delete cancels it for everyone.
      final engine = _MeetingMail(mail('CANCEL', extra: organisedByMe))
        ..calendar[uid] = onCalendar(organiser: true);
      await show(tester, engine);

      expect(find.text('Remove from calendar'), findsNothing);
    });
  });

  group('an invitation', () {
    String invitation() => mail('REQUEST', extra: organisedByDana);

    testWidgets('cancelled since offers taking it off, not answering it',
        (tester) async {
      final engine = _MeetingMail(invitation())
        ..calendar[uid] = onCalendar(cancelled: true);
      await show(tester, engine);

      expect(find.text('Cancelled since, and still on your calendar.'),
          findsOneWidget);
      expect(find.text('Accept'), findsNothing);
      await tester.tap(find.text('Remove from calendar'));
      await tester.pumpAndSettle();

      expect(engine.removedFromCalendar, hasLength(1));
    });

    testWidgets('moved since says where your calendar has it',
        (tester) async {
      final engine = _MeetingMail(invitation())
        ..calendar[uid] = onCalendar(
          start: DateTime.utc(2026, 10, 16, 14),
          end: DateTime.utc(2026, 10, 16, 15),
        );
      await show(tester, engine);

      expect(find.textContaining('Your calendar has it at'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
    });

    testWidgets('on your calendar at its time says so, and is not added twice',
        (tester) async {
      final engine = _MeetingMail(invitation())
        ..calendar[uid] = onCalendar(end: DateTime.utc(2026, 10, 16, 12, 30));
      await show(tester, engine);

      expect(find.text('On your calendar at this time.'), findsOneWidget);
      expect(find.text('Add to calendar'), findsNothing,
          reason: 'the account\'s calendar has it already');
      expect(find.text('Accept'), findsOneWidget);
    });

    testWidgets('not on your calendar can be added to the phone\'s',
        (tester) async {
      await show(tester, _MeetingMail(invitation()));

      expect(find.text('Add to calendar'), findsOneWidget);
      expect(find.textContaining('calendar.'), findsNothing,
          reason: 'nothing to say about a calendar that does not have it');
    });

    testWidgets('on a calendar that could not be asked is just an invitation',
        (tester) async {
      final engine = _MeetingMail(invitation())
        ..lookupFailure = const ConnectionFailed('No connection.');
      await show(tester, engine);

      expect(find.textContaining('Could not check'), findsNothing,
          reason: 'an invitation does not nag about the calendar');
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Add to calendar'), findsOneWidget);
    });
  });

  group('a new time proposed', () {
    testWidgets('shows who, the time now and the time proposed',
        (tester) async {
      final engine = _MeetingMail(proposal())
        ..calendar[uid] = onCalendar(organiser: true);
      await show(tester, engine);

      expect(find.text('New time proposed'), findsOneWidget);
      expect(find.text('Dana Levi declined and proposed a new time.'),
          findsOneWidget);
      expect(find.textContaining('Current: Fri 16 Oct 2026'), findsOneWidget);
      expect(find.textContaining('Proposed: Fri 16 Oct 2026'), findsOneWidget);
      expect(find.text('Accept proposal'), findsOneWidget);
      expect(find.text('Decline proposal'), findsOneWidget);
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Add to calendar'), findsNothing);
    });

    testWidgets('Accept proposal asks first, then moves the meeting',
        (tester) async {
      final engine = _MeetingMail(proposal())
        ..calendar[uid] = onCalendar(organiser: true);
      await show(tester, engine);

      await tester.tap(find.text('Accept proposal'));
      await tester.pumpAndSettle();
      expect(find.text('Move the meeting?'), findsOneWidget);
      await tester.tap(find.text('Move it'));
      await tester.pumpAndSettle();

      final moved = engine.moved.single;
      expect(moved.meeting.eventId, 'e-1');
      expect(moved.proposal.start, DateTime.utc(2026, 10, 16, 12, 30));
      expect(find.textContaining('Moved to the time proposed'), findsOneWidget);
      expect(find.text('Accept proposal'), findsNothing);
      expect(find.text('Decline proposal'), findsNothing);
    });

    testWidgets('Cancel in the question moves nothing', (tester) async {
      final engine = _MeetingMail(proposal())
        ..calendar[uid] = onCalendar(organiser: true);
      await show(tester, engine);

      await tester.tap(find.text('Accept proposal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(engine.moved, isEmpty);
      expect(find.text('Accept proposal'), findsOneWidget);
    });

    testWidgets('Decline proposal tells the proposer, in your name',
        (tester) async {
      final engine = _MeetingMail(proposal())
        ..calendar[uid] = onCalendar(organiser: true);
      // On the real clock: the sample engine's own delay is a timer, which
      // the test's clock would hold until the first pump.
      await tester.runAsync(() => engine.updateAccount(
            accountId: 'acct-personal',
            senderName: 'Ron Dvir',
          ));
      await show(tester, engine);

      await tester.tap(find.text('Decline proposal'));
      await tester.pumpAndSettle();

      final draft = engine.sentDrafts.single;
      expect(draft.to.single.email, 'dana@example.com');
      expect(draft.subject, 'New time declined: Ron and Dana');
      expect(draft.htmlBody, contains('Ron Dvir declined the new time'));
      expect(draft.htmlBody, contains('The meeting stays at'));
      expect(draft.originalMessageId, message.id);
      expect(draft.kind, ComposeKind.reply);
      expect(draft.calendarReply, isNull,
          reason: 'Outlook reads no calendar part that says no to one');
      expect(find.text('You declined it, and Dana Levi has been told.'),
          findsOneWidget);
      expect(engine.moved, isEmpty);
    });

    testWidgets('already at the time proposed offers nothing more',
        (tester) async {
      final engine = _MeetingMail(proposal())
        ..calendar[uid] = onCalendar(
          start: DateTime.utc(2026, 10, 16, 12, 30),
          end: DateTime.utc(2026, 10, 16, 13),
          organiser: true,
        );
      await show(tester, engine);

      expect(find.text('Your calendar already has the time proposed.'),
          findsOneWidget);
      expect(find.text('Accept proposal'), findsNothing);
      expect(find.text('Decline proposal'), findsNothing);
    });

    testWidgets('of the time it has already offers nothing', (tester) async {
      // Outlook lets one through: "proposed" for the time it already has.
      final engine = _MeetingMail(
        proposal(now: '20261016T083000', nowEnd: '20261016T090000'),
      )..calendar[uid] = onCalendar(organiser: true);
      await show(tester, engine);

      expect(find.text('The time proposed is the time it has now.'),
          findsOneWidget);
      expect(find.text('Accept proposal'), findsNothing);
      expect(find.text('Decline proposal'), findsNothing);
    });

    testWidgets('for someone else\'s meeting cannot be accepted here',
        (tester) async {
      final engine = _MeetingMail(proposal())..calendar[uid] = onCalendar();
      await show(tester, engine);

      expect(find.text('Only its organiser can move it.'), findsOneWidget);
      expect(find.text('Accept proposal'), findsNothing);
      expect(find.text('Decline proposal'), findsOneWidget);
    });

    testWidgets('for a meeting not on your calendar can only be declined',
        (tester) async {
      await show(tester, _MeetingMail(proposal()));

      expect(find.text('The meeting is not on your calendar.'), findsOneWidget);
      expect(find.textContaining('Current: '), findsOneWidget,
          reason: 'the time it had, as the proposer saw it');
      expect(find.text('Accept proposal'), findsNothing);
      expect(find.text('Decline proposal'), findsOneWidget);
    });
  });

  testWidgets('an answer says who answered and how, and offers nothing',
      (tester) async {
    final engine = _MeetingMail(mail(
      'REPLY',
      extra: '$organisedByMe'
          'ATTENDEE;PARTSTAT=ACCEPTED;CN=Dana Levi:mailto:dana@example.com\r\n',
    ));
    await show(tester, engine);

    expect(find.text('Accepted'), findsOneWidget);
    expect(find.text('Dana Levi'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.text('Add to calendar'), findsNothing,
        reason: 'an answer is not an event to keep');
    expect(engine.lookups, 0, reason: 'nothing on the calendar to check');
  });

  group('the mail that declines a time proposed', () {
    final proposed = CalendarInvite.parse(proposal())!;

    test('says when the meeting stays, as the calendar has it', () {
      final draft = proposalDeclinedDraft(
        message: message,
        proposal: proposed,
        senderName: 'Ron Dvir',
        meeting: onCalendar(organiser: true),
      );

      expect(draft.accountId, 'acct-personal');
      expect(draft.to.single.display, 'Dana Levi');
      expect(draft.htmlBody, startsWith('<p>Ron Dvir declined the new time '
          'you proposed for Ron and Dana, Fri 16 Oct 2026, '));
      expect(draft.htmlBody, contains('<p>The meeting stays at Fri 16 Oct 2026'));
    });

    test('or as the proposer saw it, where the calendar was not asked', () {
      final draft = proposalDeclinedDraft(
        message: message,
        proposal: proposed,
        senderName: '  ',
      );

      expect(draft.htmlBody, startsWith('<p>The organiser declined'));
      expect(draft.htmlBody, contains('The meeting stays at'));
    });

    test('a name with markup in it is text', () {
      final draft = proposalDeclinedDraft(
        message: message,
        proposal: proposed,
        senderName: 'Ron <b>Dvir</b>',
      );

      expect(draft.htmlBody, contains('Ron &lt;b&gt;Dvir&lt;/b&gt;'));
    });
  });
}

/// The sample engine with one message, carrying [ics], whose lookups can be
/// made to fail, and which keeps what it is asked to send.
class _MeetingMail extends SampleMailEngine {
  _MeetingMail(this.ics);

  final String ics;
  final List<Draft> sentDrafts = [];

  /// Thrown by [meetingOnCalendar] while set.
  Object? lookupFailure;
  int lookups = 0;

  @override
  Future<MailBody> loadMessageBody(String messageId) async =>
      MailBody(text: 'Meeting.', calendar: ics);

  @override
  Future<CalendarMeeting?> meetingOnCalendar(
    String messageId,
    CalendarInvite invite,
  ) async {
    lookups++;
    final failure = lookupFailure;
    if (failure != null) throw failure;
    return super.meetingOnCalendar(messageId, invite);
  }

  @override
  Future<void> sendDraft(Draft draft) async => sentDrafts.add(draft);
}
