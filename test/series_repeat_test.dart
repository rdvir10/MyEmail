import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/contacts/device_contacts.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/mail_engine.dart' show CalendarRefused;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_change.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/recurrence.dart';
import 'package:myemail/domain/series_repeat.dart';
import 'package:myemail/domain/time_zones.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/contact_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/meetings/meeting_options.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';

import 'fakes/fake_webview.dart';

/// Changing how a series repeats, or making a meeting repeat (calendar
/// idea #55): what Edit reads of a series' repeat, what each calendar is
/// sent, and what the screen says before it is saved.
///
/// Nothing here reads the PC's own clock: a series' times are worked out
/// on its own zone's, as Ron's phone would, wherever the tests run.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});

  Map<String, Object?> bodyOf(http.Request r) =>
      (jsonDecode(r.body) as Map).cast<String, Object?>();

  // 1 September 2026 is a Tuesday; so are 13 and 27 October.
  final firstTuesday = DateTime(2026, 9, 1);

  const jerusalem = 'Asia/Jerusalem';
  const newYork = 'America/New_York';

  /// A weekly series on Tuesdays at 09:00 Jerusalem time, its first
  /// meeting on 1 September 2026, as a calendar gives its times: instants.
  final jerusalemSeries = (
    start: instantIn(DateTime(2026, 9, 1, 9), jerusalem).toUtc(),
    end: instantIn(DateTime(2026, 9, 1, 10), jerusalem).toUtc(),
    allDay: false,
  );

  /// What a guest in [zone] sees of a meeting written [sentStart] on
  /// [sentZone]'s clock, on [day].
  DateTime seenIn(String zone, DateTime day, DateTime sentStart,
          String sentZone) =>
      wallClockIn(
        instantIn(
          DateTime(day.year, day.month, day.day, sentStart.hour,
              sentStart.minute),
          sentZone,
        ),
        zone,
      );

  group('a series read', () {
    Map<String, Object?> graph(
      Map<String, Object?> pattern, [
      Map<String, Object?> range = const {'type': 'noEnd'},
    ]) =>
        {
          'pattern': pattern,
          'range': {
            'startDate': '2026-09-01',
            'recurrenceTimeZone': 'Israel Standard Time',
            ...range,
          },
        };

    test('from Graph, as New meeting would have made it', () {
      final weekly = SeriesRepeat.fromGraph(graph(
        {
          'type': 'weekly',
          'interval': 1,
          'daysOfWeek': ['tuesday', 'thursday'],
          'firstDayOfWeek': 'sunday',
        },
        {'type': 'endDate', 'endDate': '2026-11-30'},
      ))!;
      expect(weekly.firstDay, firstTuesday);
      expect(
        weekly.repeat,
        Recurrence(RepeatKind.weekly,
            days: const {2, 4}, until: DateTime(2026, 11, 30)),
      );

      expect(
        SeriesRepeat.fromGraph(graph(
          {'type': 'daily', 'interval': 1},
          {'type': 'numbered', 'numberOfOccurrences': 10},
        ))!.repeat,
        const Recurrence(RepeatKind.daily, count: 10),
      );
      expect(
        SeriesRepeat.fromGraph(graph({
          'type': 'weekly',
          'interval': 2,
          'daysOfWeek': ['tuesday'],
          'firstDayOfWeek': 'sunday',
        }))!
            .repeat,
        const Recurrence(RepeatKind.weekly, interval: 2, days: {2}),
      );
      expect(
        SeriesRepeat.fromGraph(graph(
                {'type': 'absoluteMonthly', 'interval': 1, 'dayOfMonth': 1}))!
            .repeat,
        const Recurrence(RepeatKind.monthlyOnDate),
      );
      expect(
        SeriesRepeat.fromGraph(graph({
          'type': 'relativeMonthly',
          'interval': 1,
          'daysOfWeek': ['tuesday'],
          'index': 'first',
        }))!
            .repeat,
        const Recurrence(RepeatKind.monthlyOnWeekday),
      );
      expect(
        SeriesRepeat.fromGraph(graph({
          'type': 'absoluteYearly',
          'interval': 1,
          'dayOfMonth': 1,
          'month': 9,
        }))!
            .repeat,
        const Recurrence(RepeatKind.yearly),
      );
    });

    test('from Graph, one the menu has no item for is a series all the '
        'same, its repeat not to be shown', () {
      for (final pattern in [
        {'type': 'relativeYearly', 'interval': 1, 'month': 9},
        {'type': 'absoluteMonthly', 'interval': 1, 'dayOfMonth': 15},
        {
          'type': 'weekly',
          'interval': 2,
          'daysOfWeek': ['tuesday'],
          'firstDayOfWeek': 'monday',
        },
        {'type': 'absoluteYearly', 'interval': 2, 'dayOfMonth': 1, 'month': 9},
        // Intervals the menu has no item for (#55, review).
        {
          'type': 'weekly',
          'interval': 3,
          'daysOfWeek': ['tuesday'],
          'firstDayOfWeek': 'sunday',
        },
        {'type': 'daily', 'interval': 2},
        {'type': 'absoluteMonthly', 'interval': 3, 'dayOfMonth': 1},
        {
          'type': 'relativeMonthly',
          'interval': 2,
          'daysOfWeek': ['tuesday'],
          'index': 'first',
        },
        {
          'type': 'weekly',
          'interval': 1.5,
          'daysOfWeek': ['tuesday'],
        },
        {
          'type': 'weekly',
          'interval': '1',
          'daysOfWeek': ['tuesday'],
        },
        {
          'type': 'weekly',
          'daysOfWeek': ['tuesday'],
        },
      ]) {
        final read = SeriesRepeat.fromGraph(graph(pattern));
        expect(read, isNotNull, reason: '$pattern');
        expect(read!.repeat, isNull, reason: '$pattern');
        expect(read.firstDay, firstTuesday);
      }
      expect(SeriesRepeat.fromGraph(null), isNull, reason: 'one on its own');
      expect(SeriesRepeat.fromGraph({'pattern': 'nonsense'}), isNull);
    });

    test('from Google, its rule and its first day, its end read on its own '
        'clock', () {
      // Google writes a timed UNTIL as the end of the last day, in UTC.
      String untilOf(DateTime lastDay, String zone) {
        final end = instantIn(
                DateTime(lastDay.year, lastDay.month, lastDay.day, 23, 59, 59),
                zone)
            .toUtc();
        String two(int v) => '$v'.padLeft(2, '0');
        return '${end.year}${two(end.month)}${two(end.day)}T'
            '${two(end.hour)}${two(end.minute)}${two(end.second)}Z';
      }

      final weekly = SeriesRepeat.fromGoogle({
        'start': {
          'dateTime': '2026-09-01T09:00:00+03:00',
          'timeZone': jerusalem,
        },
        'recurrence': [
          'EXDATE;TZID=Asia/Jerusalem:20260915T090000',
          'RRULE:FREQ=WEEKLY;BYDAY=TU,TH;'
              'UNTIL=${untilOf(DateTime(2026, 11, 30), jerusalem)}',
        ],
      })!;
      expect(weekly.firstDay, firstTuesday);
      expect(
        weekly.repeat,
        Recurrence(RepeatKind.weekly,
            days: const {2, 4}, until: DateTime(2026, 11, 30)),
      );

      // A series set in Los Angeles ends at its own midnight: 07:59:59 UTC
      // the next day, which read on a phone in Jerusalem was 1 December.
      expect(
        SeriesRepeat.fromGoogle({
          'start': {
            'dateTime': '2026-09-01T09:00:00-07:00',
            'timeZone': 'America/Los_Angeles',
          },
          'recurrence': ['RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261201T075959Z'],
        })!
            .repeat
            ?.until,
        DateTime(2026, 11, 30),
      );

      Recurrence? rule(String line, {String date = '2026-09-01'}) =>
          SeriesRepeat.fromGoogle({
            'start': {'date': date},
            'recurrence': [line],
          })?.repeat;
      expect(rule('RRULE:FREQ=DAILY;COUNT=5'),
          const Recurrence(RepeatKind.daily, count: 5));
      expect(rule('RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU'),
          const Recurrence(RepeatKind.weekly, interval: 2, days: {2}));
      expect(rule('RRULE:FREQ=MONTHLY;BYMONTHDAY=1'),
          const Recurrence(RepeatKind.monthlyOnDate));
      // 29 September 2026 is the month's last Tuesday.
      expect(rule('RRULE:FREQ=MONTHLY;BYDAY=-1TU', date: '2026-09-29'),
          const Recurrence(RepeatKind.monthlyOnWeekday));
      expect(rule('RRULE:FREQ=YEARLY;UNTIL=20300901'),
          Recurrence(RepeatKind.yearly, until: DateTime(2030, 9, 1)));
      for (final unknown in [
        'RRULE:FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2',
        'RRULE:FREQ=MONTHLY;BYMONTHDAY=15',
        'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;WKST=SU',
        'RRULE:FREQ=HOURLY',
        // Intervals the menu has no item for (#55, review).
        'RRULE:FREQ=WEEKLY;INTERVAL=3;BYDAY=TU',
        'RRULE:FREQ=DAILY;INTERVAL=2',
        'RRULE:FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1',
        'RRULE:FREQ=WEEKLY;INTERVAL=1.5;BYDAY=TU',
      ]) {
        expect(rule(unknown), isNull, reason: unknown);
      }
      for (final added in ['RDATE:20260903', 'EXRULE:FREQ=WEEKLY;BYDAY=TU']) {
        expect(
          SeriesRepeat.fromGoogle({
            'start': {'date': '2026-09-01'},
            'recurrence': ['RRULE:FREQ=WEEKLY', added],
          })?.repeat,
          isNull,
          reason: '$added is more than New meeting shows',
        );
      }
      expect(SeriesRepeat.fromGoogle({'start': {'date': '2026-09-01'}}),
          isNull);
    });

    test('a meeting is changed on its own clock, where that is known', () {
      CalendarEvent at(String? zone, {bool allDay = false}) => CalendarEvent(
            id: 'e',
            accountId: 'a',
            title: 't',
            start: DateTime(2026, 10, 1, 9),
            end: DateTime(2026, 10, 1, 10),
            allDay: allDay,
            timeZone: zone,
          );
      expect(ownZoneOf(at('Israel Standard Time')), jerusalem);
      expect(ownZoneOf(at(jerusalem)), jerusalem);
      expect(ownZoneOf(at(null)), isNull);
      expect(ownZoneOf(at('Somewhere Standard Time')), isNull);
    });
  });

  group('the first meeting of a series changed', () {
    test('is the first day on or after its own that the repeat falls on', () {
      expect(
        firstDayOf(const Recurrence(RepeatKind.weekly, days: {3}),
            firstTuesday),
        DateTime(2026, 9, 2),
      );
      expect(
        firstDayOf(const Recurrence(RepeatKind.weekly, days: {1, 5}),
            firstTuesday),
        DateTime(2026, 9, 4),
      );
      expect(
          firstDayOf(const Recurrence(RepeatKind.weekly), firstTuesday),
          firstTuesday,
          reason: 'its own day, with none picked');
      expect(
          firstDayOf(const Recurrence(RepeatKind.monthlyOnDate),
              firstTuesday),
          firstTuesday);
    });

    test('every other week: inside the series\' first counting week, so it '
        'stays in the weeks it was in', () {
      // The week of 1 September starts on Sunday 30 August for Outlook,
      // Monday 31 August for Google.
      DateTime moved(Set<int> days, int weekStart) => firstDayOf(
          Recurrence(RepeatKind.weekly, interval: 2, days: days),
          firstTuesday,
          weekStart: weekStart);
      for (final weekStart in [DateTime.sunday, DateTime.monday]) {
        expect(moved({1}, weekStart), DateTime(2026, 8, 31),
            reason: 'Tuesday to Monday, the day before, not the week after');
        expect(moved({4}, weekStart), DateTime(2026, 9, 3),
            reason: 'Tuesday to Thursday');
      }
      expect(moved({7}, DateTime.sunday), DateTime(2026, 8, 30),
          reason: "Sunday opens Outlook's week");
      expect(moved({7}, DateTime.monday), DateTime(2026, 9, 6),
          reason: "Sunday closes Google's");
    });

    test('a series set in Jerusalem, changed on a phone in New York, stays '
        "on Jerusalem's clock: Jerusalem sees 09:00 whatever the two "
        'countries\' clocks do', () {
      final sent = forSeries(
        EventChange(
          repeat: Recurrence(RepeatKind.weekly,
              days: const {2}, until: DateTime(2027, 6, 29)),
          timeZone: newYork,
        ),
        jerusalemSeries,
        zone: jerusalem,
      );
      expect(sent.timeZone, jerusalem);
      expect(sent.start, DateTime(2026, 9, 1, 9));
      expect(sent.end, DateTime(2026, 9, 1, 10));
      for (final day in [
        DateTime(2026, 11, 17),
        // Mid-March, the US on summer time and Israel not yet.
        DateTime(2027, 3, 16),
        // Early November, Israel back on winter time and the US not yet.
        DateTime(2027, 11, 2),
      ]) {
        expect(seenIn(jerusalem, day, sent.start!, sent.timeZone!).hour, 9,
            reason: '$day');
      }
      // A Jerusalem meeting moves for New York with the clocks.
      expect(seenIn(newYork, DateTime(2026, 11, 17), sent.start!,
              sent.timeZone!)
          .hour, 2);
      expect(seenIn(newYork, DateTime(2027, 3, 16), sent.start!,
              sent.timeZone!)
          .hour, 3);
    });

    test('a time changed for every meeting is the time picked, read on the '
        "series' own clock", () {
      // 03:00 in New York on 17 November is 10:00 in Jerusalem.
      final sent = forSeries(
        EventChange(
          start: instantIn(DateTime(2026, 11, 17, 3), newYork),
          end: instantIn(DateTime(2026, 11, 17, 3, 45), newYork),
          allDay: false,
          timeZone: newYork,
        ),
        jerusalemSeries,
        zone: jerusalem,
      );
      expect(sent.timeZone, jerusalem);
      expect(sent.start, DateTime(2026, 9, 1, 10));
      expect(sent.end, DateTime(2026, 9, 1, 10, 45));
    });

    test('moves the series to its first new day, at its own time unless the '
        'time changes too; a new end alone leaves it where it is', () {
      const wednesdays = Recurrence(RepeatKind.weekly, days: {3});
      final days = forSeries(const EventChange(repeat: wednesdays),
          jerusalemSeries,
          zone: jerusalem);
      expect(days.start, DateTime(2026, 9, 2, 9));
      expect(days.end, DateTime(2026, 9, 2, 10));
      expect(days.repeat, wednesdays);

      final ends = forSeries(
        EventChange(
          repeat: Recurrence(RepeatKind.weekly,
              days: const {2}, until: DateTime(2026, 12, 29)),
        ),
        jerusalemSeries,
        zone: jerusalem,
      );
      expect(ends.start, DateTime(2026, 9, 1, 9));
    });

    test("the last meeting, from the repeat's end", () {
      expect(
        lastMeetingOf(const Recurrence(RepeatKind.weekly, days: {2}, count: 10),
            firstTuesday),
        DateTime(2026, 11, 3),
      );
      expect(
        lastMeetingOf(
            Recurrence(RepeatKind.weekly,
                days: const {2, 4}, until: DateTime(2026, 9, 9)),
            firstTuesday),
        DateTime(2026, 9, 8),
      );
      expect(
        lastMeetingOf(
            const Recurrence(RepeatKind.weekly, interval: 2, days: {2},
                count: 3),
            firstTuesday),
        DateTime(2026, 9, 29),
      );
      expect(
        lastMeetingOf(const Recurrence(RepeatKind.monthlyOnWeekday, count: 2),
            firstTuesday),
        DateTime(2026, 10, 6),
        reason: "October's first Tuesday",
      );
      expect(lastMeetingOf(const Recurrence(RepeatKind.daily), firstTuesday),
          isNull,
          reason: 'none: it goes on');
      expect(dayInWords(DateTime(2026, 11, 3)), '3 November 2026');
    });
  });

  group('on a Microsoft calendar', () {
    late List<http.Request> sent;

    GraphCalendarApi api([http.Response Function(http.Request)? answer]) {
      sent = [];
      return GraphCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          return answer?.call(request) ?? json({});
        }),
        sleep: (_) async {},
      );
    }

    final single = CalendarEvent(
      id: 'e1',
      accountId: 'a',
      title: 'Stand-up',
      start: DateTime(2026, 10, 1, 9),
      end: DateTime(2026, 10, 1, 9, 15),
      isOrganizer: true,
      response: EventResponse.organizer,
    );

    test('a meeting made to repeat is sent the repeat from its own day', () {
      final body = GraphCalendarApi.changeJson(
        const EventChange(
          repeat: Recurrence(RepeatKind.weekly, days: {1}),
          timeZone: jerusalem,
        ),
        before: single,
      );
      expect(body.keys, ['recurrence']);
      expect(body['recurrence'], {
        'pattern': {
          'type': 'weekly',
          'interval': 1,
          'daysOfWeek': ['monday', 'thursday'],
          'firstDayOfWeek': 'sunday',
        },
        'range': {
          'type': 'noEnd',
          'startDate': '2026-10-01',
          'recurrenceTimeZone': jerusalem,
        },
      });
    });

    test("the Jerusalem series is sent on Jerusalem's clock", () {
      final body = GraphCalendarApi.changeJson(
        forSeries(
          EventChange(
            repeat: Recurrence(RepeatKind.weekly,
                days: const {2}, until: DateTime(2027, 6, 29)),
            timeZone: newYork,
          ),
          jerusalemSeries,
          zone: jerusalem,
        ),
        before: single,
      );
      expect(body['start'], {
        'dateTime': '2026-09-01T09:00:00',
        'timeZone': jerusalem,
      });
      final range = (body['recurrence']! as Map)['range'] as Map;
      expect(range['recurrenceTimeZone'], jerusalem);
      expect(range['startDate'], '2026-09-01');
    });

    test("Edit reads a series' repeat with its notes", () async {
      final notes = await api((_) => json({
            'id': 'series-1',
            'body': {'contentType': 'text', 'content': 'Agenda'},
            'recurrence': {
              'pattern': {
                'type': 'weekly',
                'interval': 1,
                'daysOfWeek': ['tuesday'],
              },
              'range': {'type': 'noEnd', 'startDate': '2026-09-01'},
            },
          })).notes('series-1');
      expect(sent.single.url.queryParameters[r'$select'],
          contains('recurrence'));
      expect(notes.text, 'Agenda');
      expect(notes.repeat?.repeat,
          const Recurrence(RepeatKind.weekly, days: {2}));
      expect(notes.repeat?.firstDay, firstTuesday);
    });
  });

  group('on a Google calendar', () {
    late List<http.Request> sent;

    GoogleCalendarApi api(Map<String, Object?> event) {
      sent = [];
      return GoogleCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          if (request.method == 'GET') return json(event);
          return json({});
        }),
        sleep: (_) async {},
      );
    }

    final single = CalendarEvent(
      id: 'g1',
      accountId: 'g',
      title: 'Stand-up',
      start: DateTime(2026, 10, 1, 9),
      end: DateTime(2026, 10, 1, 9, 15),
      isOrganizer: true,
      response: EventResponse.organizer,
    );

    test('a meeting made to repeat is sent its rule, and its times with the '
        'zone Google wants of a series', () {
      final body = GoogleCalendarApi.changeJson(
        const EventChange(repeat: Recurrence(RepeatKind.daily, count: 5)),
        before: single,
      );
      expect(body['recurrence'], ['RRULE:FREQ=DAILY;COUNT=5']);
      expect((body['start'] as Map)['timeZone'], 'UTC',
          reason: 'with no zone from the phone');
      expect(
        DateTime.parse((body['start'] as Map)['dateTime'] as String)
            .isAtSameMomentAs(single.start),
        isTrue,
      );
      expect(
        DateTime.parse((body['end'] as Map)['dateTime'] as String)
            .isAtSameMomentAs(single.end),
        isTrue,
      );
    });

    test("the Jerusalem series is sent on Jerusalem's clock, and ends at "
        "Jerusalem's midnight", () {
      final body = GoogleCalendarApi.changeJson(
        forSeries(
          EventChange(
            repeat: Recurrence(RepeatKind.weekly,
                days: const {2}, until: DateTime(2027, 6, 29)),
            timeZone: newYork,
          ),
          jerusalemSeries,
          zone: jerusalem,
          weekStart: DateTime.monday,
        ),
        before: single,
      );
      expect(body['start'], {
        'dateTime': '2026-09-01T09:00:00',
        'timeZone': jerusalem,
        'date': null,
      });
      // 23:59:59 on 29 June 2027 in Jerusalem, on summer time: 20:59:59 UTC.
      expect(body['recurrence'],
          ['RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20270629T205959Z']);
    });

    test('a series keeps the days taken out of it by hand', () async {
      await api({
        'id': 'series-1',
        'recurrence': [
          'RRULE:FREQ=WEEKLY;BYDAY=TU',
          'EXDATE;TZID=Asia/Jerusalem:20260915T140000',
        ],
      }).update(
        'series-1',
        EventChange(
          start: DateTime(2026, 9, 1, 14),
          end: DateTime(2026, 9, 1, 15),
          allDay: false,
          timeZone: jerusalem,
          repeat: Recurrence(RepeatKind.weekly,
              days: const {2}, until: DateTime(2026, 12, 29)),
        ),
        before: single,
      );
      final body = bodyOf(sent.last);
      expect(sent.last.method, 'PATCH');
      expect(body['recurrence'], [
        startsWith('RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL='),
        'EXDATE;TZID=Asia/Jerusalem:20260915T140000',
      ]);
      expect(body['start'], {
        'dateTime': '2026-09-01T14:00:00',
        'timeZone': jerusalem,
        'date': null,
      });
    });

    test("Edit reads a series' repeat with its notes", () async {
      final notes = await api({
        'id': 'series-1',
        'status': 'confirmed',
        'description': 'Agenda',
        'start': {
          'dateTime': '2026-09-01T14:00:00+03:00',
          'timeZone': jerusalem,
        },
        'recurrence': ['RRULE:FREQ=WEEKLY;BYDAY=TU'],
      }).notes('series-1');
      expect(notes.text, 'Agenda');
      expect(notes.repeat?.repeat,
          const Recurrence(RepeatKind.weekly, days: {2}));
      expect(notes.repeat?.firstDay, firstTuesday);
    });
  });

  group('through the account', () {
    const microsoft = Account(
      id: 'a',
      displayName: 'Hadco',
      emailAddress: 'ron@hadco.example',
      provider: MailProvider.outlook,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF0F6CBD,
    );
    const gmail = Account(
      id: 'g',
      displayName: 'Gmail',
      emailAddress: 'ron@gmail.example',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.oauth,
      colorValue: 0xFF007258,
    );
    late List<http.Request> sent;

    /// Graph's master of the Jerusalem series, its times in UTC as asked.
    Map<String, Object?> graphMaster() {
      String utc(DateTime wall) {
        final u = instantIn(wall, jerusalem).toUtc();
        String two(int v) => '$v'.padLeft(2, '0');
        return '${u.year}-${two(u.month)}-${two(u.day)}T'
            '${two(u.hour)}:${two(u.minute)}:${two(u.second)}.0000000';
      }

      return {
        'id': 'series-1',
        'start': {'dateTime': utc(DateTime(2026, 9, 1, 9)), 'timeZone': 'UTC'},
        'end': {'dateTime': utc(DateTime(2026, 9, 1, 10)), 'timeZone': 'UTC'},
        'isAllDay': false,
        'type': 'seriesMaster',
      };
    }

    /// Google's recurring event of the Jerusalem series.
    const googleMaster = {
      'id': 'series-1',
      'status': 'confirmed',
      'start': {
        'dateTime': '2026-09-01T09:00:00+03:00',
        'timeZone': jerusalem,
      },
      'end': {
        'dateTime': '2026-09-01T10:00:00+03:00',
        'timeZone': jerusalem,
      },
      'recurrence': ['RRULE:FREQ=WEEKLY;BYDAY=TU'],
    };

    AccountCalendar calendar(Map<String, Object?> master) {
      sent = [];
      return AccountCalendar(
        accessToken: (id, {bool force = false, List<String>? scopes}) async =>
            'token',
        accounts: () => const [microsoft, gmail],
        httpClient: http_testing.MockClient((r) async {
          sent.add(r);
          return r.method == 'GET' ? json(master) : json({});
        }),
        sleep: (_) async {},
      );
    }

    /// One meeting of it, as the calendar view has it: on 27 October, its
    /// zone as each calendar names it.
    CalendarEvent occurrence(String accountId, String? zone) => CalendarEvent(
          id: 'occurrence-8',
          accountId: accountId,
          title: 'Review',
          start: instantIn(DateTime(2026, 10, 27, 9), jerusalem),
          end: instantIn(DateTime(2026, 10, 27, 10), jerusalem),
          isOrganizer: true,
          response: EventResponse.organizer,
          seriesId: 'series-1',
          timeZone: zone,
        );

    test('Outlook: every meeting moved to new days on a phone in New York, '
        "the series moved to its first new day on Jerusalem's clock",
        () async {
      final c = calendar(graphMaster());
      await c.updateEvent(
        microsoft,
        occurrence('a', 'Israel Standard Time'),
        const EventChange(
          repeat: Recurrence(RepeatKind.weekly, days: {3}),
          timeZone: newYork,
        ),
        wholeSeries: true,
      );
      final patch = sent.last;
      expect(patch.method, 'PATCH');
      expect(patch.url.path, endsWith('/events/series-1'));
      final body = bodyOf(patch);
      expect(body['start'], {
        'dateTime': '2026-09-02T09:00:00',
        'timeZone': jerusalem,
      });
      expect(body['end'], {
        'dateTime': '2026-09-02T10:00:00',
        'timeZone': jerusalem,
      });
      final recurrence = body['recurrence']! as Map;
      expect((recurrence['pattern'] as Map)['daysOfWeek'], ['wednesday']);
      expect((recurrence['range'] as Map)['startDate'], '2026-09-02');
      expect((recurrence['range'] as Map)['recurrenceTimeZone'], jerusalem);
      for (final day in [DateTime(2027, 3, 17), DateTime(2027, 11, 3)]) {
        expect(
          seenIn(jerusalem, day, DateTime(2026, 9, 2, 9),
                  (body['start'] as Map)['timeZone'] as String)
              .hour,
          9,
          reason: '$day',
        );
      }
    });

    test('Google: the same, on its own clock', () async {
      final c = calendar(googleMaster);
      await c.updateEvent(
        gmail,
        occurrence('g', jerusalem),
        const EventChange(
          repeat: Recurrence(RepeatKind.weekly, days: {3}),
          timeZone: newYork,
        ),
        wholeSeries: true,
      );
      final body = bodyOf(sent.last);
      expect(sent.last.method, 'PATCH');
      expect(body['start'], {
        'dateTime': '2026-09-02T09:00:00',
        'timeZone': jerusalem,
        'date': null,
      });
      expect(body['recurrence'], ['RRULE:FREQ=WEEKLY;BYDAY=WE']);
    });

    test('every other week moved to Sunday: the week before for Outlook, '
        'whose week starts on Sunday; the week after for Google', () async {
      const sundays = Recurrence(RepeatKind.weekly, interval: 2, days: {7});
      var c = calendar(graphMaster());
      await c.updateEvent(
        microsoft,
        occurrence('a', 'Israel Standard Time'),
        const EventChange(repeat: sundays),
        wholeSeries: true,
      );
      expect((bodyOf(sent.last)['start'] as Map)['dateTime'],
          '2026-08-30T09:00:00');
      c = calendar(googleMaster);
      await c.updateEvent(
        gmail,
        occurrence('g', jerusalem),
        const EventChange(repeat: sundays),
        wholeSeries: true,
      );
      expect((bodyOf(sent.last)['start'] as Map)['dateTime'],
          '2026-09-06T09:00:00');
    });

    test('a time changed for every meeting keeps the series in its own zone',
        () async {
      final c = calendar(graphMaster());
      await c.updateEvent(
        microsoft,
        occurrence('a', 'Israel Standard Time'),
        EventChange(
          start: instantIn(DateTime(2026, 10, 27, 4), newYork),
          end: instantIn(DateTime(2026, 10, 27, 5), newYork),
          allDay: false,
          timeZone: newYork,
        ),
        wholeSeries: true,
      );
      // 04:00 in New York on 27 October is 10:00 in Jerusalem, Israel's
      // clocks back since the 25th and America's not yet.
      expect(bodyOf(sent.last)['start'], {
        'dateTime': '2026-09-01T10:00:00',
        'timeZone': jerusalem,
      });
    });

    test('a timed meeting whose zone is not known is not given a repeat',
        () async {
      final c = calendar(graphMaster());
      await expectLater(
        c.updateEvent(
          microsoft,
          occurrence('a', null),
          const EventChange(
            repeat: Recurrence(RepeatKind.weekly, days: {3}),
            timeZone: newYork,
          ),
          wholeSeries: true,
        ),
        throwsA(isA<CalendarRefused>()),
      );
      expect(sent, isEmpty);
    });
  });

  group('Edit', () {
    late _Microsoft engine;

    setUp(() => engine = _Microsoft());

    Future<void> pumpScreen(WidgetTester tester, EventEdit editing) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        deviceContactsProvider.overrideWithValue(FakeDeviceContacts()),
        deviceCalendarProvider.overrideWithValue(
            FakeDeviceCalendar(timeZone: jerusalem)),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NewMeetingScreen(
                      accountId: 'acct-ms',
                      editing: editing,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// One meeting of a weekly series on Tuesdays, from 1 September, set in
    /// Jerusalem's time unless [zone] says otherwise.
    CalendarEvent tuesday({
      String? seriesId = 'series-1',
      String? zone = 'Israel Standard Time',
      bool people = true,
    }) =>
        CalendarEvent(
          id: 'occurrence-7',
          accountId: 'acct-ms',
          title: 'Review',
          start: DateTime(2026, 10, 13, 14),
          end: DateTime(2026, 10, 13, 15),
          isOrganizer: true,
          response: EventResponse.organizer,
          seriesId: seriesId,
          timeZone: zone,
          attendees: people
              ? const [EventAttendee(MailAddress(email: 'dana@example.com'))]
              : const [],
        );

    EventNotes weekly({Recurrence? repeat}) => EventNotes(
          text: '',
          repeat: SeriesRepeat(
            repeat: repeat ?? const Recurrence(RepeatKind.weekly, days: {2}),
            firstDay: firstTuesday,
          ),
        );

    Future<void> openMore(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('meeting-more')));
      await tester.pumpAndSettle();
    }

    Future<void> closeMore(WidgetTester tester) async {
      await tester.tapAt(const Offset(500, 20));
      await tester.pumpAndSettle();
    }

    /// The labels of the menu under [key].
    List<String?> items(WidgetTester tester, String key) => [
          for (final item in tester
              .widget<DropdownButton<Object?>>(find.byKey(ValueKey(key)))
              .items!)
            (item.child as Text).data,
        ];

    Future<void> chooseEnds(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const ValueKey('meeting-repeat-ends')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    Finder day(int d) => find.byKey(ValueKey('meeting-repeat-day:$d'));

    final note = find.byKey(const ValueKey('meeting-repeat-note'));

    Finder saying(String words) =>
        find.descendant(of: note, matching: find.textContaining(words));

    testWidgets("every meeting of a series: its repeat as it is, its days "
        'changed, and what that does said before Save', (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
              event: tuesday(), notes: weekly(), wholeSeries: true));
      expect(find.textContaining('Every week on Tuesday'), findsOneWidget,
          reason: 'the line under the place says how it repeats');
      expect(note, findsNothing, reason: 'nothing changed yet');

      await openMore(tester);
      expect(find.text('Every week'), findsWidgets);
      final repeats = items(tester, 'meeting-repeat');
      expect(repeats, isNot(contains('Never')),
          reason: 'a series stays a series');
      expect(repeats, contains('Every 2 weeks'));
      expect(tester.widget<FilterChip>(day(2)).selected, isTrue);
      expect(tester.widget<FilterChip>(day(2)).onSelected, isNull,
          reason: 'its only day');

      await tester.tap(day(3));
      await tester.pumpAndSettle();
      expect(tester.widget<FilterChip>(day(2)).onSelected, isNotNull,
          reason: 'any day may go but the last');
      await tester.tap(day(2));
      await tester.pumpAndSettle();
      await closeMore(tester);

      expect(find.textContaining('Every week on Wednesday'), findsOneWidget);
      expect(note, findsOneWidget);
      expect(saying('past ones'), findsOneWidget);
      expect(saying('everyone on it'), findsOneWidget);
      expect(saying('changed on its own'), findsOneWidget,
          reason: 'what Outlook may do to those is said');

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.single,
          contains('repeat=Every week on Wednesday'));
      expect(engine.calendarActions.single, contains('series'));
    });

    testWidgets('with nobody on it, nobody is said to be sent anything',
        (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
              event: tuesday(people: false),
              notes: weekly(),
              wholeSeries: true));
      await openMore(tester);
      await tester.tap(day(3));
      await tester.pumpAndSettle();
      await closeMore(tester);
      expect(saying('past ones'), findsOneWidget);
      expect(saying('everyone'), findsNothing);
    });

    testWidgets('a series ends never or on a day: a number of times would '
        'count from its first meeting', (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
              event: tuesday(), notes: weekly(), wholeSeries: true));
      await openMore(tester);
      expect(items(tester, 'meeting-repeat-ends'), ['Never', 'On a day']);
    });

    testWidgets('a series that ends after a number of times shows its own '
        'number, whatever it is, and can end on a day or never instead',
        (tester) async {
      for (final (count, words) in [(60, '60 times'), (1, '1 time')]) {
        engine = _Microsoft();
        await tester.pumpWidget(const SizedBox());
        await pumpScreen(
            tester,
            EventEdit(
              event: tuesday(),
              notes: weekly(
                  repeat: Recurrence(RepeatKind.weekly,
                      days: const {2}, count: count)),
              wholeSeries: true,
            ));
        await openMore(tester);
        expect(tester.takeException(), isNull);
        expect(find.text(words), findsOneWidget, reason: '$count');
        expect(items(tester, 'meeting-repeat-ends'),
            ['Never', 'On a day', 'After a number of times']);
        await chooseEnds(tester, 'Never');
        await closeMore(tester);
        expect(saying('no end'), findsOneWidget);
        await tester.tap(find.byTooltip('Save'));
        await tester.pumpAndSettle();
        expect(engine.calendarActions.single, contains('repeat='));
      }
    });

    testWidgets('a meeting made a series may end after a number of times, as '
        'a new one may', (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
              event: tuesday(seriesId: null),
              notes: const EventNotes(text: '')));
      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('meeting-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every week').last);
      await tester.pumpAndSettle();
      expect(items(tester, 'meeting-repeat-ends'),
          ['Never', 'On a day', 'After a number of times']);
    });

    testWidgets('an end in the past says which meeting is then the last, and '
        'Save asks once before sending it', (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
              event: tuesday(), notes: weekly(), wholeSeries: true));
      await openMore(tester);
      await chooseEnds(tester, 'On a day');
      // The picker reaches at least ten years from today.
      final picker =
          tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
      expect(picker.lastDate.year,
          greaterThanOrEqualTo(DateTime.now().year + 10));
      await tester.tap(find.byTooltip('Switch to input'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(
              of: find.byType(DatePickerDialog),
              matching: find.byType(TextField)),
          '11/04/2026');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await closeMore(tester);

      expect(
          saying("The series' last meeting is then 3 November 2026, already "
              "past: every meeting after it comes off everyone's calendar."),
          findsOneWidget);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('repeat-past-save')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('repeat-past-keep')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, isEmpty);
      expect(find.byType(NewMeetingScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('repeat-past-save')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.single, contains('repeat='));
      expect(engine.calendarActions.single, contains('series'));
    });

    testWidgets('an end ahead says the last meeting, and asks nothing',
        (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
            event: tuesday(),
            notes: weekly(
                repeat: Recurrence(RepeatKind.weekly,
                    days: const {2}, until: DateTime(2036, 6, 25))),
            wholeSeries: true,
          ));
      await openMore(tester);
      await tester.tap(day(3));
      await tester.pumpAndSettle();
      await closeMore(tester);
      expect(saying('25 June 2036'), findsOneWidget,
          reason: 'the last Wednesday by its end, a Wednesday');
      expect(saying('already past'), findsNothing);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('repeat-past-save')), findsNothing);
      expect(engine.calendarActions.single, contains('repeat='));
    });

    testWidgets('a meeting on its own can be made to repeat', (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
              event: tuesday(seriesId: null),
              notes: const EventNotes(text: '')));
      expect(find.byTooltip('Repeat, reminder, show as, private'),
          findsOneWidget);
      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('meeting-repeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every week').last);
      await tester.pumpAndSettle();
      await closeMore(tester);
      expect(saying('becomes a series'), findsOneWidget);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.single,
          contains('repeat=Every week on Tuesday'));
      expect(engine.calendarActions.single, isNot(contains('series')));
    });

    testWidgets('a meeting whose time zone is not known is not offered '
        'Repeat', (tester) async {
      for (final edit in [
        EventEdit(
            event: tuesday(zone: null), notes: weekly(), wholeSeries: true),
        EventEdit(
            event: tuesday(seriesId: null, zone: null),
            notes: const EventNotes(text: '')),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await pumpScreen(tester, edit);
        expect(find.byTooltip('Reminder, show as, private'), findsOneWidget);
        await openMore(tester);
        expect(find.byKey(const ValueKey('meeting-repeat')), findsNothing);
        await closeMore(tester);
      }
    });

    testWidgets('one meeting of a series cannot be made to repeat on its own',
        (tester) async {
      await pumpScreen(
          tester, EventEdit(event: tuesday(), notes: weekly()));
      expect(find.byTooltip('Reminder, show as, private'), findsOneWidget);
      await openMore(tester);
      expect(find.byKey(const ValueKey('meeting-repeat')), findsNothing);
    });

    testWidgets('a series whose repeat cannot be shown keeps it, with no '
        'Repeat offered', (tester) async {
      await pumpScreen(
        tester,
        EventEdit(
          event: tuesday(),
          notes: EventNotes(
            text: '',
            repeat: SeriesRepeat(repeat: null, firstDay: firstTuesday),
          ),
          wholeSeries: true,
        ),
      );
      await openMore(tester);
      expect(find.byKey(const ValueKey('meeting-repeat')), findsNothing);
    });

    testWidgets('a series saved with its repeat left alone changes nothing',
        (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
              event: tuesday(), notes: weekly(), wholeSeries: true));
      await openMore(tester);
      await closeMore(tester);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, isEmpty);
      expect(find.text('Nothing was changed.'), findsOneWidget);
    });

    testWidgets('a repeat ending before its first meeting is caught',
        (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
            event: tuesday(),
            notes: weekly(
              repeat: Recurrence(RepeatKind.weekly,
                  days: const {2}, until: DateTime(2026, 8, 25)),
            ),
            wholeSeries: true,
          ));
      // Read so, it is left alone; changed, it has to make sense.
      await openMore(tester);
      await tester.tap(day(4));
      await tester.pumpAndSettle();
      await closeMore(tester);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.text('The repeat has to end on the first meeting or after '
          'it.'), findsOneWidget);
      expect(engine.calendarActions, isEmpty);
    });
  });

  group('More on its own', () {
    testWidgets('a count outside the menu is added to it, not broken by it',
        (tester) async {
      for (final count in [1, 60, 999]) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: MeetingOptionsPanel(
              options: MeetingOptions(
                  repeat: Recurrence(RepeatKind.weekly,
                      days: const {2}, count: count)),
              start: DateTime(2026, 11, 17, 14),
              allDay: false,
              workWeek: const {1, 2, 3, 4, 5},
              editing: true,
              repeats: true,
              seriesFrom: firstTuesday,
              seriesCount: count,
              onChanged: (_) {},
            ),
          ),
        ));
        expect(tester.takeException(), isNull, reason: '$count');
        expect(find.text(count == 1 ? '1 time' : '$count times'),
            findsOneWidget);
      }
    });
  });
}

/// An engine with one Microsoft account, whose calendar holds meetings.
class _Microsoft extends SampleMailEngine {
  @override
  Future<List<Account>> loadAccounts() async => const [
        Account(
          id: 'acct-ms',
          displayName: 'Work',
          emailAddress: 'ron@contoso.com',
          provider: MailProvider.outlook,
          authMethod: AuthMethod.oauth,
          colorValue: 0xFF0F6CBD,
        ),
      ];
}
