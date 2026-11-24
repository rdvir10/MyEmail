import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/meeting_alerts.dart';
import 'package:myemail/domain/meeting_moment.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;

/// A meeting with times that lasts a day or more, a week's vacation from
/// Monday 8:00 to Friday 8:30, is drawn and told of as Outlook and Google
/// Calendar do it: as a whole day is, in the all-day row, and not as a
/// meeting under way all week. And every event of several days is one bar
/// across them there, as in Outlook's week.
void main() {
  // Monday 23 November 2026 to Friday 27 November.
  final week = [for (var i = 0; i < 5; i++) DateTime(2026, 11, 23 + i)];

  CalendarEvent whole(String id, int from, int days,
          {String? title}) =>
      CalendarEvent(
        id: id,
        accountId: 'hadco',
        title: title ?? id,
        start: week[0].add(Duration(days: from)),
        end: week[0].add(Duration(days: from + days)),
        allDay: true,
        showAs: EventShowAs.free,
      );

  CalendarEvent timed(String id, DateTime start, DateTime end,
          {EventShowAs showAs = EventShowAs.busy,
          EventResponse response = EventResponse.accepted,
          int? reminder = 15}) =>
      CalendarEvent(
        id: id,
        accountId: 'hadco',
        title: id,
        start: start,
        end: end,
        showAs: showAs,
        response: response,
        reminderMinutes: reminder,
        organizer: const MailAddress(email: 'dana@hadco.example'),
      );

  final vacation = timed(
    'vacation',
    DateTime(2026, 11, 23, 8),
    DateTime(2026, 11, 27, 8, 30),
    showAs: EventShowAs.free,
  );

  group('a meeting that lasts a day or more', () {
    test('is one of 24 hours or more with times; a whole day is not', () {
      expect(vacation.lastsADay, isTrue);
      expect(vacation.inAllDayRow, isTrue);
      final day = timed('day', DateTime(2026, 11, 23, 9),
          DateTime(2026, 11, 24, 9));
      expect(day.lastsADay, isTrue, reason: '24 hours exactly');
      final night = timed('night', DateTime(2026, 11, 23, 22),
          DateTime(2026, 11, 24, 6));
      expect(night.lastsADay, isFalse, reason: 'overnight, not a day');
      expect(night.inAllDayRow, isFalse);
      expect(whole('h', 0, 1).lastsADay, isFalse);
      expect(whole('h', 0, 1).inAllDayRow, isTrue);
    });

    test('is listed with the whole days, before the meetings', () {
      final meeting = timed('m', DateTime(2026, 11, 24, 7),
          DateTime(2026, 11, 24, 8));
      expect([
        for (final e in eventsOn(week[1], [meeting, vacation])) e.id,
      ], ['vacation', 'm']);
    });

    test('is never the next meeting over the mail, nor makes mail quiet',
        () {
      final busy = timed('conference', DateTime(2026, 11, 23, 8),
          DateTime(2026, 11, 25, 17));
      final sync = timed('sync', DateTime(2026, 11, 24, 10),
          DateTime(2026, 11, 24, 10, 30));
      expect(nextMeeting([vacation, busy], DateTime(2026, 11, 24, 9)),
          isNull);
      expect(nextMeeting([vacation, busy], DateTime(2026, 11, 23, 7, 50)),
          isNull,
          reason: 'not as it is about to begin either');
      expect(nextMeeting([vacation, busy, sync], DateTime(2026, 11, 24, 9, 50))
          ?.id, 'sync');
      expect(inMeetingAt([busy], DateTime(2026, 11, 24, 12)), isFalse);
    });

    test('still has its own reminder before it begins', () {
      final reminders = meetingRemindersFor([vacation],
          now: DateTime(2026, 11, 23, 7), use24h: true);
      expect(reminders.single.at, DateTime(2026, 11, 23, 7, 45));
    });

    test('has no Join now, Running late or countdown on its sheet', () {
      final online = CalendarEvent(
        id: 'o',
        accountId: 'hadco',
        title: 'Hackathon',
        start: DateTime(2026, 11, 23, 8),
        end: DateTime(2026, 11, 25, 18),
        joinUrl: 'https://teams.microsoft.com/l/x',
      );
      expect(meetingIsNear(online, DateTime(2026, 11, 24, 12)), isFalse);
      expect(timeToStart(online, DateTime(2026, 11, 24, 12)), isNull);
      expect(timeToStart(online, DateTime(2026, 11, 23, 7)), isNull);
    });

    test('is in the morning agenda as a whole day, not a meeting', () {
      final agenda = morningAgendaFor([vacation],
          now: DateTime(2026, 11, 23, 6),
          minutes: 7 * 60 + 30,
          workWeek: const {1, 2, 3, 4, 5},
          use24h: true)!;
      expect(agenda.title, 'No meetings today');
      expect(agenda.lines, ['From 08:00  vacation']);
      final later = morningAgendaFor([vacation],
          now: DateTime(2026, 11, 25, 6),
          minutes: 7 * 60 + 30,
          workWeek: const {1, 2, 3, 4, 5},
          use24h: true)!;
      expect(later.lines, ['All day  vacation']);
      final last = morningAgendaFor([vacation],
          now: DateTime(2026, 11, 27, 6),
          minutes: 7 * 60 + 30,
          workWeek: const {1, 2, 3, 4, 5},
          use24h: true)!;
      expect(last.lines, ['Until 08:30  vacation']);
    });

    test('says when it is on each day: from, all day, until', () {
      String said(DateTime day) => timesOnDay(vacation, day, use24h: true);
      expect(said(week[0]), 'From 08:00');
      expect(said(week[2]), 'All day');
      expect(said(week[4]), 'Until 08:30');
      final meeting = timed('m', DateTime(2026, 11, 24, 7),
          DateTime(2026, 11, 24, 8));
      expect(timesOnDay(meeting, week[1], use24h: true), '07:00–08:00',
          reason: 'a meeting as before');
      expect(timesOnDay(whole('h', 1, 1), week[1], use24h: true), 'All day');
    });

    test('is listed with the whole days on the widget, first on its day', () {
      final meeting = timed('m', DateTime(2026, 11, 23, 7),
          DateTime(2026, 11, 23, 7, 30));
      expect([
        for (final e
            in widgetMeetings([meeting, vacation], DateTime(2026, 11, 23, 6)))
          e.id,
      ], ['vacation', 'm']);
    });
  });

  group('the All day row, as bars across the days', () {
    List<String> lanes(List<DayBar> bars) => [
          for (final b in bars) '${b.event.id} ${b.first}-${b.last} ${b.lane}',
        ];

    test("Outlook's week: each event one bar, in the first row it fits", () {
      final bars = layOutDayBars(week, [
        whole('hotel2', 0, 2, title: 'Stay at Hampton Inn'),
        vacation,
        whole('thanksgiving', 3, 1),
        whole('evan', 0, 3, title: 'Evan surgery'),
        whole('hotel1', 0, 3, title: 'Stay at Hampton Inn'),
        whole('after', 4, 1),
        timed('sync', DateTime(2026, 11, 24, 10),
            DateTime(2026, 11, 24, 10, 30)),
      ]);
      expect(lanes(bars), [
        'evan 0-2 0',
        'hotel1 0-2 1',
        'hotel2 0-1 2',
        'vacation 0-4 3',
        'thanksgiving 3-3 0',
        'after 4-4 0',
      ], reason: 'a meeting of half an hour is not a bar');
    });

    test('one begun before the days shown, or going on after them, runs '
        'from the first column or to the last', () {
      final long = whole('long', -2, 10);
      expect(lanes(layOutDayBars(week, [long])), ['long 0-4 0']);
    });

    test('in Day, each is a row of its own', () {
      final bars = layOutDayBars([week[1]], [
        whole('a', 1, 1),
        whole('b', 0, 3),
        vacation,
      ]);
      expect(lanes(bars), ['b 0-0 0', 'vacation 0-0 1', 'a 0-0 2']);
    });

    test('the work week alone, with a day left out, still spans it', () {
      // Monday, Wednesday and Friday shown.
      final days = [week[0], week[2], week[4]];
      expect(
          lanes(layOutDayBars(days, [
            whole('mon-tue', 0, 2),
            whole('tue', 1, 1),
            whole('tue-wed', 1, 2),
          ])),
          ['mon-tue 0-0 0', 'tue-wed 1-1 0'],
          reason: 'one on a day not shown has no bar');
    });

    test('the same events laid out the same, whatever order they come in',
        () {
      final events = [
        whole('x', 0, 2, title: 'Same'),
        whole('y', 0, 2, title: 'Same'),
        whole('z', 1, 1),
      ];
      expect(lanes(layOutDayBars(week, events)),
          lanes(layOutDayBars(week, events.reversed)));
    });
  });
}
