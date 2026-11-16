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
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_change.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/recurrence.dart';
import 'package:myemail/domain/series_repeat.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/contact_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';

import 'fakes/fake_webview.dart';

/// Changing how a series repeats, or making a meeting repeat (calendar
/// idea #55): what Edit reads of a series' repeat, what each calendar is
/// sent, and what the screen says before it is saved.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});

  Map<String, Object?> bodyOf(http.Request r) =>
      (jsonDecode(r.body) as Map).cast<String, Object?>();

  // 1 September 2026 is a Tuesday; so are 13 and 27 October.
  final firstTuesday = DateTime(2026, 9, 1);

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
          {'type': 'daily', 'interval': 2},
          {'type': 'numbered', 'numberOfOccurrences': 10},
        ))!.repeat,
        const Recurrence(RepeatKind.daily, interval: 2, count: 10),
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

    test('from Graph, one New meeting could not have made is a series all '
        'the same, its repeat not to be shown', () {
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
      ]) {
        final read = SeriesRepeat.fromGraph(graph(pattern));
        expect(read, isNotNull, reason: '$pattern');
        expect(read!.repeat, isNull, reason: '$pattern');
        expect(read.firstDay, firstTuesday);
      }
      expect(SeriesRepeat.fromGraph(null), isNull, reason: 'one on its own');
      expect(SeriesRepeat.fromGraph({'pattern': 'nonsense'}), isNull);
    });

    test('from Google, its rule and its first day', () {
      // Google writes a timed UNTIL as the end of the last day, in UTC.
      final end = DateTime(2026, 11, 30, 23, 59, 59).toUtc();
      String two(int v) => '$v'.padLeft(2, '0');
      final until = '${end.year}${two(end.month)}${two(end.day)}T'
          '${two(end.hour)}${two(end.minute)}${two(end.second)}Z';
      final weekly = SeriesRepeat.fromGoogle({
        'start': {
          'dateTime': '2026-09-01T09:00:00+03:00',
          'timeZone': 'Asia/Jerusalem',
        },
        'recurrence': [
          'EXDATE;TZID=Asia/Jerusalem:20260915T090000',
          'RRULE:FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=$until',
        ],
      })!;
      expect(weekly.firstDay, firstTuesday);
      expect(
        weekly.repeat,
        Recurrence(RepeatKind.weekly,
            days: const {2, 4}, until: DateTime(2026, 11, 30)),
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
      ]) {
        expect(rule(unknown), isNull, reason: unknown);
      }
      expect(
        SeriesRepeat.fromGoogle({
          'start': {'date': '2026-09-01'},
          'recurrence': ['RRULE:FREQ=WEEKLY', 'RDATE:20260903'],
        })?.repeat,
        isNull,
        reason: 'a day added by hand is more than New meeting shows',
      );
      expect(SeriesRepeat.fromGoogle({'start': {'date': '2026-09-01'}}),
          isNull);
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

    test('moves the series there, at its own time unless the time changes '
        'too', () {
      final series = (
        start: DateTime(2026, 9, 1, 14).toUtc(),
        end: DateTime(2026, 9, 1, 15).toUtc(),
        allDay: false,
      );
      const wednesdays = Recurrence(RepeatKind.weekly, days: {3});
      final days = forSeries(const EventChange(repeat: wednesdays), series);
      expect(days.start, DateTime(2026, 9, 2, 14));
      expect(days.end, DateTime(2026, 9, 2, 15));
      expect(days.repeat, wednesdays);

      // From one meeting of it, moved to 15:30-16:15 as well.
      final both = forSeries(
        EventChange(
          start: DateTime(2026, 10, 27, 15, 30),
          end: DateTime(2026, 10, 27, 16, 15),
          allDay: false,
          repeat: wednesdays,
        ),
        series,
      );
      expect(both.start, DateTime(2026, 9, 2, 15, 30));
      expect(both.end, DateTime(2026, 9, 2, 16, 15));

      // A new end alone: the first meeting stays where it is.
      final ends = forSeries(
        EventChange(
          repeat: Recurrence(RepeatKind.weekly,
              days: const {2}, until: DateTime(2026, 12, 29)),
        ),
        series,
      );
      expect(ends.start, DateTime(2026, 9, 1, 14));
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
          timeZone: 'Asia/Jerusalem',
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
          'recurrenceTimeZone': 'Asia/Jerusalem',
        },
      });
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

    test('every meeting of a series moved to new days: the series moved to '
        'its first new day, with its repeat', () async {
      const microsoft = Account(
        id: 'a',
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        authMethod: AuthMethod.oauth,
        colorValue: 0xFF0F6CBD,
      );
      sent = [];
      final calendar = AccountCalendar(
        accessToken: (id, {bool force = false, List<String>? scopes}) async =>
            'token',
        accounts: () => const [microsoft],
        httpClient: http_testing.MockClient((r) async {
          sent.add(r);
          return r.method == 'GET'
              ? json({
                  'id': 'series-1',
                  'start': {
                    'dateTime':
                        '${_utcStamp(DateTime(2026, 9, 1, 14))}.0000000',
                    'timeZone': 'UTC',
                  },
                  'end': {
                    'dateTime':
                        '${_utcStamp(DateTime(2026, 9, 1, 15))}.0000000',
                    'timeZone': 'UTC',
                  },
                  'isAllDay': false,
                  'type': 'seriesMaster',
                })
              : json({});
        }),
        sleep: (_) async {},
      );
      final one = CalendarEvent(
        id: 'occurrence-8',
        accountId: 'a',
        title: 'Review',
        start: DateTime(2026, 10, 27, 14),
        end: DateTime(2026, 10, 27, 15),
        isOrganizer: true,
        response: EventResponse.organizer,
        seriesId: 'series-1',
      );
      await calendar.updateEvent(
        microsoft,
        one,
        const EventChange(
          repeat: Recurrence(RepeatKind.weekly, days: {3}),
          timeZone: 'Asia/Jerusalem',
        ),
        wholeSeries: true,
      );
      final patch = sent.last;
      expect(patch.method, 'PATCH');
      expect(patch.url.path, endsWith('/events/series-1'));
      final body = bodyOf(patch);
      expect(body['start'], {
        'dateTime': '2026-09-02T14:00:00',
        'timeZone': 'Asia/Jerusalem',
      });
      expect(body['end'], {
        'dateTime': '2026-09-02T15:00:00',
        'timeZone': 'Asia/Jerusalem',
      });
      final recurrence = body['recurrence']! as Map;
      expect((recurrence['pattern'] as Map)['daysOfWeek'], ['wednesday']);
      expect((recurrence['range'] as Map)['startDate'], '2026-09-02');
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
          timeZone: 'Asia/Jerusalem',
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
        'timeZone': 'Asia/Jerusalem',
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
          'timeZone': 'Asia/Jerusalem',
        },
        'recurrence': ['RRULE:FREQ=WEEKLY;BYDAY=TU'],
      }).notes('series-1');
      expect(notes.text, 'Agenda');
      expect(notes.repeat?.repeat,
          const Recurrence(RepeatKind.weekly, days: {2}));
      expect(notes.repeat?.firstDay, firstTuesday);
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
            FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
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

    /// One meeting of a weekly series on Tuesdays, from 1 September.
    CalendarEvent tuesday({String? seriesId = 'series-1'}) => CalendarEvent(
          id: 'occurrence-7',
          accountId: 'acct-ms',
          title: 'Review',
          start: DateTime(2026, 10, 13, 14),
          end: DateTime(2026, 10, 13, 15),
          isOrganizer: true,
          response: EventResponse.organizer,
          seriesId: seriesId,
          attendees: const [
            EventAttendee(MailAddress(email: 'dana@example.com')),
          ],
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

    Finder day(int d) => find.byKey(ValueKey('meeting-repeat-day:$d'));

    final note = find.byKey(const ValueKey('meeting-repeat-note'));

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
      final repeats = [
        for (final item in tester
            .widget<DropdownButton<Object?>>(
                find.byKey(const ValueKey('meeting-repeat')))
            .items!)
          (item.child as Text).data,
      ];
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
      expect(
        find.descendant(of: note, matching: find.textContaining('past ones')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: note, matching: find.textContaining('changed on its own')),
        findsOneWidget,
        reason: 'what Outlook may do to those is said',
      );

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.single,
          contains('repeat=Every week on Wednesday'));
      expect(engine.calendarActions.single, contains('series'));
    });

    testWidgets('a new end alone', (tester) async {
      await pumpScreen(
          tester,
          EventEdit(
              event: tuesday(), notes: weekly(), wholeSeries: true));
      await openMore(tester);
      await tester.tap(find.byKey(const ValueKey('meeting-repeat-ends')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('After a number of times').last);
      await tester.pumpAndSettle();
      await closeMore(tester);
      expect(find.textContaining('Every week on Tuesday, 10 times'),
          findsOneWidget);
      expect(note, findsOneWidget);

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.single,
          contains('repeat=Every week on Tuesday, 10 times'));
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
      expect(
        find.descendant(
            of: note, matching: find.textContaining('becomes a series')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(engine.calendarActions.single,
          contains('repeat=Every week on Tuesday'));
      expect(engine.calendarActions.single, isNot(contains('series')));
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
}

/// [local] in UTC as Graph writes a time, without the zone.
String _utcStamp(DateTime local) {
  final u = local.toUtc();
  String two(int v) => '$v'.padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)}T'
      '${two(u.hour)}:${two(u.minute)}:${two(u.second)}';
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
