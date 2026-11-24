import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart' show SignInNeedsConsent;
import 'package:myemail/data/calendar/calendar_upkeep.dart';
import 'package:myemail/data/calendar/internet_calendars.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/account_calendars.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/internet_calendar.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/domain/meeting_alerts.dart' show MeetingReminder;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// The meeting reminders (#31), the morning agenda (#33) and the calendar
/// widget's meetings (#11), kept up to date from the calendars.
void main() {
  late _ReadingEngine engine;
  late FakeMailNotifier notifier;
  late FakeHomeScreenSurface surface;
  late MemoryUiStateStore ui;
  late Account hadco;
  late DateTime now;

  final token = OAuthToken(
    accessToken: 'a',
    refreshToken: 'r',
    expiresAt: DateTime.utc(2030),
  );

  setUp(() async {
    engine = _ReadingEngine();
    notifier = FakeMailNotifier();
    surface = FakeHomeScreenSurface();
    ui = MemoryUiStateStore();
    // A Sunday evening, before a working week.
    now = DateTime(2026, 10, 25, 20);
    hadco = await engine.addOAuthAccount(
      displayName: 'Hadco',
      emailAddress: 'ron@hadco.example',
      provider: MailProvider.outlook,
      token: token,
    );
  });

  CalendarEvent meeting(
    String id,
    DateTime start, {
    String title = 'Weekly sync',
    int? reminder = 15,
    EventResponse response = EventResponse.accepted,
    String? accountId,
  }) =>
      CalendarEvent(
        id: id,
        accountId: accountId ?? hadco.id,
        title: title,
        start: start,
        end: start.add(const Duration(minutes: 30)),
        reminderMinutes: reminder,
        response: response,
        organizer: const MailAddress(email: 'dana@example.com'),
        joinUrl: 'https://teams.microsoft.com/l/meetup-join/x',
      );

  Future<void> run() => CalendarUpkeep(
        engine: engine,
        notifier: notifier,
        uiState: ui,
        surface: surface,
        clock: () => now,
      ).run();

  test("sets each meeting's reminder for its own time", () async {
    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 9, 30), title: 'Stand-up'),
      meeting('b', DateTime(2026, 10, 26, 14), reminder: null),
    ];
    await run();
    final set = notifier.meetingReminders.values.single;
    expect(set.at, DateTime(2026, 10, 26, 9, 15));
    expect(set.meeting.title, 'Stand-up');
    expect(set.canJoin, isTrue);
    expect(set.canTellLate, isTrue);
  });

  // On Ron's tablet a reminder showed neither a calendar nor its account's
  // colour (2026-11-16): each carries its account's colour now.
  test("a reminder wears its account's colour", () async {
    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 9, 30), title: 'Stand-up'),
    ];
    await run();
    expect(notifier.meetingReminders.values.single.meeting.colour,
        hadco.colorValue);
  });

  test("a Google account's are left to Google until switched on", () async {
    final gmail = await engine.addOAuthAccount(
      displayName: 'Gmail',
      emailAddress: 'ron@gmail.example',
      provider: MailProvider.gmail,
      token: token,
    );
    engine.events[hadco.id] = const [];
    engine.events[gmail.id] = [
      meeting('g', DateTime(2026, 10, 26, 11), accountId: gmail.id),
    ];
    await run();
    expect(notifier.meetingReminders, isEmpty);

    await ui.writeString(
      UiStateKeys.calendarPrefs,
      jsonEncode(const CalendarPrefs()
          .copyWith(meetingReminders: {gmail.id: true}).toJson()),
    );
    await run();
    expect(notifier.meetingReminders.values.single.meeting.eventId, 'g');
  });

  test('one declined, moved or taken off has its reminder taken back',
      () async {
    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 10)),
      meeting('b', DateTime(2026, 10, 26, 11)),
      meeting('c', DateTime(2026, 10, 26, 12)),
    ];
    await run();
    expect(notifier.meetingReminders, hasLength(3));

    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 10),
          response: EventResponse.declined),
      meeting('b', DateTime(2026, 10, 26, 16)),
    ];
    await run();
    final left = notifier.meetingReminders.values.single;
    expect(left.meeting.eventId, 'b');
    expect(left.at, DateTime(2026, 10, 26, 15, 45), reason: 'moved with it');
  });

  test('one whose time has come goes off now, and once', () async {
    now = DateTime(2026, 10, 26, 9, 50);
    engine.events[hadco.id] = [meeting('a', DateTime(2026, 10, 26, 10))];
    await run();
    final set = notifier.meetingReminders.values.single;
    expect(set.at.difference(now).inSeconds, lessThan(5));

    // Gone off, and swiped away; the next pass leaves it so.
    notifier.meetingReminders.clear();
    now = DateTime(2026, 10, 26, 9, 55);
    await run();
    expect(notifier.meetingReminders, isEmpty);
  });

  test('a meeting made inside its reminder time goes off, however long the '
      'calendars take to read', () async {
    // Made at 10:50 for 11:00, with a quarter of an hour's reminder: set
    // for now. Each calendar is read over the network first, which takes
    // seconds on a phone, and Android refuses a time that has passed.
    now = DateTime(2026, 10, 26, 10, 50);
    engine.events[hadco.id] = [meeting('a', DateTime(2026, 10, 26, 11))];
    engine.onRead = () => now = now.add(const Duration(seconds: 5));
    final android = _AndroidNotifier(() => now);
    await CalendarUpkeep(
      engine: engine,
      notifier: android,
      uiState: ui,
      surface: surface,
      clock: () => now,
    ).run();
    final set = android.meetingReminders.values.single;
    expect(set.meeting.eventId, 'a');
    expect(set.at.isAfter(now), isTrue);
    expect(set.at.difference(now).inSeconds, lessThan(5));
    expect(surface.calendarRedraws, 1, reason: 'the widget drawn too');
  });

  test('a reminder Android will not take leaves the rest, the agenda and '
      'the widget, and is tried again', () async {
    now = DateTime(2026, 10, 26, 9, 50);
    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 10)),
      meeting('b', DateTime(2026, 10, 26, 14)),
      meeting('c', DateTime(2026, 10, 27, 9, 30)),
    ];
    final android = _AndroidNotifier(() => now)..refused.add('a');
    Future<void> pass() => CalendarUpkeep(
          engine: engine,
          notifier: android,
          uiState: ui,
          surface: surface,
          clock: () => now,
        ).run();
    await pass();
    expect(
      [for (final r in android.meetingReminders.values) r.meeting.eventId],
      unorderedEquals(['b', 'c']),
    );
    expect(android.agendas, hasLength(1), reason: "tomorrow's agenda");
    expect(surface.calendarRedraws, 1);

    // It never went off: set once Android takes it.
    android.refused.clear();
    now = DateTime(2026, 10, 26, 9, 55);
    await pass();
    expect(
      [for (final r in android.meetingReminders.values) r.meeting.eventId],
      contains('a'),
    );
  });

  test('switched off, the reminders still to come are taken back', () async {
    engine.events[hadco.id] = [meeting('a', DateTime(2026, 10, 26, 10))];
    await run();
    expect(notifier.meetingReminders, hasLength(1));
    await ui.writeString(
      UiStateKeys.calendarPrefs,
      jsonEncode(const CalendarPrefs()
          .copyWith(meetingReminders: {hadco.id: false}).toJson()),
    );
    await run();
    expect(notifier.meetingReminders, isEmpty);
  });

  test('the morning agenda for the next working morning, quiet on an empty '
      'day', () async {
    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 9, 30), title: 'Stand-up'),
      meeting('b', DateTime(2026, 10, 26, 14), title: 'Design review'),
    ];
    await run();
    final agenda = notifier.agendas.values.single;
    expect(agenda.at, DateTime(2026, 10, 26, 7, 30));
    expect(agenda.title, '2 meetings today');
    expect(agenda.body, 'The first at 09:30: Stand-up');
    expect(agenda.payload, 'myemail-calendar:2026-10-26');

    engine.events[hadco.id] = const [];
    await run();
    expect(notifier.agendas, isEmpty, reason: 'nothing on: taken back');
  });

  test('the agenda at the time chosen, or not at all', () async {
    engine.events[hadco.id] = [meeting('a', DateTime(2026, 10, 26, 10))];
    await ui.writeString(
      UiStateKeys.calendarPrefs,
      jsonEncode(const CalendarPrefs().copyWith(agendaAt: 8 * 60).toJson()),
    );
    await run();
    expect(notifier.agendas.values.single.at, DateTime(2026, 10, 26, 8));
    await ui.writeString(
      UiStateKeys.calendarPrefs,
      jsonEncode(const CalendarPrefs().copyWith(noAgenda: true).toJson()),
    );
    await run();
    expect(notifier.agendas, isEmpty);
  });

  test("the widget is given today's and tomorrow's meetings", () async {
    now = DateTime(2026, 10, 26, 9);
    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 10), title: 'Stand-up'),
      meeting('b', DateTime(2026, 10, 27, 10), title: 'Tomorrow'),
      meeting('c', DateTime(2026, 10, 28, 10), title: 'Later'),
    ];
    await run();
    final rows =
        jsonDecode(surface.values[CalendarUpkeep.widgetKey]! as String) as List;
    expect([for (final r in rows) r['t']], ['Stand-up', 'Tomorrow']);
    final first = rows.first as Map;
    expect(first['s'], DateTime(2026, 10, 26, 10).millisecondsSinceEpoch);
    expect(first['c'], hadco.colorValue.toSigned(32));
    expect(first['j'], 'https://teams.microsoft.com/l/meetup-join/x');
    expect(first['l'], startsWith('myemail://event?'));
    expect(surface.calendarRedraws, 1);
  });

  // The widget drew a holiday as it draws a meeting, full strength.
  test('the widget is told which of them show as free, to draw them pale',
      () async {
    now = DateTime(2026, 10, 26, 9);
    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 10), title: 'Stand-up'),
      CalendarEvent(
        id: 'h',
        accountId: hadco.id,
        title: 'Holiday',
        start: DateTime(2026, 10, 26),
        end: DateTime(2026, 10, 27),
        allDay: true,
        showAs: EventShowAs.free,
      ),
    ];
    await run();
    final rows =
        jsonDecode(surface.values[CalendarUpkeep.widgetKey]! as String) as List;
    final byTitle = {for (final r in rows) r['t']: r as Map};
    expect(byTitle['Holiday']!['f'], isTrue);
    expect(byTitle['Holiday']!['a'], isTrue);
    expect(byTitle['Stand-up']!.containsKey('f'), isFalse);
  });

  // The views know Ron by every account's address; the widget knew him only
  // by those with a calendar, so a copy organised from his old IMAP address
  // folded in the views and showed twice on the widget.
  test("the widget knows Ron by every account's address, as the views do",
      () async {
    now = DateTime(2026, 10, 26, 9);
    await engine.addAccount(
      displayName: 'Old',
      emailAddress: 'ron@old.example',
      provider: MailProvider.gmail,
      secret: 'app-password',
    );
    engine.calendarLists[hadco.id] = [
      CalendarInfo.main(hadco.id),
      for (final id in ['birthdays', 'family'])
        CalendarInfo(accountId: hadco.id, id: id, name: id, canEdit: false),
    ];
    engine.events[hadco.id] = [
      for (final (id, organiser) in [
        ('birthdays', 'ron@old.example'),
        ('family', null),
      ])
        CalendarEvent(
          id: id,
          accountId: hadco.id,
          calendarId: id,
          title: "Dana's birthday",
          start: DateTime(2026, 10, 26),
          end: DateTime(2026, 10, 27),
          allDay: true,
          showAs: EventShowAs.free,
          readOnly: true,
          organizer: organiser == null ? null : MailAddress(email: organiser),
        ),
    ];
    await run();
    final rows =
        jsonDecode(surface.values[CalendarUpkeep.widgetKey]! as String) as List;
    expect([for (final r in rows) r['t']], ["Dana's birthday"]);
  });

  test('the widget is told which meetings last a day or more', () async {
    now = DateTime(2026, 10, 26, 9);
    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 10), title: 'Stand-up'),
      CalendarEvent(
        id: 'v',
        accountId: hadco.id,
        title: 'Vacation',
        start: DateTime(2026, 10, 26, 8),
        end: DateTime(2026, 10, 30, 8, 30),
        showAs: EventShowAs.free,
      ),
    ];
    await run();
    final rows =
        jsonDecode(surface.values[CalendarUpkeep.widgetKey]! as String) as List;
    final byTitle = {for (final r in rows) r['t']: r as Map};
    expect(byTitle['Vacation']!['m'], isTrue);
    expect(byTitle['Vacation']!.containsKey('a'), isFalse);
    expect(byTitle['Stand-up']!.containsKey('m'), isFalse);
  });

  test('a calendar that cannot be read keeps what the device kept', () async {
    engine.events[hadco.id] = [meeting('a', DateTime(2026, 10, 26, 10))];
    await run();
    notifier.meetingReminders.clear();
    engine.calendarRefusals[hadco.id] =
        const SignInNeedsConsent('Allow it first.');
    await run();
    expect(notifier.meetingReminders.values.single.meeting.eventId, 'a');
  });

  test('brought up to date every quarter of an hour at most, at once when '
      'something changed', () async {
    engine.events[hadco.id] = [meeting('a', DateTime(2026, 10, 26, 10))];
    var at = now;
    Future<void> pass({bool force = false}) => keepCalendarUpIfDue(
          engine,
          ui,
          notifier,
          surface,
          force: force,
          clock: () => at,
        );
    await pass();
    expect(surface.calendarRedraws, 1);
    at = now.add(const Duration(minutes: 10));
    await pass();
    expect(surface.calendarRedraws, 1, reason: 'too soon');
    await pass(force: true);
    expect(surface.calendarRedraws, 2);
    at = now.add(const Duration(minutes: 26));
    await pass();
    expect(surface.calendarRedraws, 3);
  });

  group('the app and the worker, each with its own copy of the settings',
      () {
    // Each reads the device's settings once and keeps a copy. The worker
    // reads its copy again each pass; the app, kept alive for days by
    // push, does not. What the worker set was not in the app's copy.
    late UiStateStore app;
    late UiStateStore worker;

    setUp(() async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      Future<UiStateStore> copy() async => PrefsUiStateStore(
            await SharedPreferencesWithCache.create(
              cacheOptions: const SharedPreferencesWithCacheOptions(),
            ),
          );
      app = await copy();
      worker = await copy();
    });

    Future<void> runIn(UiStateStore store) => CalendarUpkeep(
          engine: engine,
          notifier: notifier,
          uiState: store,
          surface: surface,
          clock: () => now,
        ).run();

    test('a reminder the worker set and that went off is not set again by '
        'the app', () async {
      now = DateTime(2026, 10, 26, 9);
      engine.events[hadco.id] = [meeting('a', DateTime(2026, 10, 26, 10))];
      await runIn(worker);
      expect(notifier.meetingReminders.values.single.at,
          DateTime(2026, 10, 26, 9, 45));

      // Gone off at 9:45, and swiped away; the app opened at 9:47.
      notifier.meetingReminders.clear();
      now = DateTime(2026, 10, 26, 9, 47);
      await runIn(app);
      expect(notifier.meetingReminders, isEmpty);
    });

    test('an agenda the worker set is taken back by the app once the day '
        'is empty', () async {
      engine.events[hadco.id] = [meeting('a', DateTime(2026, 10, 26, 10))];
      await runIn(worker);
      expect(notifier.agendas, hasLength(1));

      engine.events[hadco.id] = const [];
      now = now.add(const Duration(hours: 1));
      await runIn(app);
      expect(notifier.agendas, isEmpty, reason: 'nothing on Monday now');
    });

    test('kept up by the worker a moment ago, the app waits its quarter of '
        'an hour', () async {
      engine.events[hadco.id] = [meeting('a', DateTime(2026, 10, 26, 10))];
      Future<void> pass(UiStateStore store) => keepCalendarUpIfDue(
            engine,
            store,
            notifier,
            surface,
            clock: () => now,
          );
      await pass(worker);
      expect(surface.calendarRedraws, 1);
      now = now.add(const Duration(minutes: 5));
      await pass(app);
      expect(surface.calendarRedraws, 1, reason: 'too soon');
    });
  });

  // The calendar keeps up with meeting mail (#74): the account whose
  // invitation, change or cancellation has just arrived is read again at
  // once, and nothing else is asked of any server.
  group('meeting mail arriving (#74)', () {
    late Account gmail;

    setUp(() async {
      gmail = await engine.addOAuthAccount(
        displayName: 'Gmail',
        emailAddress: 'ron@gmail.example',
        provider: MailProvider.gmail,
        token: token,
      );
      await ui.writeString(
        UiStateKeys.calendarPrefs,
        jsonEncode(const CalendarPrefs()
            .copyWith(meetingReminders: {gmail.id: true}).toJson()),
      );
      engine.events[hadco.id] = [meeting('h', DateTime(2026, 10, 26, 10))];
      engine.events[gmail.id] = [
        meeting('g', DateTime(2026, 10, 26, 11), accountId: gmail.id),
      ];
    });

    Future<void> keepUp(
      DateTime at, {
      Set<String> meetingMail = const {},
      InternetCalendars links = const NoInternetCalendars(),
    }) =>
        keepCalendarUpIfDue(
          engine,
          ui,
          notifier,
          surface,
          links: links,
          meetingMail: meetingMail,
          clock: () => at,
        );

    Map<String, DateTime> reminders() => {
          for (final r in notifier.meetingReminders.values)
            r.meeting.eventId: r.at,
        };

    test("reads that account's calendar at once, and the others as the "
        'device kept them', () async {
      await keepUp(now);
      // Both moved since; only Hadco's mail has come.
      engine.events[hadco.id] = [meeting('h', DateTime(2026, 10, 26, 14))];
      engine.events[gmail.id] = [
        meeting('g', DateTime(2026, 10, 26, 15), accountId: gmail.id),
      ];
      engine.read.clear();
      final drawn = surface.calendarRedraws;

      await keepUp(now.add(const Duration(minutes: 2)),
          meetingMail: {hadco.id});

      expect(reminders()['h'], DateTime(2026, 10, 26, 13, 45),
          reason: 'moved with its mail');
      expect(reminders()['g'], DateTime(2026, 10, 26, 10, 45),
          reason: 'as the device kept it, until its own read');
      expect(engine.read, [hadco.id], reason: 'no other calendar asked');
      expect(surface.calendarRedraws, drawn + 1, reason: 'the widget too');
    });

    test('other mail waits for the quarter hour, which it does not put '
        'off', () async {
      await keepUp(now);
      engine.read.clear();
      await keepUp(now.add(const Duration(minutes: 5)));
      expect(engine.read, isEmpty, reason: 'as before');

      await keepUp(now.add(const Duration(minutes: 6)),
          meetingMail: {hadco.id});
      engine.read.clear();
      await keepUp(now.add(const Duration(minutes: 16)));
      expect(engine.read, unorderedEquals([hadco.id, gmail.id]),
          reason: 'the quarter hour counted from the last whole read');
    });

    test('an account with no calendar here reads nothing at all', () async {
      final imap = await engine.addAccount(
        displayName: 'Old ISP',
        emailAddress: 'ron@isp.example',
        provider: MailProvider.gmail,
        secret: 'app-password',
      );
      await keepUp(now);
      engine.read.clear();
      final drawn = surface.calendarRedraws;

      await keepUp(now.add(const Duration(minutes: 2)),
          meetingMail: {imap.id});

      expect(engine.read, isEmpty);
      expect(surface.calendarRedraws, drawn, reason: 'nothing to redo');
    });

    test('a calendar from a link is taken as it was last read', () async {
      const link = InternetCalendar(
        id: 'il',
        name: 'Holidays in Israel',
        url: 'https://example.com/il.ics',
        colour: 0xFF0B8043,
      );
      await ui.writeString(
          UiStateKeys.internetCalendars, InternetCalendar.listToText([link]));
      final links = MemoryInternetCalendars({
        link.url: 'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:h\r\n'
            'SUMMARY:Holiday\r\nDTSTART;VALUE=DATE:20261026\r\n'
            'DTEND;VALUE=DATE:20261027\r\nEND:VEVENT\r\nEND:VCALENDAR',
      })
        // Read long enough ago to be due again.
        ..clock = () => now.subtract(const Duration(days: 1));
      await keepUp(now, links: links);
      expect(links.asked, hasLength(1));

      await keepUp(now.add(const Duration(minutes: 2)),
          meetingMail: {hadco.id}, links: links);

      expect(links.asked, hasLength(1), reason: 'its link not asked');
      final rows = jsonDecode(surface.values[CalendarUpkeep.widgetKey]!
          as String) as List;
      expect([for (final r in rows) r['t']], contains('Holiday'));
    });
  });

  // A reminder for meetings that have none, and for all-day events (#68).
  group('reminders chosen for what has none', () {
    Future<void> choose(CalendarPrefs Function(CalendarPrefs p) change) =>
        ui.writeString(UiStateKeys.calendarPrefs,
            jsonEncode(change(const CalendarPrefs()).toJson()));

    CalendarEvent day(String id, String title, {String? accountId}) =>
        CalendarEvent(
          id: id,
          accountId: accountId ?? hadco.id,
          title: title,
          start: DateTime(2026, 10, 26),
          end: DateTime(2026, 10, 27),
          allDay: true,
          response: EventResponse.accepted,
        );

    test("a meeting with no reminder has the one chosen, on an account's "
        'reminded', () async {
      final gmail = await engine.addOAuthAccount(
        displayName: 'Gmail',
        emailAddress: 'ron@gmail.example',
        provider: MailProvider.gmail,
        token: token,
      );
      engine.events[hadco.id] = [
        meeting('h', DateTime(2026, 10, 26, 10), reminder: null),
      ];
      engine.events[gmail.id] = [
        meeting('g', DateTime(2026, 10, 26, 11),
            reminder: null, accountId: gmail.id),
      ];
      await run();
      expect(notifier.meetingReminders, isEmpty, reason: 'none, as before');

      await choose((p) => p.copyWith(reminderIfNone: 10));
      await run();
      final set = notifier.meetingReminders.values.single;
      expect(set.meeting.eventId, 'h',
          reason: "Gmail's reminders are Google's until switched on");
      expect(set.at, DateTime(2026, 10, 26, 9, 50));
      expect(set.canJoin, isTrue, reason: 'a reminder like any other');
    });

    test('all-day events: one reminder for the day, at the time chosen, '
        'taken back when none', () async {
      now = DateTime(2026, 10, 25, 17);
      engine.events[hadco.id] = [
        day('t', 'Thanksgiving'),
        day('b', "Ron's birthday"),
      ];
      await run();
      expect(notifier.dayReminders, isEmpty, reason: 'none, as before');

      await choose((p) => p.copyWith(allDayReminder: AllDayReminder.morning));
      await run();
      var set = notifier.dayReminders.values.single;
      expect(set.at, DateTime(2026, 10, 26, 8));
      expect(set.title, 'Today: Thanksgiving and 1 more');
      expect(notifier.meetingReminders, isEmpty);

      await choose((p) =>
          p.copyWith(allDayReminder: AllDayReminder.eveningBefore));
      await run();
      set = notifier.dayReminders.values.single;
      expect(set.at, DateTime(2026, 10, 25, 18));
      expect(set.title, 'Tomorrow: Thanksgiving and 1 more');

      await choose((p) => p);
      await run();
      expect(notifier.dayReminders, isEmpty, reason: 'taken back');
    });

    test('the morning agenda speaks up on a day of all-day events only',
        () async {
      engine.events[hadco.id] = [day('t', 'Thanksgiving')];
      await run();
      final agenda = notifier.agendas.values.single;
      expect(agenda.at, DateTime(2026, 10, 26, 7, 30));
      expect(agenda.title, 'No meetings today');
      expect(agenda.body, 'All day: Thanksgiving');
    });
  });

  // Quiet while you are in a meeting (#70): the background goes by the
  // meetings the device kept, and asks no server.
  group('in a meeting, from what the device kept', () {
    final at = DateTime(2026, 10, 26, 10, 10);

    setUp(() async {
      engine.calendarLists[hadco.id] = [
        CalendarInfo.main(hadco.id),
        CalendarInfo(accountId: hadco.id, id: 'BBB', name: 'Projects'),
      ];
      engine.events[hadco.id] = [
        // Ron's own, on a calendar beside his main one: he accepted it.
        CalendarEvent(
          id: 'p',
          accountId: hadco.id,
          calendarId: 'BBB',
          title: 'Projects review',
          start: DateTime(2026, 10, 26, 10),
          end: DateTime(2026, 10, 26, 11),
          organizer: const MailAddress(email: 'dana@example.com'),
          attendees: const [
            EventAttendee(MailAddress(email: 'ron@hadco.example'),
                response: EventResponse.accepted),
          ],
        ),
      ];
      // Read once, as the quarter hour's read does, and kept.
      await engine.calendarEvents(
          hadco.id, DateTime(2026, 10, 26), DateTime(2026, 10, 27));
      engine.read.clear();
    });

    test('a meeting under way on a calendar shown, and no server asked',
        () async {
      expect(await inMeetingFromKept(engine, ui, at), isTrue);
      expect(await inMeetingFromKept(engine, ui, DateTime(2026, 10, 26, 11)),
          isFalse);
      expect(engine.read, isEmpty);
    });

    test("not someone else's meeting on a calendar the account follows",
        () async {
      engine.calendarLists[hadco.id] = [
        CalendarInfo.main(hadco.id),
        CalendarInfo(accountId: hadco.id, id: 'FAM', name: 'Family'),
      ];
      // As the family calendar's own copy says it: made by its owner.
      engine.events[hadco.id] = [
        CalendarEvent(
          id: 'f',
          accountId: hadco.id,
          calendarId: 'FAM',
          title: 'Parents evening',
          start: DateTime(2026, 10, 26, 10),
          end: DateTime(2026, 10, 26, 11),
          isOrganizer: true,
          response: EventResponse.organizer,
          organizer: const MailAddress(email: 'family@group.example'),
        ),
      ];
      await engine.calendarEvents(
          hadco.id, DateTime(2026, 10, 26), DateTime(2026, 10, 27));

      expect(await inMeetingFromKept(engine, ui, at), isFalse);
    });

    test('not on a calendar switched off, nor an account hidden', () async {
      await ui.writeIds(UiStateKeys.hiddenCalendars, {'${hadco.id}|BBB'});
      expect(await inMeetingFromKept(engine, ui, at), isFalse);
      await ui.writeIds(UiStateKeys.hiddenCalendars, {hadco.id});
      expect(await inMeetingFromKept(engine, ui, at), isFalse);
    });

    test('nothing kept is no meeting', () async {
      final gmail = await engine.addOAuthAccount(
        displayName: 'Gmail',
        emailAddress: 'ron@gmail.example',
        provider: MailProvider.gmail,
        token: token,
      );
      engine.events[gmail.id] = [
        meeting('g', DateTime(2026, 10, 26, 10), accountId: gmail.id),
      ];
      await ui.writeIds(UiStateKeys.hiddenCalendars, {hadco.id});
      expect(await inMeetingFromKept(engine, ui, at), isFalse,
          reason: "Gmail's calendar was never read here");
      expect(engine.read, isEmpty);
    });
  });

  test('a calendar switched off has no reminders, and is not on the widget',
      () async {
    now = DateTime(2026, 10, 26, 9);
    engine.calendarLists[hadco.id] = [
      CalendarInfo.main(hadco.id),
      CalendarInfo(accountId: hadco.id, id: 'BBB', name: 'Projects'),
    ];
    engine.events[hadco.id] = [
      meeting('a', DateTime(2026, 10, 26, 11), title: 'Main'),
      CalendarEvent(
        id: 'b',
        accountId: hadco.id,
        calendarId: 'BBB',
        title: 'Projects',
        start: DateTime(2026, 10, 26, 12),
        end: DateTime(2026, 10, 26, 13),
        reminderMinutes: 15,
      ),
    ];
    await ui.writeIds(UiStateKeys.hiddenCalendars, {'${hadco.id}|BBB'});
    await run();
    expect([for (final r in notifier.meetingReminders.values) r.meeting.title],
        ['Main']);
    final rows =
        jsonDecode(surface.values[CalendarUpkeep.widgetKey]! as String) as List;
    expect([for (final r in rows) r['t']], ['Main']);
  });

  test('a calendar from a link is on the widget, in its colour', () async {
    now = DateTime(2026, 10, 26, 9);
    engine.events[hadco.id] = const [];
    const link = InternetCalendar(
      id: 'il',
      name: 'Holidays in Israel',
      url: 'https://example.com/il.ics',
      colour: 0xFF0B8043,
    );
    await ui.writeString(
        UiStateKeys.internetCalendars, InternetCalendar.listToText([link]));
    final links = MemoryInternetCalendars({
      link.url: 'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:h\r\n'
          'SUMMARY:Holiday\r\nDTSTART;VALUE=DATE:20261027\r\n'
          'DTEND;VALUE=DATE:20261028\r\nEND:VEVENT\r\nEND:VCALENDAR',
    });
    await CalendarUpkeep(
      engine: engine,
      notifier: notifier,
      uiState: ui,
      surface: surface,
      links: links,
      clock: () => now,
    ).run();
    final rows =
        jsonDecode(surface.values[CalendarUpkeep.widgetKey]! as String) as List;
    final holiday = rows.single as Map;
    expect(holiday['t'], 'Holiday');
    expect(holiday['a'], isTrue);
    expect(holiday['c'], 0xFF0B8043.toSigned(32));
    expect(links.asked, [link.url], reason: 'read, never having been');
  });
}

/// Calendars read over the network, which takes time: [onRead] moves a
/// test's clock on as each is read.
class _ReadingEngine extends SampleMailEngine {
  void Function()? onRead;

  /// Each account whose calendar was read, in order.
  final List<String> read = [];

  @override
  Future<List<CalendarEvent>> calendarEvents(
    String accountId,
    DateTime start,
    DateTime end,
  ) {
    onRead?.call();
    read.add(accountId);
    return super.calendarEvents(accountId, start, end);
  }
}

/// Android's side, as the notifications plugin has it: a time that has
/// passed is refused by throwing, and so is the reminder of a meeting in
/// [refused].
class _AndroidNotifier extends FakeMailNotifier {
  _AndroidNotifier(this.clock);

  final DateTime Function() clock;

  /// The meetings whose reminders Android will not take, by event id.
  final Set<String> refused = {};

  void _inTheFuture(DateTime at) {
    if (at.isBefore(clock())) {
      throw ArgumentError.value(
          at, 'scheduledDate', 'Must be a date in the future');
    }
  }

  @override
  Future<bool> scheduleMeetingReminder(MeetingReminder reminder) {
    if (refused.contains(reminder.meeting.eventId)) {
      throw PlatformException(code: 'refused');
    }
    _inTheFuture(reminder.at);
    return super.scheduleMeetingReminder(reminder);
  }

  @override
  Future<bool> scheduleAgenda({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required List<String> lines,
    required String payload,
  }) {
    _inTheFuture(at);
    return super.scheduleAgenda(
      id: id,
      at: at,
      title: title,
      body: body,
      lines: lines,
      payload: payload,
    );
  }
}
