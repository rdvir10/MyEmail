import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/account.dart';
import '../../domain/calendar_event.dart';
import '../../domain/calendar_prefs.dart';
import '../../domain/meeting_alerts.dart';
import '../mail_engine.dart';
import '../notifications/mail_notifier.dart';
import '../ui_state_store.dart';
import '../widget/home_screen_surface.dart';
import 'account_calendar.dart';

/// What MyEmail says about the calendars away from the calendar, kept up
/// to date: each meeting's reminder, set with Android for its time; the
/// morning's agenda; and the meetings the home-screen widget lists. From
/// the background passes and from the app, every quarter of an hour at
/// most, and at once after the app changes a calendar or these settings.
///
/// Read from the calendars themselves, today to the end of the day after
/// tomorrow, and from what the device kept of one that cannot be reached
/// just now.
class CalendarUpkeep {
  CalendarUpkeep({
    required this.engine,
    required this.notifier,
    required this.uiState,
    required this.surface,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MailEngine engine;
  final MailNotifier notifier;
  final UiStateStore uiState;
  final HomeScreenSurface surface;
  final DateTime Function() _clock;

  /// How many days are read, from today: the night's reminders and
  /// tomorrow's agenda are there whatever the hour.
  static const days = 3;

  /// How long a reminder that has gone off is remembered, so it is not
  /// set again for its meeting.
  static const remembered = Duration(days: 2);

  /// Where the widget finds its meetings: see CalendarWidgetProvider.kt.
  static const widgetKey = 'calendar.widget.meetings';

  /// The agenda's notification id for [day]: a new one each day, so
  /// setting tomorrow's leaves this morning's alone.
  static int agendaIdFor(DateTime day) =>
      'agenda:${day.year}-${day.month}-${day.day}'.hashCode & 0x7fffffff;

  Future<void> run() async {
    final now = _clock();
    final accounts = [
      for (final a in await engine.loadAccounts())
        if (AccountCalendar.canRead(a)) a,
    ];
    final today = DateTime(now.year, now.month, now.day);
    final end = DateTime(today.year, today.month, today.day + days);
    final byAccount = <String, List<CalendarEvent>>{
      for (final a in accounts) a.id: await _read(a.id, today, end),
    };
    final prefs = CalendarPrefs.tryParse(
          uiState.readString(UiStateKeys.calendarPrefs) ?? '',
        ) ??
        const CalendarPrefs();
    final use24h = uiState.readString(UiStateKeys.clock24h) != 'false';
    final inPhone = uiState.readIds(UiStateKeys.phoneCalendars);
    final hidden = uiState.readIds(UiStateKeys.hiddenCalendars);
    final workWeek = {
      for (final d in uiState.readIds(UiStateKeys.workWeek)) ?int.tryParse(d),
    };

    await _remind(
      meetingRemindersFor(
        [
          for (final a in accounts)
            if (prefs.remindsFor(a, inPhoneCalendar: inPhone.contains(a.id)))
              ...byAccount[a.id]!,
        ],
        now: now,
        use24h: use24h,
        ownEmails: {for (final a in accounts) a.id: a.emailAddress},
      ),
      now,
    );

    final shown = [
      for (final a in accounts)
        if (!hidden.contains(a.id)) ...byAccount[a.id]!,
    ];
    final agendaAt = prefs.agendaAt;
    await _agenda(
      agendaAt == null
          ? null
          : morningAgendaFor(
              shown,
              now: now,
              minutes: agendaAt,
              workWeek: workWeek,
              use24h: use24h,
            ),
      now,
    );
    await _widget(
      widgetMeetings(shown, now, showDeclined: prefs.showDeclined),
      {for (final a in accounts) a.id: a},
    );
  }

  Future<List<CalendarEvent>> _read(
    String accountId,
    DateTime start,
    DateTime end,
  ) async {
    try {
      return await engine.calendarEvents(accountId, start, end);
    } catch (e) {
      debugPrint('[myemail] calendar of $accountId not read for its '
          'reminders: $e');
      try {
        return (await engine.keptCalendarEvents(accountId, start, end)).events;
      } catch (_) {
        return const [];
      }
    }
  }

  /// Each of [wanted] set for its time, and each set before and wanted no
  /// longer (declined, moved, taken off, its account switched off) taken
  /// back while it is still to come. One whose time has come goes off
  /// now, once: [UiStateKeys.meetingReminders] keeps what was set, by id,
  /// with its time, for [remembered] after.
  Future<void> _remind(List<MeetingReminder> wanted, DateTime now) async {
    final set = _readSet();
    final keep = <int, DateTime>{};
    final ids = {for (final r in wanted) r.id};
    for (final MapEntry(key: id, value: at) in set.entries) {
      if (ids.contains(id)) continue;
      if (at.isAfter(now)) {
        await notifier.cancelReminder(id);
      } else if (now.difference(at) < remembered) {
        keep[id] = at;
      }
    }
    for (final r in wanted) {
      final was = set[r.id];
      if (r.at.isAfter(now)) {
        // Set again each time: its title or its place may have changed.
        await notifier.scheduleMeetingReminder(r);
      } else if (was == null || was.isAfter(now)) {
        // Its time came with nothing set for it: a meeting made, or its
        // reminder lengthened, inside the reminder's own time.
        await notifier.scheduleMeetingReminder(MeetingReminder(
          id: r.id,
          at: now.add(const Duration(seconds: 2)),
          meeting: r.meeting,
        ));
      } else {
        // Gone off already, or snoozed: left as it is.
        keep[r.id] = was;
        continue;
      }
      keep[r.id] = r.at;
    }
    await uiState.writeString(
      UiStateKeys.meetingReminders,
      jsonEncode({
        for (final MapEntry(:key, :value) in keep.entries)
          '$key': value.millisecondsSinceEpoch,
      }),
    );
  }

  Map<int, DateTime> _readSet() {
    try {
      final json =
          jsonDecode(uiState.readString(UiStateKeys.meetingReminders) ?? '{}');
      if (json is! Map) return const {};
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (int.tryParse('$key') case final id? when value is int)
            id: DateTime.fromMillisecondsSinceEpoch(value),
      };
    } on FormatException {
      return const {};
    }
  }

  /// The morning's [agenda] set for its time, in place of one set for
  /// another morning and not gone off yet; with none, that one taken back.
  Future<void> _agenda(MorningAgenda? agenda, DateTime now) async {
    final was = _readAgenda();
    final id = agenda == null ? null : agendaIdFor(agenda.day);
    if (was != null && was.at.isAfter(now) && was.id != id) {
      await notifier.cancelReminder(was.id);
    }
    if (agenda == null || id == null) {
      if (was != null && was.at.isAfter(now)) {
        await uiState.writeString(UiStateKeys.agendaSet, null);
      }
      return;
    }
    await notifier.scheduleAgenda(
      id: id,
      at: agenda.at,
      title: agenda.title,
      body: agenda.body,
      lines: agenda.lines,
      payload: calendarDayPayload(agenda.day),
    );
    await uiState.writeString(
      UiStateKeys.agendaSet,
      jsonEncode({'id': id, 'at': agenda.at.millisecondsSinceEpoch}),
    );
  }

  ({int id, DateTime at})? _readAgenda() {
    try {
      final json = jsonDecode(uiState.readString(UiStateKeys.agendaSet) ?? '');
      if (json case {'id': final int id, 'at': final int at}) {
        return (id: id, at: DateTime.fromMillisecondsSinceEpoch(at));
      }
    } on FormatException {
      // Nothing set.
    }
    return null;
  }

  /// [meetings] written down for the home-screen widget, which draws them
  /// whether or not the app is running, and drops each as it ends.
  Future<void> _widget(
    List<CalendarEvent> meetings,
    Map<String, Account> accounts,
  ) async {
    await surface.putString(
      widgetKey,
      jsonEncode([
        for (final e in meetings.take(40))
          {
            't': e.title.trim().isEmpty ? '(No title)' : e.title.trim(),
            's': e.start.millisecondsSinceEpoch,
            'e': e.end.millisecondsSinceEpoch,
            if (e.allDay) 'a': true,
            if (e.declined) 'd': true,
            // Signed and inside 32 bits, as Android reads a colour.
            'c': (accounts[e.accountId]?.colorValue ?? 0xFFFF7A18).toSigned(32),
            if (e.location.trim().isNotEmpty) 'w': e.location.trim(),
            'j': ?e.joinUrl,
            'l': calendarWidgetLink(e),
          },
      ]),
    );
    await surface.redrawCalendar();
  }
}

/// What a tap on [event] in the widget opens: the meeting in MyEmail.
String calendarWidgetLink(CalendarEvent event) => Uri(
      scheme: 'myemail',
      host: 'event',
      queryParameters: {
        'account': event.accountId,
        'id': event.id,
        if (event.calendarId.isNotEmpty) 'calendar': event.calendarId,
        'start': '${event.start.millisecondsSinceEpoch}',
        'end': '${event.end.millisecondsSinceEpoch}',
      },
    ).toString();

/// [meeting] as the device kept it from its calendar, or null where it
/// kept nothing of it. Never throws.
Future<CalendarEvent?> findKeptMeeting(
  MailEngine engine,
  MeetingRef meeting,
) async {
  try {
    final from = DateTime(
        meeting.start.year, meeting.start.month, meeting.start.day);
    final dayAfter = DateTime(from.year, from.month, from.day + 1);
    final kept = await engine.keptCalendarEvents(
      meeting.accountId,
      from,
      meeting.end.isAfter(dayAfter) ? meeting.end : dayAfter,
    );
    return kept.events
        .where((e) =>
            e.id == meeting.eventId && e.calendarId == meeting.calendarId)
        .firstOrNull;
  } catch (e) {
    debugPrint('[myemail] kept meeting not found: $e');
    return null;
  }
}

/// [CalendarUpkeep] where [every] has passed since it last ran, or at once
/// with [force]: from the background passes, and from the app as it comes
/// to the front, while it is there, and after it changes a calendar.
/// Never throws.
Future<void> keepCalendarUpIfDue(
  MailEngine engine,
  UiStateStore uiState,
  MailNotifier notifier,
  HomeScreenSurface surface, {
  Duration every = const Duration(minutes: 15),
  bool force = false,
  DateTime Function() clock = DateTime.now,
}) async {
  try {
    final now = clock();
    final last =
        DateTime.tryParse(uiState.readString(UiStateKeys.calendarKeptUp) ?? '');
    if (!force &&
        last != null &&
        now.difference(last) < every &&
        !now.isBefore(last)) {
      return;
    }
    await uiState.writeString(
        UiStateKeys.calendarKeptUp, now.toIso8601String());
    await CalendarUpkeep(
      engine: engine,
      notifier: notifier,
      uiState: uiState,
      surface: surface,
      clock: clock,
    ).run();
  } catch (e, stack) {
    debugPrint('[myemail] meeting reminders not brought up to date: $e');
    debugPrint('$stack');
  }
}
