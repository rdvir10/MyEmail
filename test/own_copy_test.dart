import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/calendar/account_calendar.dart';
import 'package:myemail/data/calendar/calendar_upkeep.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/domain/meeting.dart' show Reminder;
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/calendar_view_providers.dart'
    show calendarRefreshProvider;
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/calendar_screen.dart'
    show showEventDetails;

import 'fakes/fake_webview.dart';

/// Your own reminder and show as on someone else's meeting (calendar idea
/// #45): changed on your own copy alone, telling nobody, and MyEmail's own
/// reminder of it follows.
void main() {
  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});
  Map<String, Object?> bodyOf(http.Request r) =>
      (jsonDecode(r.body) as Map).cast<String, Object?>();

  const dana = MailAddress(email: 'dana.levi@hadco.example', name: 'Dana Levi');
  const ron = MailAddress(email: 'ron@hadco.example', name: 'Ron');

  /// Dana's meeting with Ron invited, next Tuesday at two.
  CalendarEvent invited(
    String accountId, {
    String id = 'm',
    String? seriesId,
    int? reminder = 15,
    EventShowAs showAs = EventShowAs.busy,
    EventResponse response = EventResponse.accepted,
    bool readOnly = false,
    bool cancelled = false,
    String calendarId = CalendarEvent.mainCalendar,
    DateTime? start,
  }) {
    final from = start ?? DateTime(2026, 11, 24, 14);
    return CalendarEvent(
      id: id,
      accountId: accountId,
      calendarId: calendarId,
      title: 'Supplier call',
      start: from,
      end: from.add(const Duration(hours: 1)),
      organizer: dana,
      attendees: [
        const EventAttendee(dana, response: EventResponse.organizer),
        EventAttendee(ron, response: response),
      ],
      response: response,
      seriesId: seriesId,
      reminderMinutes: reminder,
      showAs: showAs,
      readOnly: readOnly,
      cancelled: cancelled,
    );
  }

  group('on the wire, only your own copy changes', () {
    late List<http.Request> sent;
    http_testing.MockClient client([http.Response Function(http.Request)? a]) {
      sent = [];
      return http_testing.MockClient((r) async {
        sent.add(r);
        return a?.call(r) ?? json({});
      });
    }

    GraphCalendarApi graph([http.Response Function(http.Request)? a]) =>
        GraphCalendarApi(
          accessToken: ({bool force = false}) async => 'token',
          httpClient: client(a),
          sleep: (_) async {},
        );
    GoogleCalendarApi google() => GoogleCalendarApi(
          accessToken: ({bool force = false}) async => 'token',
          httpClient: client(),
          sleep: (_) async {},
        );

    test('Microsoft: the reminder, and nothing else of the meeting', () async {
      final api = graph();
      await api.changeOwnCopy('e/1', reminder: const Reminder.before(30));
      expect(sent.single.method, 'PATCH');
      expect(sent.single.url.path, '/v1.0/me/events/e%2F1');
      expect(bodyOf(sent.single),
          {'isReminderOn': true, 'reminderMinutesBeforeStart': 30});

      await api.changeOwnCopy('e1', reminder: const Reminder.none());
      expect(bodyOf(sent.last), {'isReminderOn': false});
    });

    test('Microsoft: how it shows you, and nothing else of the meeting',
        () async {
      final api = graph();
      await api.changeOwnCopy('e1', showAs: EventShowAs.free);
      expect(bodyOf(sent.single), {'showAs': 'free'});
      await api.changeOwnCopy('e1', showAs: EventShowAs.outOfOffice);
      expect(bodyOf(sent.last), {'showAs': 'oof'});
      await api.changeOwnCopy('e1', showAs: EventShowAs.workingElsewhere);
      expect(bodyOf(sent.last), {'showAs': 'workingElsewhere'});
      expect([for (final r in sent) r.method], everyElement('PATCH'),
          reason: 'no answer, no forward: nothing that writes to anyone');
    });

    test('Microsoft: a meeting gone meanwhile says so', () async {
      await expectLater(
        graph((_) => json({'error': {'code': 'ErrorItemNotFound'}}, 404))
            .changeOwnCopy('e1', showAs: EventShowAs.free),
        throwsA(isA<EventGone>()),
      );
    });

    test('Google: the reminder on the phone, or busy or free, with Google '
        'told to write to nobody', () async {
      final api = google();
      await api.changeOwnCopy('g1', reminder: const Reminder.before(30));
      expect(sent.single.method, 'PATCH');
      expect(sent.single.url.path, '/calendar/v3/calendars/primary/events/g1');
      expect(sent.single.url.queryParameters['sendUpdates'], 'none');
      expect(bodyOf(sent.single), {
        'reminders': {
          'useDefault': false,
          'overrides': [
            {'method': 'popup', 'minutes': 30},
          ],
        },
      });

      await api.changeOwnCopy('g1',
          showAs: EventShowAs.free, calendarId: 'team@group.calendar');
      expect(sent.last.url.path,
          '/calendar/v3/calendars/team%40group.calendar/events/g1');
      expect(sent.last.url.queryParameters['sendUpdates'], 'none');
      expect(bodyOf(sent.last), {'transparency': 'transparent'});

      await api.changeOwnCopy('g1', showAs: EventShowAs.busy);
      expect(bodyOf(sent.last), {'transparency': 'opaque'});
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
      const withPassword = Account(
        id: 'p',
        displayName: 'Gmail',
        emailAddress: 'ron@gmail.example',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.appPassword,
        colorValue: 0xFF007258,
      );
      AccountCalendar calendar() => AccountCalendar(
            accessToken: (id,
                    {bool force = false, List<String>? scopes}) async =>
                'token',
            accounts: () => const [microsoft],
            httpClient: client(),
            sleep: (_) async {},
          );

      test('one meeting of a series, or every one', () async {
        final c = calendar();
        final one = invited('a', id: 'occurrence-4', seriesId: 'series-1');
        await c.changeOwnCopy(microsoft, one,
            reminder: const Reminder.before(5));
        expect(sent.single.url.path, endsWith('/events/occurrence-4'));
        await c.changeOwnCopy(microsoft, one,
            reminder: const Reminder.before(5), wholeSeries: true);
        expect(sent.last.url.path, endsWith('/events/series-1'));
      });

      test("not a meeting of your own, which Edit changes, telling them; "
          'not a calendar the app cannot reach', () async {
        final c = calendar();
        final own = CalendarEvent(
          id: 'mine',
          accountId: 'a',
          title: 'Q4 planning',
          start: DateTime(2026, 11, 24, 15),
          end: DateTime(2026, 11, 24, 16),
          isOrganizer: true,
          response: EventResponse.organizer,
          attendees: const [EventAttendee(dana)],
        );
        await expectLater(
            c.changeOwnCopy(microsoft, own, showAs: EventShowAs.free),
            throwsA(isA<ArgumentError>()));
        await expectLater(
            c.changeOwnCopy(withPassword, invited('p'),
                showAs: EventShowAs.free),
            throwsA(isA<CalendarUnavailable>()));
        expect(sent, isEmpty);
      });
    });
  });

  group("MyEmail's own reminder of it follows", () {
    test('a reminder moved, then taken away, is set again from the copy '
        'as the calendar now has it', () async {
      final engine = SampleMailEngine();
      final notifier = FakeMailNotifier();
      final ui = MemoryUiStateStore();
      final hadco = await engine.addOAuthAccount(
        displayName: 'Hadco',
        emailAddress: 'ron@hadco.example',
        provider: MailProvider.outlook,
        token: OAuthToken(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.utc(2030),
        ),
      );
      final now = DateTime(2026, 11, 24, 9);
      final meeting = invited(hadco.id);
      engine.events[hadco.id] = [meeting];
      Future<void> run() => CalendarUpkeep(
            engine: engine,
            notifier: notifier,
            uiState: ui,
            surface: FakeHomeScreenSurface(),
            clock: () => now,
          ).run();

      await run();
      expect(notifier.meetingReminders.values.single.at,
          DateTime(2026, 11, 24, 13, 45));

      await engine.changeOwnCopy(meeting, reminder: const Reminder.before(60));
      await run();
      expect(notifier.meetingReminders.values.single.at,
          DateTime(2026, 11, 24, 13),
          reason: 'an hour before, as the copy now says');

      await engine.changeOwnCopy(engine.events[hadco.id]!.single,
          reminder: const Reminder.none());
      await run();
      expect(notifier.meetingReminders, isEmpty,
          reason: 'none now, and the one set is taken back');
    });
  });

  group("on the meeting's sheet", () {
    setUpAll(FakeWebViewPlatform.install);

    late SampleMailEngine engine;
    late ProviderContainer container;
    late Account account;

    Future<void> pump(
      WidgetTester tester,
      CalendarEvent Function(Account a) event, {
      MailProvider provider = MailProvider.outlook,
      CalendarPrefs? prefs,
    }) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Whatever an earlier pump of the same test left open, gone.
      await tester.pumpWidget(const SizedBox());
      engine = SampleMailEngine();
      account = (await tester.runAsync(() => engine.addOAuthAccount(
            displayName: 'Hadco',
            emailAddress: provider == MailProvider.gmail
                ? 'ron@gmail.example'
                : 'ron@hadco.example',
            provider: provider,
            token: OAuthToken(
              accessToken: 'a',
              refreshToken: 'r',
              expiresAt: DateTime.utc(2030),
            ),
          )))!;
      final shown = event(account);
      engine.events[account.id] = [shown];
      final ui = MemoryUiStateStore();
      if (prefs != null) {
        await ui.writeString(
            UiStateKeys.calendarPrefs, jsonEncode(prefs.toJson()));
      }
      container = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine),
        deviceCalendarProvider.overrideWithValue(
            FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
        meetingClockProvider
            .overrideWithValue(() => DateTime(2026, 11, 17, 9)),
      ]);
      addTearDown(container.dispose);
      // The accounts, read as the calendar screen has them read: by the
      // time the tree below has settled.
      container.listen(accountsProvider, (_, _) {});
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  key: const ValueKey('open-sheet'),
                  onPressed: () =>
                      showEventDetails(context, ref, shown, account),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-sheet')));
      await tester.pumpAndSettle();
    }

    /// The ⋮ menu's entries, in order, by their words; open after.
    Future<List<String>> menu(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('event-more')));
      await tester.pumpAndSettle();
      return [
        for (final item in tester.widgetList<PopupMenuItem<String>>(
            find.byType(PopupMenuItem<String>)))
          (item.child! as Text).data!,
      ];
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    /// The choices a dialog of [prefix]'s offers, by their words, and the
    /// one marked as what it is now.
    ({List<String> all, String? now}) choices(
        WidgetTester tester, String prefix) {
      final keys = [
        for (final w in tester.widgetList(find.byType(SimpleDialogOption)))
          if (w.key case final ValueKey<String> key
              when key.value.startsWith('$prefix:'))
            key,
      ];
      String words(Key key) => tester
          .widgetList<Text>(find.descendant(
              of: find.byKey(key), matching: find.byType(Text)))
          .map((t) => t.data)
          .join();
      return (
        all: [for (final k in keys) words(k)],
        now: [
          for (final k in keys)
            if (find
                .descendant(
                    of: find.byKey(k), matching: find.byIcon(Icons.check))
                .evaluate()
                .isNotEmpty)
              words(k),
        ].singleOrNull,
      );
    }

    String? said(WidgetTester tester) {
      final bar = find.byType(SnackBar);
      if (bar.evaluate().isEmpty) return null;
      return tester
          .widget<Text>(
              find.descendant(of: bar, matching: find.byType(Text)).first)
          .data;
    }

    testWidgets("someone else's meeting: My reminder and Show me as under ⋮, "
        'after Propose a new time', (tester) async {
      await pump(tester, (a) => invited(a.id));
      expect(await menu(tester), [
        'Email everyone',
        'Forward',
        'Propose a new time',
        'My reminder',
        'Show me as',
        'Duplicate',
        'Decline and remove',
      ]);
    });

    testWidgets('not on a meeting of your own, one on a calendar only read, '
        'one cancelled or one declined', (tester) async {
      await pump(
          tester,
          (a) => CalendarEvent(
                id: 'mine',
                accountId: a.id,
                title: 'Q4 planning',
                start: DateTime(2026, 11, 24, 15),
                end: DateTime(2026, 11, 24, 16),
                organizer: ron,
                isOrganizer: true,
                response: EventResponse.organizer,
                attendees: const [EventAttendee(dana)],
              ));
      expect(await menu(tester), isNot(contains('My reminder')));

      for (final other in [
        (String id) => invited(id, cancelled: true),
        (String id) => invited(id, response: EventResponse.declined),
      ]) {
        await pump(tester, (a) => other(a.id),
            provider: MailProvider.gmail);
        final items = await menu(tester);
        expect(items, isNot(contains('My reminder')));
        expect(items, isNot(contains('Show me as')));
      }

      await pump(tester, (a) => invited(a.id, readOnly: true));
      expect(find.byKey(const ValueKey('event-more')), findsNothing);
    });

    testWidgets('My reminder: the reminder as it is marked; another chosen '
        'goes to your copy alone, and the calendar is read again for '
        "MyEmail's own", (tester) async {
      await pump(tester, (a) => invited(a.id));
      await menu(tester);
      await tapKey(tester, 'event-my-reminder');
      expect(find.text('Only your calendar changes. Nobody is told.'),
          findsOneWidget);
      final offered = choices(tester, 'my-reminder');
      expect(offered.all, [
        'None',
        'At the start',
        '5 minutes before',
        '15 minutes before',
        '30 minutes before',
        '1 hour before',
        '1 day before',
      ]);
      expect(offered.now, '15 minutes before');
      // What a screen reader is told: which is chosen now.
      final now = tester
          .getSemantics(find.byKey(const ValueKey('my-reminder:15')))
          .getSemanticsData();
      expect(now.flagsCollection.isSelected, Tristate.isTrue);

      final before = container.read(calendarRefreshProvider);
      await tapKey(tester, 'my-reminder:30');
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['own m reminder=30']);
      expect(said(tester), 'Your reminder: 30 minutes before. Nobody is told.');
      expect(container.read(calendarRefreshProvider), isNot(before),
          reason: 'read again, and with it the reminders MyEmail sets');
      expect(engine.events[account.id]!.single.reminderMinutes, 30);
    });

    testWidgets("a reminder not among the usual ones is offered as it is",
        (tester) async {
      await pump(tester, (a) => invited(a.id, reminder: 10));
      await menu(tester);
      await tapKey(tester, 'event-my-reminder');
      final offered = choices(tester, 'my-reminder');
      expect(offered.now, '10 minutes before');
      expect(offered.all, contains('10 minutes before'));
      expect(offered.all.first, 'None');

      await pump(tester, (a) => invited(a.id, reminder: null));
      await menu(tester);
      await tapKey(tester, 'event-my-reminder');
      expect(choices(tester, 'my-reminder').now, 'None');
    });

    testWidgets('None, where Settings have MyEmail remind of a meeting with '
        'none, says it still will', (tester) async {
      await pump(tester, (a) => invited(a.id),
          prefs: const CalendarPrefs(reminderIfNone: 10));
      await menu(tester);
      await tapKey(tester, 'event-my-reminder');
      await tapKey(tester, 'my-reminder:none');
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['own m reminder=none']);
      expect(
          said(tester),
          'No reminder from the calendar. MyEmail still reminds you 10 '
          'minutes before, as Settings say. Nobody is told.');
    });

    testWidgets('None, with no such setting: no reminder', (tester) async {
      await pump(tester, (a) => invited(a.id));
      await menu(tester);
      await tapKey(tester, 'event-my-reminder');
      await tapKey(tester, 'my-reminder:none');
      await tester.pumpAndSettle();
      expect(said(tester), 'No reminder. Nobody is told.');
    });

    testWidgets('one meeting of a series: this one, or every one',
        (tester) async {
      await pump(tester, (a) => invited(a.id, seriesId: 's1'));
      await menu(tester);
      await tapKey(tester, 'event-show-me-as');
      await tapKey(tester, 'show-me-as:free');
      expect(find.byKey(const ValueKey('series-all')), findsOneWidget);
      await tapKey(tester, 'series-all');
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['own m showAs=free series']);
      expect(said(tester), 'You show as free. Nobody is told.');
    });

    testWidgets('Show me as on a Microsoft calendar: as Outlook offers it',
        (tester) async {
      await pump(tester, (a) => invited(a.id, showAs: EventShowAs.tentative));
      await menu(tester);
      await tapKey(tester, 'event-show-me-as');
      final offered = choices(tester, 'show-me-as');
      expect(offered.all,
          ['Busy', 'Free', 'Tentative', 'Out of office', 'Working elsewhere']);
      expect(offered.now, 'Tentative');
      await tapKey(tester, 'show-me-as:outOfOffice');
      await tester.pumpAndSettle();
      expect(engine.calendarActions, ['own m showAs=outOfOffice']);
      expect(said(tester), 'You show as out of office. Nobody is told.');
    });

    testWidgets('Show me as on a Google calendar: busy or free, a meeting '
        'answered maybe being busy there', (tester) async {
      await pump(
          tester,
          (a) => invited(a.id,
              showAs: EventShowAs.tentative,
              response: EventResponse.tentative),
          provider: MailProvider.gmail);
      await menu(tester);
      await tapKey(tester, 'event-show-me-as');
      final offered = choices(tester, 'show-me-as');
      expect(offered.all, ['Busy', 'Free']);
      expect(offered.now, 'Busy');
    });

    testWidgets('backed out of, nothing is changed', (tester) async {
      await pump(tester, (a) => invited(a.id));
      await menu(tester);
      await tapKey(tester, 'event-my-reminder');
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, isEmpty);
    });

    testWidgets('refused, it says so, and nothing is shown as changed',
        (tester) async {
      await pump(tester, (a) => invited(a.id));
      engine.calendarRefusals[account.id] =
          const ConnectionFailed('Could not reach Microsoft.');
      await menu(tester);
      await tapKey(tester, 'event-my-reminder');
      await tapKey(tester, 'my-reminder:30');
      await tester.pumpAndSettle();
      expect(said(tester),
          'Could not change your reminder: Could not reach Microsoft.');
      expect(engine.calendarActions, isEmpty);
    });
  });
}
