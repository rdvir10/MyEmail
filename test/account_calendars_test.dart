import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/cache/mail_database.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/calendar/internet_calendars.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/account_calendars.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/internet_calendar.dart';
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/providers.dart';

/// Every calendar in each account (#25), category colours (#26) and
/// calendars from links (#28), as the calendar view reads them.
void main() {
  CalendarEvent event(
    String id, {
    String accountId = 'hadco',
    String calendarId = CalendarEvent.mainCalendar,
    int? colour,
  }) =>
      CalendarEvent(
        id: id,
        accountId: accountId,
        calendarId: calendarId,
        title: id,
        start: DateTime(2026, 10, 27, 10),
        end: DateTime(2026, 10, 27, 11),
        colour: colour,
      );

  group('one calendar of an account', () {
    test('hidden by its own key, or with its whole account', () {
      final work = event('w', calendarId: 'work');
      expect(calendarShown(work, const {}), isTrue);
      expect(calendarShown(work, {calendarKey('hadco', 'work')}), isFalse);
      expect(calendarShown(work, {'hadco'}), isFalse);
      expect(calendarShown(event('m'), {calendarKey('hadco', 'work')}), isTrue);
    });

    test('drawn in its own colour, else its calendar\'s, else its account\'s',
        () {
      const calendars = {
        'hadco|work': CalendarInfo(
            accountId: 'hadco', id: 'work', name: 'Work', colour: 0xFF00AA00),
      };
      expect(eventColour(event('m'), 0xFF0000FF, calendars: calendars),
          0xFF0000FF);
      expect(
          eventColour(event('w', calendarId: 'work'), 0xFF0000FF,
              calendars: calendars),
          0xFF00AA00);
      expect(
          eventColour(event('c', calendarId: 'work', colour: 0xFFE74856),
              0xFF0000FF,
              calendars: calendars),
          0xFFE74856);
      expect(colourFromHex('#9fe1e7'), 0xFF9FE1E7);
      expect(colourFromHex('nope'), isNull);
    });

    test('kept as text, and read back', () {
      const info = CalendarInfo(
          accountId: 'g', id: 'x@group', name: 'Birthdays', canEdit: false);
      expect(CalendarInfo.fromJson(jsonDecode(jsonEncode(info.toJson()))), info);
      final e = event('r', calendarId: 'x@group', colour: 0xFF33B679);
      final kept = CalendarEvent.fromJson(jsonDecode(jsonEncode(
          CalendarEvent(
            id: e.id,
            accountId: e.accountId,
            calendarId: e.calendarId,
            title: e.title,
            start: e.start,
            end: e.end,
            readOnly: true,
            categories: const ['Travel'],
            colour: 0xFF33B679,
          ).toJson())))!;
      expect(kept.readOnly, isTrue);
      expect(kept.categories, ['Travel']);
      expect(kept.colour, 0xFF33B679);
    });
  });

  group("Outlook's calendars and categories", () {
    test('the default one is the main calendar, the rest in their colours',
        () async {
      final api = GraphCalendarApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: http_testing.MockClient((request) async {
          expect(request.url.path, '/v1.0/me/calendars');
          return http.Response(
            jsonEncode({
              'value': [
                {'id': 'AAA', 'name': 'Calendar', 'isDefaultCalendar': true},
                {
                  'id': 'BBB',
                  'name': 'Projects',
                  'hexColor': '#e3008c',
                  'canEdit': true,
                },
                {
                  'id': 'CCC',
                  'name': 'Team',
                  'color': 'lightGreen',
                  'hexColor': '',
                  'canEdit': false,
                },
              ],
            }),
            200,
          );
        }),
      );
      final calendars = await api.calendars(accountId: 'hadco');
      expect([for (final c in calendars) c.id],
          [CalendarEvent.mainCalendar, 'BBB', 'CCC']);
      expect(calendars[1].colour, 0xFFE3008C);
      expect(calendars[2].colour, outlookCalendarColours['lightGreen']);
      expect(calendars[2].canEdit, isFalse);
    });

    test("a meeting in a category takes the category's colour", () async {
      final api = GraphCalendarApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: http_testing.MockClient((request) async => http.Response(
              jsonEncode({
                'value': [
                  {'displayName': 'Travel', 'color': 'preset7'},
                  {'displayName': 'None', 'color': 'none'},
                ],
              }),
              200,
            )),
      );
      final colours = await api.categoryColours();
      expect(colours, {'Travel': outlookCategoryColours['preset7']});
      final e = GraphCalendarApi.eventFrom({
        'id': 'e1',
        'subject': 'Flight',
        'start': {'dateTime': '2026-10-27T10:00:00'},
        'end': {'dateTime': '2026-10-27T11:00:00'},
        'categories': ['Holiday', 'Travel'],
      }, 'hadco', calendarId: 'BBB', categoryColours: colours)!;
      expect(e.categories, ['Holiday', 'Travel']);
      expect(e.colour, outlookCategoryColours['preset7']);
      expect(e.calendarId, 'BBB');
    });
  });

  group("Google's calendar list and event colours", () {
    test('the primary one is the main calendar; those switched off are left',
        () async {
      final api = GoogleCalendarApi(
        accessToken: ({bool force = false}) async => 't',
        httpClient: http_testing.MockClient((request) async {
          expect(request.url.path, '/calendar/v3/users/me/calendarList');
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'ron@gmail.example',
                  'summary': 'ron@gmail.example',
                  'primary': true,
                  'selected': true,
                  'accessRole': 'owner',
                },
                {
                  'id': 'en.jewish#holiday@group.v.calendar.google.com',
                  'summary': 'Holidays in Israel',
                  'backgroundColor': '#16a765',
                  'selected': true,
                  'accessRole': 'reader',
                },
                {
                  'id': 'family@group.calendar.google.com',
                  'summary': 'Family',
                  'summaryOverride': 'Home',
                  'selected': true,
                  'accessRole': 'writer',
                },
                {
                  'id': 'off@group.calendar.google.com',
                  'summary': 'Switched off',
                  'selected': false,
                  'accessRole': 'owner',
                },
              ],
            }),
            200,
          );
        }),
      );
      final calendars = await api.calendars(accountId: 'g');
      expect([for (final c in calendars) c.name],
          ['ron@gmail.example', 'Holidays in Israel', 'Home']);
      expect(calendars.first.isMain, isTrue);
      expect(calendars[1].canEdit, isFalse);
      expect(calendars[1].colour, 0xFF16A765);
      expect(calendars[2].canEdit, isTrue);
    });

    test("an event's picked colour", () {
      final e = GoogleCalendarApi.eventFrom({
        'id': 'e1',
        'summary': 'Dentist',
        'colorId': '11',
        'start': {'dateTime': '2026-10-27T10:00:00Z'},
        'end': {'dateTime': '2026-10-27T11:00:00Z'},
      }, 'g', calendarId: 'family@group', readOnly: true)!;
      expect(e.colour, googleEventColours['11']);
      expect(e.calendarId, 'family@group');
      expect(e.readOnly, isTrue);
    });
  });

  group('the list kept on the device', () {
    Future<void> keeps(CacheStore store) async {
      expect(await store.keptCalendarList('hadco'), isEmpty);
      const listed = [
        CalendarInfo.main('hadco'),
        CalendarInfo(
            accountId: 'hadco', id: 'BBB', name: 'Projects', colour: 0xFFE3008C),
      ];
      await store.keepCalendarList('hadco', listed);
      expect(await store.keptCalendarList('hadco'), listed);
      await store.keepCalendarList('hadco', const [CalendarInfo.main('hadco')]);
      expect(await store.keptCalendarList('hadco'),
          const [CalendarInfo.main('hadco')]);
      await store.deleteAccount('hadco');
      expect(await store.keptCalendarList('hadco'), isEmpty);
    }

    test('in memory', () => keeps(MemoryCacheStore()));

    test('in the database', () async {
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await keeps(DriftCacheStore(db));
    });
  });

  group("the calendar view's load", () {
    late SampleMailEngine engine;
    late Account hadco;
    late ProviderContainer c;
    late MemoryUiStateStore ui;
    late MemoryInternetCalendars links;
    final range = (start: DateTime(2026, 10, 26), end: DateTime(2026, 11, 2));

    setUp(() async {
      engine = SampleMailEngine();
      hadco = await engine.addOAuthAccount(
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        token: OAuthToken(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.utc(2030),
        ),
      );
      engine.calendarLists[hadco.id] = [
        CalendarInfo.main(hadco.id),
        CalendarInfo(
            accountId: hadco.id, id: 'BBB', name: 'Projects', colour: 0xFFE3008C),
      ];
      engine.events[hadco.id] = [
        event('main', accountId: hadco.id),
        event('projects', accountId: hadco.id, calendarId: 'BBB'),
      ];
      ui = MemoryUiStateStore();
      links = MemoryInternetCalendars({
        'https://example.com/il.ics': [
          'BEGIN:VCALENDAR',
          'BEGIN:VEVENT',
          'UID:h1',
          'SUMMARY:Holiday',
          'DTSTART;VALUE=DATE:20261028',
          'DTEND;VALUE=DATE:20261029',
          'END:VEVENT',
          'END:VCALENDAR',
        ].join('\r\n'),
      });
      c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine),
        internetCalendarReaderProvider.overrideWithValue(links),
      ]);
      addTearDown(c.dispose);
      await c.read(accountsProvider.future);
    });

    Future<CalendarLoad> settled() async {
      final done = Completer<CalendarLoad>();
      final sub = c.listen(calendarEventsProvider(range), (_, next) {
        final v = next.value;
        if (v != null && !v.reading && !done.isCompleted) done.complete(v);
      }, fireImmediately: true);
      addTearDown(sub.close);
      return done.future;
    }

    test("every calendar's meetings, each calendar named and coloured",
        () async {
      final load = await settled();
      expect({for (final e in load.events) e.id}, {'main', 'projects'});
      expect(load.calendars['${hadco.id}|BBB']?.name, 'Projects');
    });

    test('one calendar switched off leaves the others', () async {
      c
          .read(hiddenCalendarsProvider.notifier)
          .setCalendarShown(calendarKey(hadco.id, 'BBB'), false);
      final load = await settled();
      expect([for (final e in load.events) e.id], ['main']);
    });

    test("a calendar from a link, read, kept, and shown in its colour",
        () async {
      c.read(internetCalendarsProvider.notifier).add(const InternetCalendar(
            id: 'il',
            name: 'Holidays in Israel',
            url: 'https://example.com/il.ics',
            colour: 0xFF0B8043,
          ));
      final load = await settled();
      final holiday = load.events.where((e) => e.title == 'Holiday').single;
      expect(holiday.accountId, 'internet:il');
      expect(holiday.readOnly, isTrue);
      expect(load.calendars['internet:il|']?.colour, 0xFF0B8043);
      expect(links.asked, ['https://example.com/il.ics']);
      expect(
          InternetCalendar.listFrom(ui.readString(UiStateKeys.internetCalendars))
              .single
              .name,
          'Holidays in Israel',
          reason: 'kept, for the backup too');
    });
  });
}
