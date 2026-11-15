import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/mail_engine.dart'
    show ConnectionFailed, KeptCalendar;
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/account_calendars.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_finding.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/calendar_view_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart';
import 'package:myemail/ui/calendar/calendar_search_screen.dart';
import 'package:myemail/ui/calendar/waiting_answers.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart'
    show NewMeetingScreen;

/// The invitations waiting for your answer (#50): a line at the Agenda's
/// top, and the list it opens, each answered there as on its sheet.
void main() {
  const dana = MailAddress(email: 'dana@hadco.example', name: 'Dana Levi');
  const ron = MailAddress(email: 'ron@hadco.example');

  DateTime day(int fromToday, [int hour = 10]) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day + fromToday, hour);
  }

  /// Dana's meeting [fromToday] days on, inviting the account, answered
  /// as [response]; or, with [own], the account's own. On its main
  /// calendar, or [calendarId].
  CalendarEvent meeting(
    String accountId,
    String id,
    String title,
    int fromToday, {
    EventResponse response = EventResponse.notResponded,
    bool own = false,
    bool cancelled = false,
    bool readOnly = false,
    String? seriesId,
    int hour = 10,
    MailAddress? organizer = dana,
    String calendarId = CalendarEvent.mainCalendar,
  }) =>
      CalendarEvent(
        id: id,
        accountId: accountId,
        calendarId: calendarId,
        title: title,
        start: day(fromToday, hour),
        end: day(fromToday, hour + 1),
        organizer: own ? null : organizer,
        isOrganizer: own,
        response: own ? EventResponse.organizer : response,
        cancelled: cancelled,
        readOnly: readOnly,
        seriesId: seriesId,
        attendees: [
          if (!own && organizer != null)
            EventAttendee(organizer, response: EventResponse.organizer),
          EventAttendee(ron,
              response: own ? EventResponse.organizer : response),
        ],
      );

  group('which meetings wait for your answer', () {
    List<String> ids(List<Waiting> found) =>
        [for (final w in found) '${w.event.accountId}:${w.event.id}'];

    test("someone else's not answered, not cancelled, not over and on your "
        'own calendar, soonest first', () {
      final now = DateTime.now();
      final found = waitingForAnswer([
        meeting('a', 'later', 'Offsite', 30),
        meeting('a', 'soon', 'Budget', 1),
        meeting('a', 'accepted', 'Lunch', 2, response: EventResponse.accepted),
        meeting('a', 'maybe', 'Review', 2, response: EventResponse.tentative),
        meeting('a', 'declined', 'Party', 2, response: EventResponse.declined),
        meeting('a', 'mine', 'Planning', 2, own: true),
        meeting('a', 'cancelled', 'Sync', 3, cancelled: true),
        meeting('a', 'over', 'Yesterday', -1),
        meeting('a', 'holiday', 'Holiday', 4, readOnly: true),
        meeting('a', 'nobody', 'Note', 5, organizer: null),
        // The same meeting read twice, by two reads that overlap.
        meeting('a', 'soon', 'Budget', 1),
        // On another account, the same id is another meeting.
        meeting('b', 'soon', 'Budget', 1, hour: 12),
        // A colleague's calendar shared to the account, which it may
        // change: her answer, not the account's, and the same meeting
        // again.
        meeting('a', 'soon', 'Budget', 1, calendarId: 'dana'),
        meeting('a', 'hers', 'Supplier visit', 6, calendarId: 'dana'),
      ], now);
      expect(ids(found), ['a:soon', 'b:soon', 'a:later']);
      expect([for (final w in found) w.more], [0, 0, 0]);
    });

    test('a series counts once, as its next meeting waiting, with how many '
        'more of it wait', () {
      final now = DateTime.now();
      final found = waitingForAnswer([
        for (var week = 3; week >= 0; week--)
          meeting('a', 'w$week', 'Weekly sync', 1 + 7 * week,
              seriesId: 'weekly'),
        meeting('a', 'w-answered', 'Weekly sync', 2,
            seriesId: 'weekly', response: EventResponse.accepted),
        // Another account's series of the same id is its own.
        meeting('b', 'w0', 'Weekly sync', 1, seriesId: 'weekly', hour: 12),
        meeting('a', 'budget', 'Budget', 3),
      ], now);
      expect(ids(found), ['a:w0', 'b:w0', 'a:budget']);
      expect([for (final w in found) w.more], [3, 0, 0]);
    });

    test("Microsoft's and Google's alike, as each calendar says it: Graph's "
        "notResponded, Google's needsAction", () {
      String at(int fromToday, int hour) =>
          day(fromToday, hour).toUtc().toIso8601String();
      const me = {
        'email': 'me@gmail.example',
        'self': true,
        'responseStatus': 'needsAction',
      };
      final outlook = GraphCalendarApi.eventFrom({
        'id': 'g1',
        'subject': 'Budget',
        'start': {'dateTime': at(1, 10).replaceAll('Z', ''), 'timeZone': 'UTC'},
        'end': {'dateTime': at(1, 11).replaceAll('Z', ''), 'timeZone': 'UTC'},
        'organizer': {
          'emailAddress': {
            'name': 'Dana Levi',
            'address': 'dana@hadco.example',
          },
        },
        'responseStatus': {'response': 'notResponded'},
      }, 'hadco')!;
      final google = GoogleCalendarApi.eventFrom({
        'id': 'e1',
        'summary': 'Lunch',
        'start': {'dateTime': at(2, 12)},
        'end': {'dateTime': at(2, 13)},
        'organizer': {'email': 'dana@example.com'},
        'attendees': [
          {'email': 'dana@example.com', 'organizer': true},
          me,
        ],
      }, 'gmail')!;
      final holiday = GoogleCalendarApi.eventFrom({
        'id': 'h1',
        'summary': 'A holiday',
        'start': {'dateTime': at(3, 12)},
        'end': {'dateTime': at(3, 13)},
        'organizer': {'email': 'holidays@group.v.calendar.google.com'},
        'attendees': [me],
      }, 'gmail', calendarId: 'holidays', readOnly: true)!;
      expect(
          [
            for (final w in waitingForAnswer(
                [holiday, google, outlook], DateTime.now()))
              w.event,
          ],
          [outlook, google]);
    });

    test('one going on now still waits; one with no answer at all does not',
        () {
      final now = DateTime.now();
      final on = CalendarEvent(
        id: 'on',
        accountId: 'a',
        title: 'Going on',
        start: now.subtract(const Duration(minutes: 10)),
        end: now.add(const Duration(minutes: 20)),
        organizer: dana,
        response: EventResponse.notResponded,
      );
      final none = meeting('a', 'none', 'Unknown', 1,
          response: EventResponse.none);
      expect([for (final w in waitingForAnswer([on, none], now)) w.event],
          [on]);
    });
  });

  group('on screen', () {
    /// The calendar on a Hadco account holding [events], on its main
    /// calendar and those of [calendars]. With [keptAYearAgo], a search of
    /// the calendar made that long ago kept a year either way. [prepare]
    /// sets the engine up further before the calendar opens.
    Future<(ProviderContainer, _Engine, Account)> pump(
      WidgetTester tester, {
      Size size = const Size(1000, 1400),
      required List<CalendarEvent> Function(Account hadco) events,
      Duration? keptAYearAgo,
      List<CalendarInfo> Function(Account hadco)? calendars,
      Duration readsAgo = Duration.zero,
      Future<void> Function(_Engine engine, Account hadco)? prepare,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = _Engine();
      final hadco = (await tester.runAsync(() => engine.addOAuthAccount(
            displayName: 'Hadco',
            emailAddress: 'ron@hadco.example',
            provider: MailProvider.outlook,
            token: OAuthToken(
              accessToken: 'a',
              refreshToken: 'r',
              expiresAt: DateTime.utc(2030),
            ),
          )))!;
      engine.events[hadco.id] = events(hadco);
      if (calendars != null) engine.calendarLists[hadco.id] = calendars(hadco);
      if (keptAYearAgo != null) {
        final span = searchSpan(DateTime.now());
        engine.calendarClock = () => DateTime.now().subtract(keptAYearAgo);
        await tester.runAsync(
            () => engine.calendarEvents(hadco.id, span.start, span.end));
        engine.calendarClock = DateTime.now;
      }
      // Every read from here said to be made [readsAgo] before it was, as
      // on a calendar left open that long.
      if (readsAgo > Duration.zero) {
        engine.calendarClock = () => DateTime.now().subtract(readsAgo);
      }
      if (prepare != null) await tester.runAsync(() => prepare(engine, hadco));
      engine.reads.clear();
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider.overrideWithValue(
            FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: const CalendarScreen(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (c, engine, hadco);
    }

    Finder line() => find.byKey(const ValueKey('agenda-waiting'));
    Finder row(Account a, String id) =>
        find.byKey(ValueKey('waiting-event:${a.id}||$id'));
    Finder rows() => find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('waiting-event:'));
    Finder button(Account a, String id, String which) => find.descendant(
          of: row(a, id),
          matching: find.byKey(ValueKey('waiting-$which')),
        );

    /// The reads of the year ahead the list makes, from today to where
    /// search's year ends.
    int yearReads(_Engine engine) {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final end = searchSpan(now).end;
      return engine.reads
          .where((r) => r.start == start && r.end == end)
          .length;
    }

    /// Answering stopped, the list reads the year again: let that be done
    /// before the test ends.
    Future<void> quiet(WidgetTester tester) async {
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
    }

    /// Press [which] on [id]'s row, then Send the response now, and for one
    /// meeting of a series, [series].
    Future<void> answerRow(
      WidgetTester tester,
      Account hadco,
      String id,
      String which, {
      String? series,
    }) async {
      await tester.tap(button(hadco, id, which));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-now')));
      await tester.pumpAndSettle();
      if (series != null) {
        await tester.tap(find.byKey(ValueKey(series)));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('the Agenda says how many wait for your answer at its top, '
        'and not in Day', (tester) async {
      await pump(tester, events: (hadco) => [
            meeting(hadco.id, 'budget', 'Budget', 1),
            meeting(hadco.id, 'review', 'Review', 3),
            meeting(hadco.id, 'lunch', 'Lunch', 2,
                response: EventResponse.accepted),
            meeting(hadco.id, 'planning', 'Planning', 2, own: true),
          ]);
      expect(line(), findsOneWidget);
      expect(find.text('2 waiting for your answer in the next 30 days'),
          findsOneWidget);
      // Above the days.
      expect(
          tester.getTopLeft(line()).dy,
          lessThan(tester
              .getTopLeft(find.byKey(const ValueKey('agenda-event:budget')))
              .dy));

      await tester.tap(find.byKey(const ValueKey('calendar-view-day')));
      await tester.pumpAndSettle();
      expect(line(), findsNothing);
    });

    testWidgets('one says so; none means no line', (tester) async {
      final (c, engine, hadco) = await pump(tester, events: (hadco) => [
            meeting(hadco.id, 'budget', 'Budget', 1),
            meeting(hadco.id, 'lunch', 'Lunch', 2,
                response: EventResponse.accepted),
          ]);
      expect(find.text('1 waiting for your answer in the next 30 days'),
          findsOneWidget);

      engine.events[hadco.id] = [
        meeting(hadco.id, 'lunch', 'Lunch', 2,
            response: EventResponse.accepted),
      ];
      c.read(calendarRefreshProvider.notifier).now();
      await tester.pumpAndSettle();
      expect(line(), findsNothing);
      expect(find.textContaining('waiting for your answer'), findsNothing);
    });

    for (final (name, size) in [
      ('a phone', const Size(400, 860)),
      ('a tablet', const Size(1000, 1400)),
    ]) {
      testWidgets('on $name, a tap lists them soonest first, each drawn as '
          'the Agenda draws it, with Accept, Maybe and Decline, and a tap '
          'on one opens its sheet', (tester) async {
        final (_, _, hadco) = await pump(tester, size: size,
            events: (hadco) => [
                  meeting(hadco.id, 'review', 'Review', 3, hour: 14),
                  meeting(hadco.id, 'budget', 'Budget', 1),
                ]);
        await tester.tap(line());
        await tester.pumpAndSettle();
        expect(find.text('Waiting for your answer'), findsOneWidget);
        expect(row(hadco, 'budget'), findsOneWidget);
        expect(row(hadco, 'review'), findsOneWidget);
        expect(tester.getTopLeft(row(hadco, 'budget')).dy,
            lessThan(tester.getTopLeft(row(hadco, 'review')).dy));
        // As the Agenda draws it: the time, the title, Not answered, under
        // its day's heading.
        expect(
            find.descendant(
                of: row(hadco, 'review'), matching: find.text('14:00')),
            findsOneWidget);
        expect(
            find.descendant(
                of: row(hadco, 'review'), matching: find.text('Not answered')),
            findsOneWidget);
        expect(find.textContaining('Tomorrow'), findsOneWidget);
        for (final which in ['accept', 'tentative', 'decline']) {
          expect(button(hadco, 'budget', which), findsOneWidget);
        }
        expect(
            find.descendant(
                of: button(hadco, 'budget', 'tentative'),
                matching: find.text('Maybe')),
            findsOneWidget);

        await tester.tap(find.descendant(
            of: row(hadco, 'budget'), matching: find.text('Budget')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('event-accept')), findsOneWidget,
            reason: "the meeting's sheet");
      });
    }

    testWidgets('Accept asks how the answer goes, as on the sheet; the '
        'meeting leaves the list, and the line counts one fewer',
        (tester) async {
      final (_, engine, hadco) = await pump(tester, events: (hadco) => [
            meeting(hadco.id, 'budget', 'Budget', 1),
            meeting(hadco.id, 'review', 'Review', 3),
          ]);
      await tester.tap(line());
      await tester.pumpAndSettle();

      await tester.tap(button(hadco, 'budget', 'accept'));
      await tester.pumpAndSettle();
      expect(find.text('Send the response now'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('answer-now')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['respond budget accepted']);
      expect(find.text('Accepted. Dana is told.'), findsOneWidget);
      expect(row(hadco, 'budget'), findsNothing);
      expect(row(hadco, 'review'), findsOneWidget);
      expect(yearReads(engine), 1, reason: 'read once, when it opened');

      // Closed straight after: the year is read again once, behind it, so
      // the line can count it whole.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(yearReads(engine), 2);
      expect(find.text('1 waiting for your answer'), findsOneWidget);
    });

    testWidgets('one meeting of a series asks the series question too, and '
        'Decline with a message sends it', (tester) async {
      final (_, engine, hadco) = await pump(tester, events: (hadco) => [
            meeting(hadco.id, 'weekly', 'Weekly', 2, seriesId: 'series'),
          ]);
      await tester.tap(line());
      await tester.pumpAndSettle();

      await tester.tap(button(hadco, 'weekly', 'decline'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('answer-note')), 'Away that week');
      await tester.tap(find.byKey(const ValueKey('answer-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('series-one')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions,
          ['respond weekly declined note=Away that week']);
      expect(find.text('Nothing is waiting for your answer.'), findsOneWidget);
      await quiet(tester);
    });

    testWidgets('opening the calendar reads nothing more for the line, and '
        'the line does not count a year the device read an hour ago',
        (tester) async {
      final (_, engine, _) = await pump(tester,
          keptAYearAgo: const Duration(hours: 1),
          events: (hadco) => [
                meeting(hadco.id, 'budget', 'Budget', 1),
                meeting(hadco.id, 'offsite', 'Offsite', 90),
              ]);
      expect(find.text('1 waiting for your answer in the next 30 days'),
          findsOneWidget);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      expect(
          engine.reads.toSet(),
          {
            (start: DateTime(now.year, now.month, now.day - 30), end: today),
            (start: today, end: DateTime(now.year, now.month, now.day + 30)),
          },
          reason: "the Agenda's own two reads, and nothing more");
      expect(engine.reads, hasLength(2));
    });

    testWidgets('a year read within half an hour, since the last change, '
        'counts whole; an answer since leaves the line counting 30 days',
        (tester) async {
      final (_, engine, _) = await pump(tester,
          keptAYearAgo: const Duration(minutes: 5),
          events: (hadco) => [
                meeting(hadco.id, 'budget', 'Budget', 1),
                meeting(hadco.id, 'review', 'Review', 3),
                meeting(hadco.id, 'offsite', 'Offsite', 90),
              ]);
      expect(find.text('3 waiting for your answer'), findsOneWidget);

      // Answered on its sheet: the year read before it no longer vouches
      // for the meetings further off.
      await tester.tap(find.byKey(const ValueKey('agenda-event:budget')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('event-accept')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('answer-now')));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['respond budget accepted']);
      expect(find.text('1 waiting for your answer in the next 30 days'),
          findsOneWidget);
    });

    testWidgets('the list reads the year ahead, as search does, and the line '
        'counts it whole after', (tester) async {
      final (_, engine, hadco) = await pump(tester, events: (hadco) => [
            meeting(hadco.id, 'budget', 'Budget', 1),
            meeting(hadco.id, 'offsite', 'Offsite', 90),
          ]);
      expect(find.text('1 waiting for your answer in the next 30 days'),
          findsOneWidget,
          reason: 'what the device can vouch for: the 30 days the Agenda '
              'read');

      await tester.tap(line());
      await tester.pumpAndSettle();
      expect(yearReads(engine), 1);
      expect(row(hadco, 'offsite'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('2 waiting for your answer'), findsOneWidget);
      expect(yearReads(engine), 1, reason: 'nothing answered: no read more');
    });

    testWidgets('an account with a calendar beside its main one that cannot '
        'be read: its meetings are counted all the same, as the Agenda '
        'shows them', (tester) async {
      await pump(tester,
          calendars: (hadco) => [
                CalendarInfo.main(hadco.id),
                CalendarInfo(accountId: hadco.id, id: 'team', name: 'Team'),
              ],
          prepare: (engine, hadco) async => engine.unreadBeside.add(hadco.id),
          events: (hadco) => [
                meeting(hadco.id, 'budget', 'Budget', 1),
                meeting(hadco.id, 'review', 'Review', 3),
              ]);
      expect(find.byKey(const ValueKey('agenda-event:budget')), findsOneWidget);
      expect(find.text('2 waiting for your answer in the next 30 days'),
          findsOneWidget);
    });

    testWidgets('the Agenda read over half an hour ago, then another '
        "account's calendar read again for its meeting mail: the first "
        "account's meetings are still counted, as the Agenda still shows "
        'them', (tester) async {
      late Account gmail;
      final (c, engine, _) = await pump(tester,
          // Every read stamped 31 minutes back: the calendar open that long
          // since the Agenda read it.
          readsAgo: const Duration(minutes: 31),
          prepare: (engine, _) async {
            gmail = await engine.addOAuthAccount(
              displayName: 'Gmail',
              emailAddress: 'ron@gmail.example',
              provider: MailProvider.gmail,
              token: OAuthToken(
                accessToken: 'a',
                refreshToken: 'r',
                expiresAt: DateTime.utc(2030),
              ),
            );
            engine.events[gmail.id] = [meeting(gmail.id, 'lunch', 'Lunch', 2)];
          },
          events: (hadco) => [meeting(hadco.id, 'budget', 'Budget', 1)]);
      expect(find.text('2 waiting for your answer in the next 30 days'),
          findsOneWidget);

      // New meeting mail for the Gmail account: its calendar read again
      // now, and the open screens told (calendar idea #74).
      engine.events[gmail.id]!.add(meeting(gmail.id, 'party', 'Party', 5));
      engine.calendarClock = DateTime.now;
      c.read(calendarReadAgainProvider.notifier).readAgain({gmail.id});
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agenda-event:party')), findsOneWidget);
      expect(find.byKey(const ValueKey('agenda-event:budget')), findsOneWidget);
      expect(find.text('3 waiting for your answer in the next 30 days'),
          findsOneWidget);
    });

    testWidgets('Refresh with the calendar out of reach: the Agenda shows '
        'what the device kept, and the line still counts it', (tester) async {
      final (c, engine, hadco) = await pump(tester, events: (hadco) => [
            meeting(hadco.id, 'budget', 'Budget', 1),
            meeting(hadco.id, 'review', 'Review', 3),
          ]);
      expect(find.text('2 waiting for your answer in the next 30 days'),
          findsOneWidget);

      engine.calendarRefusals[hadco.id] =
          const ConnectionFailed('Could not reach Microsoft.');
      c.read(calendarRefreshProvider.notifier).now();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agenda-event:budget')), findsOneWidget);
      expect(find.byKey(const ValueKey('agenda-event:review')), findsOneWidget);
      expect(find.text('2 waiting for your answer in the next 30 days'),
          findsOneWidget);
    });

    testWidgets('an unanswered weekly series is one row, counted once: its '
        'next meeting, saying it repeats; This meeting moves it on, Every '
        'meeting takes it off', (tester) async {
      final (_, engine, hadco) = await pump(tester, events: (hadco) => [
            for (var week = 0; week < 8; week++)
              meeting(hadco.id, 'w${week + 1}', 'Weekly sync', 1 + 7 * week,
                  seriesId: 'weekly'),
            meeting(hadco.id, 'budget', 'Budget', 2),
          ]);
      expect(find.text('2 waiting for your answer in the next 30 days'),
          findsOneWidget);

      await tester.tap(line());
      await tester.pumpAndSettle();
      expect(rows(), findsNWidgets(2));
      expect(row(hadco, 'w1'), findsOneWidget);
      expect(
          find.descendant(
              of: row(hadco, 'w1'),
              matching: find.text('Repeats · 7 more not answered')),
          findsOneWidget);

      await answerRow(tester, hadco, 'w1', 'accept', series: 'series-one');
      expect(engine.calendarActions, ['respond w1 accepted']);
      expect(row(hadco, 'w1'), findsNothing);
      expect(
          find.descendant(
              of: row(hadco, 'w2'),
              matching: find.text('Repeats · 6 more not answered')),
          findsOneWidget);

      await answerRow(tester, hadco, 'w2', 'accept', series: 'series-all');
      expect(engine.calendarActions.last, 'respond w2 accepted series');
      expect(rows(), findsOneWidget);
      expect(row(hadco, 'budget'), findsOneWidget);

      // The year read again once answering stops: the series stays off,
      // though a calendar slow to show the whole series answered (as the
      // sample's is) still lists its other meetings as they were.
      await quiet(tester);
      expect(rows(), findsOneWidget);
      expect(row(hadco, 'budget'), findsOneWidget);
    });

    testWidgets("only your own calendar's meetings: not one on a calendar "
        'shared to you, though you may change it, nor the same meeting '
        'there again', (tester) async {
      final (_, _, hadco) = await pump(tester,
          calendars: (hadco) => [
                CalendarInfo.main(hadco.id),
                CalendarInfo(
                    accountId: hadco.id, id: 'dana', name: 'Dana Levi'),
              ],
          events: (hadco) => [
                meeting(hadco.id, 'budget', 'Budget', 1),
                CalendarEvent(
                  id: 'budget',
                  accountId: hadco.id,
                  calendarId: 'dana',
                  title: 'Budget',
                  start: day(1),
                  end: day(1, 11),
                  organizer: dana,
                  response: EventResponse.notResponded,
                ),
                // Yossi's invitation to Dana, not answered by her.
                CalendarEvent(
                  id: 'hers',
                  accountId: hadco.id,
                  calendarId: 'dana',
                  title: 'Supplier visit',
                  start: day(2),
                  end: day(2, 11),
                  organizer: const MailAddress(
                      email: 'yossi@hadco.example', name: 'Yossi'),
                  response: EventResponse.notResponded,
                ),
              ]);
      expect(find.text('1 waiting for your answer in the next 30 days'),
          findsOneWidget);
      await tester.tap(line());
      await tester.pumpAndSettle();
      expect(rows(), findsOneWidget);
      expect(row(hadco, 'budget'), findsOneWidget);
    });

    testWidgets("the calendar's keys do nothing while the list is open, and "
        'Esc leaves it; back on the calendar, they work again',
        (tester) async {
      final (c, _, _) = await pump(tester, events: (hadco) => [
            meeting(hadco.id, 'budget', 'Budget', 1),
          ]);
      await tester.tap(line());
      await tester.pumpAndSettle();
      expect(find.byType(WaitingAnswersScreen), findsOneWidget);

      for (final key in [
        LogicalKeyboardKey.keyD,
        LogicalKeyboardKey.keyT,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.keyG,
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.slash,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(c.read(calendarViewProvider), CalendarViewMode.agenda);
      expect(find.byType(WaitingAnswersScreen), findsOneWidget);
      expect(find.byType(NewMeetingScreen), findsNothing);
      expect(find.byType(CalendarSearchScreen), findsNothing);
      expect(find.byKey(const ValueKey('pick-next')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(WaitingAnswersScreen), findsNothing);
      expect(find.byType(CalendarScreen), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      expect(c.read(calendarViewProvider), CalendarViewMode.day);
    });

    testWidgets('a calendar read again for its meeting mail, while the list '
        'is open, sets off none of its reads, nor puts back its read once '
        'answering stops', (tester) async {
      final (c, engine, hadco) = await pump(tester, events: (hadco) => [
            meeting(hadco.id, 'a', 'Alpha', 1),
            meeting(hadco.id, 'b', 'Bravo', 2),
          ]);
      await tester.tap(line());
      await tester.pumpAndSettle();
      expect(yearReads(engine), 1);
      await answerRow(tester, hadco, 'a', 'accept');

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      // Meeting mail came: the account's calendar read again by the app's
      // keeper, and the open screens told (calendar idea #74).
      c.read(calendarReadAgainProvider.notifier).readAgain({hadco.id});
      await tester.pump();
      expect(yearReads(engine), 1, reason: 'the list reads nothing for it');

      // Five seconds after the answer, not after the news.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
      expect(yearReads(engine), 2);
      expect(rows(), findsOneWidget);
      expect(row(hadco, 'b'), findsOneWidget);
    });

    testWidgets('answered one after another, each leaves the list at once, '
        'and the year is read again once, a few seconds after the last',
        (tester) async {
      final (_, engine, hadco) = await pump(tester, events: (hadco) => [
            meeting(hadco.id, 'a', 'Alpha', 1),
            meeting(hadco.id, 'b', 'Bravo', 2),
            meeting(hadco.id, 'c', 'Charlie', 3),
            meeting(hadco.id, 'd', 'Delta', 4),
          ]);
      await tester.tap(line());
      await tester.pumpAndSettle();
      expect(yearReads(engine), 1);
      // The calendar slow to read a day again after each answer: the row
      // goes at once all the same.
      engine.slowDays = true;

      for (final (id, which) in [
        ('a', 'accept'),
        ('b', 'decline'),
        ('c', 'tentative'),
      ]) {
        await tester.tap(button(hadco, id, which));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('answer-now')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(row(hadco, id), findsNothing);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
      }
      expect(engine.calendarActions, [
        'respond a accepted',
        'respond b declined',
        'respond c tentative',
      ]);
      expect(yearReads(engine), 1, reason: 'not again with every answer');
      expect(rows(), findsOneWidget);

      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pumpAndSettle();
      expect(yearReads(engine), 2, reason: 'once answering stopped');
      expect(rows(), findsOneWidget);
      expect(row(hadco, 'd'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(yearReads(engine), 2, reason: 'read already: nothing on close');
    });
  });
}

/// The sample engine, noting each stretch the calendars are read for, and
/// with [slowDays], two seconds to read a few days again.
class _Engine extends SampleMailEngine {
  final List<CalendarRange> reads = [];
  bool slowDays = false;

  /// Accounts with a calendar beside the main one that is never read, so
  /// the device can say of no stretch of theirs when it was read, as the
  /// real engine cannot where one of an account's calendars has no read.
  final Set<String> unreadBeside = {};

  @override
  Future<KeptCalendar> keptCalendarEvents(
    String accountId,
    DateTime start,
    DateTime end,
  ) async {
    final kept = await super.keptCalendarEvents(accountId, start, end);
    return unreadBeside.contains(accountId)
        ? (events: kept.events, readAt: null)
        : kept;
  }

  @override
  Future<List<CalendarEvent>> calendarEvents(
    String accountId,
    DateTime start,
    DateTime end,
  ) async {
    reads.add((start: start, end: end));
    if (slowDays && end.difference(start) < const Duration(days: 7)) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return super.calendarEvents(accountId, start, end);
  }
}
