import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/calendar_upkeep.dart'
    show calendarWidgetLink;
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/calendar/running_late.dart';
import 'package:myemail/data/widget/widget_taps.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/domain/meeting_alerts.dart';

/// What MyEmail says about meetings away from the calendar (calendar ideas
/// #9, #11, #31 and #33), worked out from the events alone.
void main() {
  // A Monday morning.
  final now = DateTime(2026, 10, 26, 9, 50);
  const dana = MailAddress(email: 'dana@example.com', name: 'Dana Levi');

  CalendarEvent event(
    String id,
    DateTime start, {
    Duration length = const Duration(minutes: 30),
    String title = 'Weekly sync',
    bool allDay = false,
    EventResponse response = EventResponse.accepted,
    bool cancelled = false,
    int? reminder = 15,
    String location = '',
    String? joinUrl,
    MailAddress? organizer = dana,
    bool isOrganizer = false,
    List<EventAttendee> attendees = const [],
    String accountId = 'hadco',
  }) =>
      CalendarEvent(
        id: id,
        accountId: accountId,
        title: title,
        start: start,
        end: start.add(length),
        allDay: allDay,
        response: response,
        cancelled: cancelled,
        reminderMinutes: reminder,
        location: location,
        joinUrl: joinUrl,
        organizer: organizer,
        isOrganizer: isOrganizer,
        attendees: attendees,
      );

  group('the next meeting over the mail (#9)', () {
    test('a quarter of an hour before, and not before that', () {
      final soon = event('a', DateTime(2026, 10, 26, 10));
      final later = event('b', DateTime(2026, 10, 26, 10, 10));
      expect(nextMeeting([later, soon], now), same(soon));
      expect(nextMeeting([later], now), isNull, reason: '20 minutes off');
    });

    test('one under way until it ends, the next to start first', () {
      final going = event('a', DateTime(2026, 10, 26, 9, 30),
          length: const Duration(hours: 1));
      final next = event('b', DateTime(2026, 10, 26, 10));
      expect(nextMeeting([going], now), same(going));
      expect(nextMeeting([going, next], now), same(next));
      expect(nextMeeting([going], DateTime(2026, 10, 26, 10, 30)), isNull);
    });

    test('never one declined, cancelled, a whole day, or swiped away', () {
      final at = DateTime(2026, 10, 26, 10);
      expect(
          nextMeeting([
            event('a', at, response: EventResponse.declined),
            event('b', at, cancelled: true),
            event('c', DateTime(2026, 10, 26),
                allDay: true, length: const Duration(days: 1)),
          ], now),
          isNull);
      final swiped = event('d', at);
      expect(nextMeeting([swiped], now, dismissed: {meetingKey(swiped)}),
          isNull);
      // Moved to another time, it is another meeting to say.
      final moved = event('d', at.add(const Duration(minutes: 5)));
      expect(nextMeeting([moved], now, dismissed: {meetingKey(swiped)}),
          same(moved));
    });

    test('says how long to go, or until when', () {
      final e = event('a', DateTime(2026, 10, 26, 10, 2));
      expect(startsText(e, now, use24h: true), 'in 12 min');
      expect(startsText(e, DateTime(2026, 10, 26, 10, 1, 30), use24h: true),
          'in 1 min');
      expect(startsText(e, DateTime(2026, 10, 26, 10, 5), use24h: true),
          'now, until 10:32');
      expect(startsText(e, DateTime(2026, 10, 26, 10, 5), use24h: false),
          'now, until 10:32 AM');
    });
  });

  group('a meeting in a notification', () {
    final ref = MeetingRef(
      accountId: 'hadco',
      eventId: 'AAMk=+/x',
      calendarId: 'work@group.calendar.google.com',
      start: DateTime(2026, 10, 26, 10),
      end: DateTime(2026, 10, 26, 10, 30),
      title: 'Weekly sync',
      body: '10:00–10:30 · Room 4',
      joinUrl: 'https://teams.microsoft.com/l/meetup-join/x',
      canTellLate: true,
    );

    test('comes back whole from its payload, and from Join', () {
      expect(MeetingRef.fromPayload(ref.payload), ref);
      expect(MeetingRef.isJoin(ref.payload), isFalse);
      final joined = MeetingRef.joining(ref.payload);
      expect(MeetingRef.isJoin(joined), isTrue);
      expect(MeetingRef.fromPayload(joined), ref);
      expect(joined, ref.joinPayload);
    });

    test('is not taken for a message, nor a message for it', () {
      expect(MeetingRef.fromPayload('acct:INBOX#4'), isNull);
      expect(MeetingRef.joining('acct:INBOX#4'), 'acct:INBOX#4');
      expect(MeetingRef.fromPayload('myemail-meeting:{nope'), isNull);
      expect(calendarDayOf(ref.payload), isNull);
    });

    test("the agenda's opens the calendar on its day", () {
      final payload = calendarDayPayload(DateTime(2026, 11, 2));
      expect(calendarDayOf(payload), DateTime(2026, 11, 2));
      expect(MeetingRef.fromPayload(payload), isNull);
    });
  });

  group('meeting reminders (#31)', () {
    test("at each meeting's own time before it, saying when and where", () {
      final e = event('a', DateTime(2026, 10, 26, 11),
          location: 'Room 4', joinUrl: 'https://meet.google.com/abc');
      final r = meetingRemindersFor([e], now: now, use24h: true).single;
      expect(r.at, DateTime(2026, 10, 26, 10, 45));
      expect(r.id, meetingReminderId(e));
      expect(r.meeting.title, 'Weekly sync');
      expect(r.meeting.body, '11:00–11:30 · Room 4');
      expect(r.canJoin, isTrue);
      expect(r.canTellLate, isTrue, reason: 'Dana organised it');
    });

    test("each wears its account's colour, where one is given, and carries "
        'it in what a tap or a Snooze hands back', () {
      final e = event('a', DateTime(2026, 10, 26, 11));
      final r = meetingRemindersFor([e],
          now: now, use24h: true, colours: {e.accountId: 0xFF0F6CBD}).single;
      expect(r.meeting.colour, 0xFF0F6CBD);
      expect(MeetingRef.fromPayload(r.meeting.payload), r.meeting);
      expect(MeetingRef.fromPayload(r.meeting.payload)!.colour, 0xFF0F6CBD);

      final plain = meetingRemindersFor([e], now: now, use24h: true).single;
      expect(plain.meeting.colour, isNull);
      expect(plain.meeting.payload, isNot(contains('"k"')),
          reason: 'as a reminder set by an older build has it');
      expect(MeetingRef.fromPayload(plain.meeting.payload)!.colour, isNull);
    });

    test('none for a meeting with no reminder, declined, or begun', () {
      expect(
          meetingRemindersFor([
            event('a', DateTime(2026, 10, 26, 11), reminder: null),
            event('b', DateTime(2026, 10, 26, 11),
                response: EventResponse.declined),
            event('c', DateTime(2026, 10, 26, 9, 30)),
            event('d', DateTime(2026, 10, 28, 11)),
          ], now: now, use24h: true),
          isEmpty);
    });

    test('Running late only where there is someone to tell', () {
      final alone = event('a', DateTime(2026, 10, 26, 11),
          organizer: null, isOrganizer: true);
      final mine = event('b', DateTime(2026, 10, 26, 12),
          organizer: const MailAddress(email: 'ron@hadco.example'),
          isOrganizer: true,
          attendees: const [EventAttendee(dana)]);
      final reminders = meetingRemindersFor([alone, mine],
          now: now,
          use24h: true,
          ownEmails: {'hadco': 'ron@hadco.example'});
      expect([for (final r in reminders) r.canTellLate], [false, true]);
      expect(reminders.first.meeting.body, '11:00–11:30');
    });

    // A reminder for meetings that have none (#68).
    test('a meeting with no reminder of its own has the one chosen; none '
        'as before', () {
      final none = event('a', DateTime(2026, 10, 26, 11), reminder: null);
      final own = event('b', DateTime(2026, 10, 26, 12));
      final atStart = event('c', DateTime(2026, 10, 26, 13), reminder: 0);
      expect(
        [
          for (final r in meetingRemindersFor([none, own, atStart],
              now: now, use24h: true))
            r.meeting.eventId,
        ],
        ['b', 'c'],
        reason: 'nothing chosen: as it always was',
      );
      final chosen = meetingRemindersFor(
        [
          none,
          own,
          atStart,
          event('d', DateTime(2026, 10, 26, 14),
              reminder: null, response: EventResponse.declined),
          event('e', DateTime(2026, 10, 27),
              reminder: null, allDay: true, length: const Duration(days: 1)),
        ],
        now: now,
        use24h: true,
        ifNone: 10,
      );
      expect({for (final r in chosen) r.meeting.eventId: r.at}, {
        'a': DateTime(2026, 10, 26, 10, 50),
        'b': DateTime(2026, 10, 26, 11, 45),
        'c': DateTime(2026, 10, 26, 13),
      });
    });

    test('Snooze puts it off five minutes, or to the start, never past it',
        () {
      final ref = MeetingRef.of(event('a', DateTime(2026, 10, 26, 10)));
      expect(snoozedUntil(ref, DateTime(2026, 10, 26, 9, 45)),
          DateTime(2026, 10, 26, 9, 50));
      expect(snoozedUntil(ref, DateTime(2026, 10, 26, 9, 57)),
          DateTime(2026, 10, 26, 10));
      expect(snoozedUntil(ref, DateTime(2026, 10, 26, 10, 10)),
          DateTime(2026, 10, 26, 10, 15));
      expect(snoozedUntil(ref, DateTime(2026, 10, 26, 10, 26)), isNull);
    });
  });

  group('the morning agenda (#33)', () {
    const workWeek = {1, 2, 3, 4, 5};

    test("on the next working morning, at the time chosen", () {
      expect(nextAgendaTime(DateTime(2026, 10, 26, 7), 450, workWeek),
          DateTime(2026, 10, 26, 7, 30));
      expect(nextAgendaTime(DateTime(2026, 10, 26, 8), 450, workWeek),
          DateTime(2026, 10, 27, 7, 30));
      // Friday evening: Monday.
      expect(nextAgendaTime(DateTime(2026, 10, 30, 18), 450, workWeek),
          DateTime(2026, 11, 2, 7, 30));
      // A Sunday to Thursday week.
      expect(nextAgendaTime(DateTime(2026, 10, 30, 18), 450, {7, 1, 2, 3, 4}),
          DateTime(2026, 11, 1, 7, 30));
    });

    test('how many, and when the first begins', () {
      final agenda = morningAgendaFor([
        event('b', DateTime(2026, 10, 27, 14), title: 'Design review'),
        event('a', DateTime(2026, 10, 27, 9, 30), title: 'Stand-up'),
        event('x', DateTime(2026, 10, 27, 11),
            response: EventResponse.declined),
        event('d', DateTime(2026, 10, 27),
            allDay: true, length: const Duration(days: 1), title: 'Day out'),
        event('n', DateTime(2026, 10, 28, 9), title: 'Next day'),
      ], now: now, minutes: 450, workWeek: workWeek, use24h: true)!;
      expect(agenda.at, DateTime(2026, 10, 27, 7, 30));
      expect(agenda.title, '2 meetings today');
      expect(agenda.body, 'The first at 09:30: Stand-up');
      expect(agenda.lines,
          ['09:30  Stand-up', '14:00  Design review', 'All day  Day out']);
    });

    test('a day with nothing on stays quiet', () {
      expect(
          morningAgendaFor([
            event('n', DateTime(2026, 10, 28, 9)),
          ], now: now, minutes: 450, workWeek: workWeek, use24h: true),
          isNull);
    });

    // It speaks up on a day with only all-day events (#68), which it left
    // unsaid before.
    test('a day of all-day events only says them', () {
      MorningAgenda? agenda(List<CalendarEvent> events) => morningAgendaFor(
          events,
          now: now,
          minutes: 450,
          workWeek: workWeek,
          use24h: true);

      CalendarEvent day(String id, String title, {bool declined = false}) =>
          event(id, DateTime(2026, 10, 27),
              allDay: true,
              length: const Duration(days: 1),
              title: title,
              response:
                  declined ? EventResponse.declined : EventResponse.accepted);

      final one = agenda([day('h', "Ron's birthday")])!;
      expect(one.at, DateTime(2026, 10, 27, 7, 30));
      expect(one.title, 'No meetings today');
      expect(one.body, "All day: Ron's birthday");
      expect(one.lines, ["All day  Ron's birthday"]);
      expect(
          agenda([
            day('t', 'Thanksgiving'),
            day('h', "Ron's birthday"),
            day('x', 'Turned down', declined: true),
          ])?.body,
          'All day: Thanksgiving and 1 more');
      expect(agenda([day('x', 'Turned down', declined: true)]), isNull);
    });

    test('an all-day event on two calendars is named once', () {
      CalendarEvent holiday(String account) => event(
          'h-$account', DateTime(2026, 10, 27),
          allDay: true,
          length: const Duration(days: 1),
          title: 'Thanksgiving',
          accountId: account);
      MorningAgenda? agenda(List<CalendarEvent> events) => morningAgendaFor(
          events,
          now: now,
          minutes: 450,
          workWeek: workWeek,
          use24h: true);

      final quiet = agenda([holiday('hadco'), holiday('gmail')])!;
      expect(quiet.body, 'All day: Thanksgiving');
      expect(quiet.lines, ['All day  Thanksgiving']);
      final busy = agenda([
        holiday('hadco'),
        holiday('gmail'),
        event('m', DateTime(2026, 10, 27, 10), title: 'Stand-up'),
      ])!;
      expect(busy.lines, ['10:00  Stand-up', 'All day  Thanksgiving']);
    });
  });

  // A reminder for all-day events (#68): one a day, however many.
  group('all-day reminders', () {
    CalendarEvent day(String id, DateTime start, String title,
            {int days = 1}) =>
        event(id, start,
            allDay: true, length: Duration(days: days), title: title);

    final events = [
      day('t', DateTime(2026, 10, 27), 'Thanksgiving'),
      day('h', DateTime(2026, 10, 27), "Ron's birthday"),
      day('w', DateTime(2026, 10, 28), 'Fair'),
      event('m', DateTime(2026, 10, 27, 10)),
      event('c', DateTime(2026, 10, 27),
          allDay: true,
          length: const Duration(days: 1),
          title: 'Called off',
          cancelled: true),
    ];

    test('that morning: one for the day, in plain words', () {
      final reminders = allDayRemindersFor(events,
          now: now, minutes: 8 * 60, eveningBefore: false);
      final r = reminders.single;
      expect(r.at, DateTime(2026, 10, 27, 8));
      expect(r.title, "Today: Thanksgiving and 1 more");
      expect(r.body, "Thanksgiving, Ron's birthday");
      expect(r.payload, calendarDayPayload(DateTime(2026, 10, 27)));
      expect(r.until, DateTime(2026, 10, 28), reason: 'gone at its end');
      expect(r.id, allDayReminderId(DateTime(2026, 10, 27)));
      expect(r.id, isNot(allDayReminderId(DateTime(2026, 10, 28))));
    });

    test('the evening before, at the time chosen', () {
      final r = allDayRemindersFor([events[2]],
              now: DateTime(2026, 10, 27, 12),
              minutes: 18 * 60,
              eveningBefore: true)
          .single;
      expect(r.at, DateTime(2026, 10, 27, 18));
      expect(r.title, 'Tomorrow: Fair');
      expect(r.body, 'All day');
      expect(r.until, DateTime(2026, 10, 28),
          reason: '"Tomorrow" is wrong once it is today');
    });

    test('one gone by today is still to go off once; one for a day begun '
        'the evening before is not', () {
      final today = [day('o', DateTime(2026, 10, 26), 'Day off')];
      expect(
          allDayRemindersFor(today,
                  now: now, minutes: 8 * 60, eveningBefore: false)
              .single
              .at,
          DateTime(2026, 10, 26, 8));
      expect(
          allDayRemindersFor(today,
              now: now, minutes: 18 * 60, eveningBefore: true),
          isEmpty);
    });

    test('a stay of several days is told of on its first', () {
      final away = [day('a', DateTime(2026, 10, 26), 'Away', days: 3)];
      expect(
          allDayRemindersFor(away,
              now: DateTime(2026, 10, 27, 6),
              minutes: 8 * 60,
              eveningBefore: false),
          isEmpty);
    });

    // A holiday on two accounts' holiday calendars, say.
    test('the same one on two calendars is named once', () {
      CalendarEvent on(String account, String id, String title) =>
          event(id, DateTime(2026, 10, 27),
              allDay: true,
              length: const Duration(days: 1),
              title: title,
              accountId: account);
      final twice = [
        on('hadco', 't', 'Thanksgiving'),
        on('gmail', 't2', 'Thanksgiving '),
        on('gmail', 'h', "Ron's birthday"),
      ];
      final r = allDayRemindersFor(twice,
              now: now, minutes: 8 * 60, eveningBefore: false)
          .single;
      expect(r.title, 'Today: Thanksgiving and 1 more');
      expect(r.body, "Thanksgiving, Ron's birthday");
      final alone = allDayRemindersFor(twice.take(2),
              now: now, minutes: 8 * 60, eveningBefore: false)
          .single;
      expect(alone.title, 'Today: Thanksgiving');
      expect(alone.body, 'All day');
    });
  });

  group('in a meeting, for quiet mail (#70)', () {
    final start = DateTime(2026, 10, 26, 9, 30);

    test('one you accepted or made, showing you busy or away, under way', () {
      final accepted = event('a', start, length: const Duration(hours: 1));
      expect(inMeetingAt([accepted], now), isTrue);
      expect(
          inMeetingAt([
            event('m', start,
                length: const Duration(hours: 1),
                response: EventResponse.organizer,
                isOrganizer: true,
                organizer: null),
          ], now),
          isTrue,
          reason: 'one of your own');
      expect(
          inMeetingAt([
            CalendarEvent(
              id: 'o',
              accountId: 'hadco',
              title: 'Off site',
              start: start,
              end: start.add(const Duration(hours: 1)),
              response: EventResponse.accepted,
              showAs: EventShowAs.outOfOffice,
            ),
          ], now),
          isTrue);
    });

    test('not before it begins, nor from when it ends', () {
      final meeting = event('a', start, length: const Duration(minutes: 20));
      expect(inMeetingAt([meeting], DateTime(2026, 10, 26, 9, 29)), isFalse);
      expect(inMeetingAt([meeting], DateTime(2026, 10, 26, 9, 30)), isTrue);
      expect(inMeetingAt([meeting], DateTime(2026, 10, 26, 9, 50)), isFalse);
    });

    test('never free, tentative, declined, cancelled, unanswered or a whole '
        'day', () {
      CalendarEvent showing(EventShowAs showAs) => CalendarEvent(
            id: 's',
            accountId: 'hadco',
            title: 'Weekly sync',
            start: start,
            end: start.add(const Duration(hours: 1)),
            response: EventResponse.accepted,
            showAs: showAs,
          );
      expect(
          inMeetingAt([
            showing(EventShowAs.free),
            showing(EventShowAs.tentative),
            showing(EventShowAs.workingElsewhere),
            event('t', start,
                length: const Duration(hours: 1),
                response: EventResponse.tentative),
            event('d', start,
                length: const Duration(hours: 1),
                response: EventResponse.declined),
            event('c', start,
                length: const Duration(hours: 1), cancelled: true),
            event('n', start,
                length: const Duration(hours: 1),
                response: EventResponse.notResponded),
            event('x', start,
                length: const Duration(hours: 1),
                response: EventResponse.none),
            event('w', DateTime(2026, 10, 26),
                allDay: true, length: const Duration(days: 1)),
          ], now),
          isFalse);
    });

    // On a calendar the account follows, "made" and "accepted" are its
    // owner's, not the account's: the family's, or a colleague's.
    test("only the account's own: on another calendar, made or accepted "
        'by its own address; never on one it only reads', () {
      const ron = MailAddress(email: 'ron@hadco.example');
      CalendarEvent on(
        String calendarId, {
        bool readOnly = false,
        bool isOrganizer = false,
        EventResponse response = EventResponse.none,
        MailAddress? organizer = dana,
        List<EventAttendee> attendees = const [],
      }) =>
          CalendarEvent(
            id: 'f',
            accountId: 'hadco',
            calendarId: calendarId,
            title: 'Their meeting',
            start: start,
            end: start.add(const Duration(hours: 1)),
            readOnly: readOnly,
            isOrganizer: isOrganizer,
            response: response,
            organizer: organizer,
            attendees: attendees,
          );
      bool counts(CalendarEvent e) =>
          inMeetingAt([e], now, ownEmails: {'hadco': 'Ron@Hadco.example'});

      expect(
          counts(on('family',
              isOrganizer: true,
              response: EventResponse.organizer,
              organizer:
                  const MailAddress(email: 'family@group.calendar.google'))),
          isFalse,
          reason: "the family calendar's own meeting");
      expect(counts(on('dana', response: EventResponse.accepted)), isFalse,
          reason: "Dana's acceptance, on her calendar");
      expect(counts(on('dana', organizer: ron)), isTrue,
          reason: 'one the account made');
      expect(
          counts(on('dana',
              attendees: const [
                EventAttendee(ron, response: EventResponse.accepted),
              ])),
          isTrue,
          reason: 'one it accepted as itself');
      expect(
          counts(on('dana',
              attendees: const [
                EventAttendee(ron, response: EventResponse.tentative),
              ])),
          isFalse);
      expect(counts(on('holidays', readOnly: true, organizer: ron)), isFalse,
          reason: 'a calendar it only reads');
      expect(
          counts(on(CalendarEvent.mainCalendar,
              response: EventResponse.accepted)),
          isTrue,
          reason: 'its main calendar is its own: its answer, as before');
    });
  });

  group('the calendar widget (#11)', () {
    test("today's and tomorrow's, not over, whole days first", () {
      final shown = widgetMeetings([
        event('over', DateTime(2026, 10, 26, 8)),
        event('later', DateTime(2026, 10, 26, 15)),
        event('tomorrow', DateTime(2026, 10, 27, 10)),
        event('day', DateTime(2026, 10, 27),
            allDay: true, length: const Duration(days: 1)),
        event('after', DateTime(2026, 10, 28, 10)),
        event('no', DateTime(2026, 10, 26, 16),
            response: EventResponse.declined),
      ], now);
      expect([for (final e in shown) e.id], ['later', 'day', 'tomorrow']);
    });

    test('a free whole day on two calendars is one row', () {
      CalendarEvent holiday(String id, String accountId) => CalendarEvent(
            id: id,
            accountId: accountId,
            title: 'Thanksgiving',
            start: DateTime(2026, 10, 26),
            end: DateTime(2026, 10, 27),
            allDay: true,
            showAs: EventShowAs.free,
            readOnly: true,
          );
      final shown = widgetMeetings([
        holiday('g', 'gmail'),
        holiday('h', 'hadco'),
        event('later', DateTime(2026, 10, 26, 15)),
      ], now);
      expect([for (final e in shown) e.id], ['g', 'later']);
    });

    test('a meeting tapped there opens it again', () {
      final e = event('AAMk=+/x', DateTime(2026, 10, 27, 10));
      final link = calendarFromWidgetLink(Uri.parse(calendarWidgetLink(e)))!;
      expect(link.day, DateTime(2026, 10, 27));
      expect(link.meeting!.accountId, 'hadco');
      expect(link.meeting!.eventId, 'AAMk=+/x');
      expect(link.meeting!.end, e.end);
      final calendar = calendarFromWidgetLink(Uri.parse('myemail://calendar'),
          now: now)!;
      expect(calendar.meeting, isNull);
      expect(calendar.day, DateTime(2026, 10, 26));
      expect(calendarFromWidgetLink(Uri.parse('myemail://folder?id=a:INBOX')),
          isNull);
    });
  });

  group('the settings', () {
    const outlook = Account(
      id: 'hadco',
      displayName: 'Hadco',
      emailAddress: 'ron@hadco.example',
      provider: MailProvider.outlook,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF0F6CBD,
    );
    const gmail = Account(
      id: 'gmail',
      displayName: 'Gmail',
      emailAddress: 'ron@gmail.example',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF107C41,
    );

    test("MyEmail reminds of a Microsoft account's meetings, not Google's",
        () {
      const prefs = CalendarPrefs();
      expect(prefs.remindsFor(outlook), isTrue);
      expect(prefs.remindsFor(outlook, inPhoneCalendar: true), isFalse,
          reason: "the phone's calendar reminds of those");
      expect(prefs.remindsFor(gmail), isFalse);
      final switched = prefs.copyWith(
          meetingReminders: {'gmail': true, 'hadco': false});
      expect(switched.remindsFor(gmail), isTrue);
      expect(switched.remindsFor(outlook), isFalse);
    });

    test('kept as text, the agenda at half past seven to begin with', () {
      const prefs = CalendarPrefs();
      expect(prefs.agendaAt, 450);
      final chosen = prefs.copyWith(
          meetingReminders: {'gmail': true}, agendaAt: 8 * 60 + 15);
      expect(CalendarPrefs.tryParse(jsonEncode(chosen.toJson())), chosen);
      final off = chosen.copyWith(noAgenda: true);
      expect(off.agendaAt, isNull);
      expect(CalendarPrefs.tryParse(jsonEncode(off.toJson())), off);
      expect(CalendarPrefs.tryParse('{}')!.agendaAt, 450);
    });

    // A reminder for meetings that have none, and for all-day events (#68).
    test('no reminder of its own, and all-day events: none at first, then '
        'as chosen, and kept', () {
      const prefs = CalendarPrefs();
      expect(prefs.reminderIfNone, isNull);
      expect(prefs.allDayReminder, AllDayReminder.none);
      expect(prefs.toJson().keys, isNot(contains('ifNone')));
      expect(prefs.toJson().keys, isNot(contains('allDay')));

      final chosen = prefs.copyWith(
          reminderIfNone: 10, allDayReminder: AllDayReminder.eveningBefore);
      expect(chosen.allDayReminderMinutes, 18 * 60, reason: '18:00 at first');
      expect(CalendarPrefs.tryParse(jsonEncode(chosen.toJson())), chosen);
      final morning = chosen.copyWith(
          allDayReminder: AllDayReminder.morning, allDayReminderAt: 7 * 60);
      expect(CalendarPrefs.tryParse(jsonEncode(morning.toJson())), morning);
      expect(
          const CalendarPrefs(allDayReminder: AllDayReminder.morning)
              .allDayReminderMinutes,
          8 * 60,
          reason: '8:00 at first');
      expect(chosen.copyWith(noReminderIfNone: true).reminderIfNone, isNull);
      expect(
          CalendarPrefs.tryParse(
              '{"ifNone": 7, "allDay": "noon", "allDayAt": 9999}'),
          const CalendarPrefs(),
          reason: 'what is not a choice is none');
    });
  });

  group('running late', () {
    test('the minutes picked or typed, five where none', () {
      expect(lateMinutesIn('10 min late'), 10);
      expect(lateMinutesIn('about 20'), 20);
      expect(lateMinutesIn(''), 5);
      expect(lateMinutesIn(null), 5);
    });

    test("to the organiser of someone else's, to everyone on your own", () {
      final theirs = event('a', DateTime(2026, 10, 26, 10));
      final draft =
          runningLateDraft(theirs, ownEmail: 'ron@hadco.example', minutes: 10)!;
      expect([for (final a in draft.to) a.email], ['dana@example.com']);
      expect(draft.subject, 'Running late: Weekly sync');
      expect(draft.htmlBody, contains('about 10 minutes'));

      final mine = event('b', DateTime(2026, 10, 26, 10),
          organizer: const MailAddress(email: 'ron@hadco.example'),
          isOrganizer: true,
          attendees: const [EventAttendee(dana)]);
      expect(
          runningLateDraft(mine, ownEmail: 'ron@hadco.example', minutes: 5)!
              .htmlBody,
          contains('please wait for me'));
      final alone = event('c', DateTime(2026, 10, 26, 10),
          organizer: null, isOrganizer: true);
      expect(runningLateDraft(alone, ownEmail: 'ron@hadco.example', minutes: 5),
          isNull);
    });
  });

  test("a Google event on its calendar's own reminders has those minutes",
      () {
    Map<String, Object?> json(Map<String, Object?> reminders) => {
          'id': 'e1',
          'summary': 'Lunch',
          'start': {'dateTime': '2026-10-26T12:00:00Z'},
          'end': {'dateTime': '2026-10-26T13:00:00Z'},
          'reminders': reminders,
        };
    expect(
        GoogleCalendarApi.eventFrom(json({'useDefault': true}), 'g',
                calendarReminder: 10)!
            .reminderMinutes,
        10);
    expect(
        GoogleCalendarApi.eventFrom(
                json({
                  'useDefault': false,
                  'overrides': [
                    {'method': 'popup', 'minutes': 30},
                  ],
                }),
                'g',
                calendarReminder: 10)!
            .reminderMinutes,
        30);
    expect(
        GoogleCalendarApi.eventFrom(json({'useDefault': false}), 'g',
                calendarReminder: 10)!
            .reminderMinutes,
        isNull);
  });
}
