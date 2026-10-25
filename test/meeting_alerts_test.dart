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
            event('d', DateTime(2026, 10, 27),
                allDay: true, length: const Duration(days: 1)),
          ], now: now, minutes: 450, workWeek: workWeek, use24h: true),
          isNull);
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
