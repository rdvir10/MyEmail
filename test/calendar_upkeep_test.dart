import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart' show SignInNeedsConsent;
import 'package:myemail/data/calendar/calendar_upkeep.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_prefs.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;
import 'package:myemail/data/auth/oauth_token.dart';

/// The meeting reminders (#31), the morning agenda (#33) and the calendar
/// widget's meetings (#11), kept up to date from the calendars.
void main() {
  late SampleMailEngine engine;
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
    engine = SampleMailEngine();
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
}
