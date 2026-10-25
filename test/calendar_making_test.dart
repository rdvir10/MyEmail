import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/domain/calendar_change.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/found_dates.dart';
import 'package:myemail/domain/meeting.dart';
import 'package:myemail/domain/recurrence.dart';
import 'package:myemail/domain/time_zones.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart' show setInZone;
import 'package:myemail/ui/messages/dated_text.dart';

/// Making meetings (calendar ideas #20 to #24): repeats, reminders, how a
/// meeting shows, zones, and meetings and dates read from text.
void main() {
  // Tuesday 27 October 2026.
  final tue = DateTime(2026, 10, 27, 14);

  group('a repeat', () {
    test('as Graph takes it', () {
      Map<String, Object?> pattern(Recurrence r) =>
          r.toGraph(tue, timeZone: 'Asia/Jerusalem')['pattern']
              as Map<String, Object?>;
      expect(pattern(const Recurrence(RepeatKind.daily, interval: 2)),
          {'type': 'daily', 'interval': 2});
      expect(
        pattern(const Recurrence(RepeatKind.weekly, days: {4})),
        {
          'type': 'weekly',
          'interval': 1,
          'daysOfWeek': ['tuesday', 'thursday'],
          'firstDayOfWeek': 'sunday',
        },
        reason: "the first meeting's own day always among them",
      );
      expect(pattern(const Recurrence(RepeatKind.monthlyOnWeekday)), {
        'type': 'relativeMonthly',
        'interval': 1,
        'daysOfWeek': ['tuesday'],
        'index': 'fourth',
      });
      expect(
        pattern(const Recurrence(RepeatKind.yearly)),
        {'type': 'absoluteYearly', 'interval': 1, 'dayOfMonth': 27, 'month': 10},
      );
      final range = const Recurrence(RepeatKind.daily)
          .ending(day: DateTime(2026, 11, 30))
          .toGraph(tue, timeZone: 'Asia/Jerusalem')['range'];
      expect(range, {
        'type': 'endDate',
        'endDate': '2026-11-30',
        'startDate': '2026-10-27',
        'recurrenceTimeZone': 'Asia/Jerusalem',
      });
      expect(
        (const Recurrence(RepeatKind.daily).ending(times: 5).toGraph(tue,
            timeZone: 'UTC')['range'] as Map)['numberOfOccurrences'],
        5,
      );
    });

    test('as an RRULE, a timed end in UTC and a whole day as its date', () {
      expect(
        const Recurrence(RepeatKind.workDays, days: {7, 1, 2, 3, 4})
            .toRule(tue, allDay: false),
        'RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,SU',
      );
      expect(
        const Recurrence(RepeatKind.weekly, interval: 2, days: {2})
            .toRule(tue, allDay: false),
        'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU',
      );
      expect(const Recurrence(RepeatKind.monthlyOnDate).toRule(tue, allDay: true),
          'RRULE:FREQ=MONTHLY;BYMONTHDAY=27');
      expect(
        const Recurrence(RepeatKind.monthlyOnWeekday)
            .toRule(DateTime(2026, 10, 30), allDay: true),
        'RRULE:FREQ=MONTHLY;BYDAY=-1FR',
        reason: 'the fifth Friday is the last',
      );
      expect(
        const Recurrence(RepeatKind.daily)
            .ending(day: DateTime(2026, 11, 30))
            .toRule(tue, allDay: true),
        'RRULE:FREQ=DAILY;UNTIL=20261130',
      );
      final timed = const Recurrence(RepeatKind.daily)
          .ending(day: DateTime(2026, 11, 30))
          .toRule(tue, allDay: false);
      final stamp = RegExp(r'UNTIL=(\d{8}T\d{6}Z)').firstMatch(timed)![1]!;
      final until = DateTime.parse(stamp);
      expect(until.toLocal(), DateTime(2026, 11, 30, 23, 59, 59),
          reason: 'the end of the last day, written in UTC');
      expect(const Recurrence(RepeatKind.daily).ending(times: 3).toRule(tue, allDay: false),
          'RRULE:FREQ=DAILY;COUNT=3');
    });

    test('said as the screen says it', () {
      expect(
        const Recurrence(RepeatKind.weekly, days: {4})
            .ending(day: DateTime(2026, 11, 30))
            .describe(tue),
        'Every week on Tuesday and Thursday, until 30 November 2026',
      );
      expect(const Recurrence(RepeatKind.monthlyOnWeekday).describe(tue),
          'Every month on the fourth Tuesday');
      expect(const Recurrence(RepeatKind.daily, interval: 3).ending(times: 6).describe(tue),
          'Every 3 days, 6 times');
    });

    test('a last day before the first meeting is caught', () {
      final draft = MeetingDraft(
        accountId: 'a',
        title: 'Stand-up',
        start: tue,
        end: tue.add(const Duration(minutes: 15)),
        recurrence: const Recurrence(RepeatKind.daily)
            .ending(day: DateTime(2026, 10, 1)),
      );
      expect(draft.problem, contains('repeat'));
    });
  });

  group('a new meeting sent with its choices', () {
    MeetingDraft meeting({
      Recurrence? repeat,
      Reminder? reminder,
      EventShowAs? showAs,
      bool private = false,
    }) =>
        MeetingDraft(
          accountId: 'a',
          title: 'Review',
          start: tue,
          end: tue.add(const Duration(hours: 1)),
          timeZone: 'Asia/Jerusalem',
          recurrence: repeat,
          reminder: reminder,
          showAs: showAs,
          isPrivate: private,
        );

    test('to Graph', () {
      final json = GraphCalendarApi.eventJson(meeting(
        repeat: const Recurrence(RepeatKind.weekly),
        reminder: const Reminder.before(30),
        showAs: EventShowAs.outOfOffice,
        private: true,
      ));
      expect((json['recurrence'] as Map)['pattern'], isNotNull);
      expect(json['isReminderOn'], isTrue);
      expect(json['reminderMinutesBeforeStart'], 30);
      expect(json['showAs'], 'oof');
      expect(json['sensitivity'], 'private');

      final plain = GraphCalendarApi.eventJson(meeting());
      expect(plain.containsKey('isReminderOn'), isFalse,
          reason: "the calendar's own reminder");
      expect(plain.containsKey('showAs'), isFalse);
      expect(
          GraphCalendarApi.eventJson(meeting(reminder: const Reminder.none()))[
              'isReminderOn'],
          isFalse);
    });

    test('to Google', () {
      final json = GoogleCalendarApi.eventJson(meeting(
        repeat: const Recurrence(RepeatKind.daily),
        reminder: const Reminder.before(10),
        showAs: EventShowAs.free,
        private: true,
      ));
      expect(json['recurrence'], ['RRULE:FREQ=DAILY']);
      expect(json['reminders'], {
        'useDefault': false,
        'overrides': [
          {'method': 'popup', 'minutes': 10},
        ],
      });
      expect(json['transparency'], 'transparent');
      expect(json['visibility'], 'private');
      expect(
        GoogleCalendarApi.eventJson(meeting(reminder: const Reminder.none()))[
            'reminders'],
        {'useDefault': false, 'overrides': []},
      );
    });

    test('a change of the reminder, how it shows, or privacy', () {
      final before = CalendarEvent(
        id: 'e1',
        accountId: 'a',
        title: 'Review',
        start: tue,
        end: tue.add(const Duration(hours: 1)),
        isOrganizer: true,
        reminderMinutes: 15,
      );
      final change = EventChange.between(
        before,
        notesBefore: const EventNotes(text: ''),
        title: 'Review',
        start: before.start,
        end: before.end,
        allDay: false,
        location: '',
        notes: '',
        attendees: const [],
        reminder: const Reminder.before(15),
        showAs: EventShowAs.free,
        isPrivate: true,
      );
      expect(change.reminder, isNull, reason: 'as it was');
      expect(change.showAs, EventShowAs.free);
      expect(change.isPrivate, isTrue);
      expect(GraphCalendarApi.changeJson(change, before: before),
          {'showAs': 'free', 'sensitivity': 'private'});
      expect(GoogleCalendarApi.changeJson(change, before: before),
          {'transparency': 'transparent', 'visibility': 'private'});
    });

    test('read back: privacy and the zone it was set in', () {
      final graph = GraphCalendarApi.eventFrom({
        'id': 'g',
        'subject': 'x',
        'start': {'dateTime': '2026-10-27T12:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-10-27T13:00:00.0000000', 'timeZone': 'UTC'},
        'sensitivity': 'private',
        'originalStartTimeZone': 'Eastern Standard Time',
      }, 'a')!;
      expect(graph.isPrivate, isTrue);
      expect(graph.timeZone, 'Eastern Standard Time');
      final google = GoogleCalendarApi.eventFrom({
        'id': 'g',
        'start': {'dateTime': '2026-10-27T10:00:00-04:00', 'timeZone': 'America/New_York'},
        'end': {'dateTime': '2026-10-27T11:00:00-04:00', 'timeZone': 'America/New_York'},
        'visibility': 'private',
      }, 'a')!;
      expect(google.isPrivate, isTrue);
      expect(google.timeZone, 'America/New_York');
      expect(CalendarEvent.fromJson(google.toJson()), google);
    });
  });

  group('zones', () {
    test("a clock's figures there and back", () {
      final instant = DateTime.utc(2026, 10, 27, 14);
      final ny = wallClockIn(instant, 'America/New_York');
      expect(ny, DateTime(2026, 10, 27, 10), reason: 'EDT, four hours behind');
      expect(instantIn(ny, 'America/New_York').toUtc(), instant);
      expect(offsetOf('Asia/Kolkata', instant), 'UTC+5:30');
      expect(placeOf('America/New_York'), 'New York');
    });

    test("Exchange's names are known, and each is a zone there is", () {
      expect(ianaZoneOf('Eastern Standard Time'), 'America/New_York');
      expect(ianaZoneOf('Asia/Jerusalem'), 'Asia/Jerusalem');
      expect(ianaZoneOf('Somewhere Standard Time'), isNull);
      for (final name in const [
        'Israel Standard Time',
        'India Standard Time',
        'US Eastern Standard Time',
        'Argentina Standard Time',
        'FLE Standard Time',
        'GMT Standard Time',
      ]) {
        expect(isTimeZone(ianaZoneOf(name)!), isTrue, reason: name);
      }
    });

    test('the sheet names the zone a meeting was set in, when not yours', () {
      final e = CalendarEvent(
        id: 'e',
        accountId: 'a',
        title: 'x',
        start: DateTime.utc(2026, 10, 27, 14).toLocal(),
        end: DateTime.utc(2026, 10, 27, 15).toLocal(),
        timeZone: 'Tokyo Standard Time',
      );
      expect(setInZone(e, 'Europe/London', use24h: true),
          'Set in Tokyo time: 23:00–00:00');
      expect(setInZone(e, 'Asia/Tokyo', use24h: true), isNull,
          reason: 'your own zone');
      expect(
          setInZone(
              CalendarEvent(
                id: 'd',
                accountId: 'a',
                title: 'x',
                start: DateTime(2026, 10, 27),
                end: DateTime(2026, 10, 28),
                allDay: true,
                timeZone: 'Eastern Standard Time',
              ),
              'Asia/Tokyo',
              use24h: true),
          isNull,
          reason: 'a whole day is its date anywhere');
    });

    test('the prefs keep the second zone and the dates in mail', () {
      const prefs = CalendarPrefs(secondZone: 'America/New_York', datesInMail: false);
      expect(CalendarPrefs.fromJson(prefs.toJson()), prefs);
      expect(prefs.copyWith(noSecondZone: true).secondZone, isNull);
      expect(const CalendarPrefs().datesInMail, isTrue);
    });
  });

  group('read from text', () {
    FoundDate at(String line, String words, DateTime when, DateGrain grain) {
      final start = line.indexOf(words);
      return FoundDate(
        start: start,
        end: start + words.length,
        text: words,
        at: when,
        grain: grain,
      );
    }

    test('a meeting typed in a line: title, time and place', () {
      const line = 'Lunch with Dana Thursday 1pm at Café Noir';
      final read = readQuickMeeting(line, [
        at(line, 'Thursday 1pm', DateTime(2026, 10, 29, 13), DateGrain.hour),
      ]);
      expect(read.title, 'Lunch with Dana');
      expect(read.location, 'Café Noir');
      expect(read.start, DateTime(2026, 10, 29, 13));
      expect(read.end, DateTime(2026, 10, 29, 14));
      expect(read.allDay, isFalse);
    });

    test('a second time is when it ends, and the joining words go', () {
      const line = 'Call Yossi on Tuesday from 2pm to 3:30pm';
      final read = readQuickMeeting(line, [
        at(line, 'Tuesday from 2pm', DateTime(2026, 10, 27, 14), DateGrain.hour),
        at(line, '3:30pm', DateTime(2026, 10, 27, 15, 30), DateGrain.minute),
      ]);
      expect(read.title, 'Call Yossi');
      expect(read.end, DateTime(2026, 10, 27, 15, 30));
    });

    test('a day with no time is a whole day; nothing found is the title alone',
        () {
      const line = 'Dentist Friday';
      final read = readQuickMeeting(line, [
        at(line, 'Friday', DateTime(2026, 10, 30, 9), DateGrain.day),
      ]);
      expect(read.title, 'Dentist');
      expect(read.allDay, isTrue);
      expect(read.start, DateTime(2026, 10, 30));
      final none = readQuickMeeting('Think about the budget', const []);
      expect(none.title, 'Think about the budget');
      expect(none.start, isNull);
    });

    test('the dates in a message: links, from today on, never inside one '
        'already', () {
      final now = DateTime(2026, 10, 25);
      final soon = FoundDate(
        start: 0,
        end: 15,
        text: 'Tuesday at 3pm',
        at: DateTime(2026, 10, 27, 15),
        grain: DateGrain.hour,
      );
      final past = FoundDate(
        start: 0,
        end: 6,
        text: 'Monday',
        at: DateTime(2026, 10, 19),
        grain: DateGrain.day,
      );
      final month = FoundDate(
        start: 0,
        end: 7,
        text: 'October',
        at: DateTime(2026, 10, 31),
        grain: DateGrain.month,
      );
      expect(datesWorthLinking([soon, past, month], now: now), [soon]);

      final html = withDateLinks(
        '<p>Shall we meet Tuesday at 3pm?</p>'
        '<p><a href="https://x.example">Tuesday at 3pm</a></p>',
        [soon],
      );
      expect(RegExp('myemail-date:').allMatches(html).length, 1,
          reason: 'not inside the link the message has');
      expect(html, contains('underline dotted'));
      final link = RegExp(r'href="(myemail-date:[^"]+)"').firstMatch(html)![1]!;
      expect(readDateLink(link), (at: DateTime(2026, 10, 27, 15), allDay: false));
      expect(readDateLink('https://x.example'), isNull);
      expect(withDateLinks('<p>Nothing here</p>', [soon]), '<p>Nothing here</p>');
    });

    testWidgets("a plain message's date, tapped, says when", (tester) async {
      DateTime? tapped;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DatedText(
            text: 'Can you do Tuesday at 3pm? Thanks.',
            dates: [
              FoundDate(
                start: 11,
                end: 25,
                text: 'Tuesday at 3pm',
                at: DateTime(2026, 10, 27, 15),
                grain: DateGrain.hour,
              ),
            ],
            onDate: (at, allDay) => tapped = at,
          ),
        ),
      ));
      await tester.tapOnText(find.textRange.ofSubstring('Tuesday at 3pm'));
      await tester.pump();
      expect(tapped, DateTime(2026, 10, 27, 15));
    });
  });
}
