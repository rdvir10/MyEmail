import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/account.dart';
import '../../domain/account_calendars.dart';
import '../../domain/calendar_event.dart';
import '../../domain/calendar_prefs.dart';
import '../../domain/internet_calendar.dart';
import '../../domain/meeting_alerts.dart';
import '../../domain/meeting_links.dart' show placeNamed;
import '../mail_engine.dart';
import '../notifications/mail_notifier.dart';
import '../ui_state_store.dart';
import '../widget/home_screen_surface.dart';
import 'account_calendar.dart';
import 'internet_calendars.dart';

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
    this.links = const NoInternetCalendars(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MailEngine engine;
  final MailNotifier notifier;
  final UiStateStore uiState;
  final HomeScreenSurface surface;

  /// The calendars from links, for the widget and the agenda.
  final InternetCalendars links;
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

  /// [reading] narrows what is read from the calendars to those accounts,
  /// whose meeting mail has just arrived (calendar idea #74): every other
  /// account is as the device kept it, and each calendar from a link as it
  /// was last read, with nothing asked of their servers. Where none of
  /// [reading] has a calendar here, nothing is done. Null reads them all,
  /// as each quarter of an hour does.
  Future<void> run({Set<String>? reading}) async {
    final now = _clock();
    final accounts = [
      for (final a in await engine.loadAccounts())
        if (AccountCalendar.canRead(a)) a,
    ];
    if (reading != null && !accounts.any((a) => reading.contains(a.id))) {
      return;
    }
    final today = DateTime(now.year, now.month, now.day);
    final end = DateTime(today.year, today.month, today.day + days);
    final byAccount = <String, List<CalendarEvent>>{
      for (final a in accounts)
        a.id: reading == null || reading.contains(a.id)
            ? await _read(a.id, today, end)
            : await _keptOf(a.id, today, end),
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

    final reminded = [
      for (final a in accounts)
        if (prefs.remindsFor(a, inPhoneCalendar: inPhone.contains(a.id)))
          for (final e in byAccount[a.id]!)
            if (calendarShown(e, hidden)) e,
    ];
    await _remind(
      meetingRemindersFor(
        reminded,
        now: now,
        use24h: use24h,
        ownEmails: {for (final a in accounts) a.id: a.emailAddress},
        colours: {for (final a in accounts) a.id: a.colorValue},
        ifNone: prefs.reminderIfNone,
      ),
      // The all-day events' too, once a day, on the accounts reminded for
      // (calendar idea #68); none where none is chosen, as before.
      days: prefs.allDayReminder == AllDayReminder.none
          ? const []
          : allDayRemindersFor(
              reminded,
              now: now,
              minutes: prefs.allDayReminderMinutes,
              eveningBefore:
                  prefs.allDayReminder == AllDayReminder.eveningBefore,
            ),
    );

    final fromLinks = <CalendarEvent>[];
    final calendars = <String, CalendarInfo>{
      for (final a in accounts)
        for (final c in await _keptCalendarsOf(a.id)) c.key: c,
    };
    for (final c in InternetCalendar.listFrom(
      uiState.readString(UiStateKeys.internetCalendars),
    )) {
      if (hidden.contains(c.accountId)) continue;
      calendars[calendarKey(c.accountId, CalendarEvent.mainCalendar)] =
          CalendarInfo(
        accountId: c.accountId,
        id: CalendarEvent.mainCalendar,
        name: c.name,
        colour: c.colour,
        canEdit: false,
      );
      fromLinks.addAll(
          await _fromLink(c, today, end, now, readDue: reading == null));
    }
    final shown = [
      for (final a in accounts)
        if (!hidden.contains(a.id))
          for (final e in byAccount[a.id]!)
            if (calendarShown(e, hidden)) e,
      ...fromLinks,
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
      calendars,
    );
  }

  Future<List<CalendarInfo>> _keptCalendarsOf(String accountId) async {
    try {
      return await engine.keptCalendarsOf(accountId);
    } catch (_) {
      return const [];
    }
  }

  /// [calendar]'s events from [start] to [end], read from its link again
  /// where what was kept is older than [InternetCalendars.readEvery],
  /// unless not [readDue].
  Future<List<CalendarEvent>> _fromLink(
    InternetCalendar calendar,
    DateTime start,
    DateTime end,
    DateTime now, {
    bool readDue = true,
  }) async {
    var kept = await links.kept(calendar);
    if (readDue &&
        (kept == null ||
            now.difference(kept.readAt) >= InternetCalendars.readEvery)) {
      try {
        kept = (feed: await links.read(calendar), readAt: now);
      } catch (e) {
        debugPrint('[myemail] ${calendar.name} not read: $e');
      }
    }
    return kept?.feed.between(start, end, accountId: calendar.accountId) ??
        const [];
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

  /// What the device kept of [accountId]'s calendars from [start] to
  /// [end], the latest of what was read, asking nothing of its server.
  /// Where even that cannot be had, read after all: taken for nothing on,
  /// its reminders would be taken back.
  Future<List<CalendarEvent>> _keptOf(
    String accountId,
    DateTime start,
    DateTime end,
  ) async {
    try {
      return (await engine.keptCalendarEvents(accountId, start, end)).events;
    } catch (e) {
      debugPrint('[myemail] kept calendar of $accountId not read: $e');
      return _read(accountId, start, end);
    }
  }

  /// Each of [wanted] set for its time, and each set before and wanted no
  /// longer (declined, moved, taken off, its account switched off) taken
  /// back while it is still to come. One whose time has come goes off
  /// now, once: [UiStateKeys.meetingReminders] keeps what was set, by id,
  /// with its time, for [remembered] after. One Android will not take is
  /// tried again next time, and the rest go on.
  ///
  /// [days], the all-day events' reminders, the same way, kept with them.
  Future<void> _remind(
    List<MeetingReminder> wanted, {
    List<DayReminder> days = const [],
  }) async {
    // Now, not as the run began: the calendars were read since, which
    // takes seconds, and "now" by the run's clock had passed.
    final now = _clock();
    final set = await _readSet();
    final keep = <int, DateTime>{};
    final all = <_Wanted>[
      for (final r in wanted)
        (
          id: r.id,
          at: r.at,
          set: (DateTime at) => notifier.scheduleMeetingReminder(at == r.at
              ? r
              : MeetingReminder(id: r.id, at: at, meeting: r.meeting)),
        ),
      for (final d in days)
        (
          id: d.id,
          at: d.at,
          set: (DateTime at) =>
              notifier.scheduleDayReminder(at == d.at ? d : d.movedTo(at)),
        ),
    ];
    final ids = {for (final r in all) r.id};
    for (final MapEntry(key: id, value: at) in set.entries) {
      if (ids.contains(id)) continue;
      if (at.isAfter(now)) {
        await notifier.cancelReminder(id);
      } else if (now.difference(at) < remembered) {
        keep[id] = at;
      }
    }
    for (final r in all) {
      final was = set[r.id];
      try {
        if (r.at.isAfter(now)) {
          // Set again each time: its title or its place may have changed.
          await r.set(r.at);
        } else if (was == null || was.isAfter(now)) {
          // Its time came with nothing set for it: a meeting made, or its
          // reminder lengthened, inside the reminder's own time.
          await r.set(now.add(const Duration(seconds: 2)));
        } else {
          // Gone off already, or snoozed: left as it is.
          keep[r.id] = was;
          continue;
        }
      } catch (e) {
        // Kept as it was, so it is tried again: the other reminders, the
        // agenda and the widget are not held up by it.
        debugPrint('[myemail] reminder ${r.id} not set: $e');
        if (was != null) keep[r.id] = was;
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

  /// What was set, as the device has it now. The worker sets reminders
  /// too, through its own copy of the settings, and the app's copy did not
  /// have them: one the worker set, gone off, the app set again for now.
  Future<Map<int, DateTime>> _readSet() async {
    try {
      final json = jsonDecode(
          await uiState.readFresh(UiStateKeys.meetingReminders) ?? '{}');
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
    final was = await _readAgenda();
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

  /// As the device has it now, as [_readSet] for the same reason.
  Future<({int id, DateTime at})?> _readAgenda() async {
    try {
      final json =
          jsonDecode(await uiState.readFresh(UiStateKeys.agendaSet) ?? '');
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
    Map<String, CalendarInfo> calendars,
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
            'c': eventColour(
              e,
              accounts[e.accountId]?.colorValue ?? 0xFFFF7A18,
              calendars: calendars,
            ).toSigned(32),
            // On the home screen for anyone to read: a link in the place
            // is named ("Zoom"), not written out with its passcode.
            if (placeNamed(e.location) case final where
                when where.isNotEmpty)
              'w': where,
            'j': ?e.joinUrl,
            'l': calendarWidgetLink(e),
          },
      ]),
    );
    await surface.redrawCalendar();
  }
}

/// A reminder for [CalendarUpkeep._remind] to set: a meeting's, or a day's
/// all-day events', and how to set it at a time.
typedef _Wanted = ({
  int id,
  DateTime at,
  Future<bool> Function(DateTime at) set,
});

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

/// Whether you are in a meeting at [now] ([inMeetingAt]) on any calendar
/// shown, for the background pass to post new mail silently in one (calendar
/// idea #70): one of the account's own, by its own address where it is on
/// a calendar the account follows. From what the device kept of each
/// calendar, which the quarter hour's read and the calendar's own keep
/// fresh: no server is asked. Never throws; false where nothing can be
/// told.
Future<bool> inMeetingFromKept(
  MailEngine engine,
  UiStateStore uiState,
  DateTime now,
) async {
  try {
    final hidden = uiState.readIds(UiStateKeys.hiddenCalendars);
    final until = now.add(const Duration(minutes: 1));
    for (final a in await engine.loadAccounts()) {
      if (!AccountCalendar.canRead(a) || hidden.contains(a.id)) continue;
      final kept = await engine.keptCalendarEvents(a.id, now, until);
      final shown = [
        for (final e in kept.events)
          if (calendarShown(e, hidden)) e,
      ];
      if (inMeetingAt(shown, now, ownEmails: {a.id: a.emailAddress})) {
        return true;
      }
    }
  } catch (e) {
    debugPrint('[myemail] could not tell whether a meeting is on: $e');
  }
  return false;
}

/// [CalendarUpkeep] where [every] has passed since it last ran, or at once
/// with [force]: from the background passes, and from the app as it comes
/// to the front, while it is there, and after it changes a calendar.
/// Never throws.
///
/// [meetingMail], the accounts whose meeting mail has just arrived, are
/// read again at once whatever the time, and only they (calendar idea
/// #74); the quarter hour is still counted from the last run that read
/// them all.
Future<void> keepCalendarUpIfDue(
  MailEngine engine,
  UiStateStore uiState,
  MailNotifier notifier,
  HomeScreenSurface surface, {
  InternetCalendars links = const NoInternetCalendars(),
  Duration every = const Duration(minutes: 15),
  bool force = false,
  Set<String> meetingMail = const {},
  DateTime Function() clock = DateTime.now,
}) async {
  try {
    final now = clock();
    final upkeep = CalendarUpkeep(
      engine: engine,
      notifier: notifier,
      uiState: uiState,
      surface: surface,
      links: links,
      clock: clock,
    );
    // As the device has it: a run in the worker counts as much as one here.
    final last = DateTime.tryParse(
        await uiState.readFresh(UiStateKeys.calendarKeptUp) ?? '');
    if (!force &&
        last != null &&
        now.difference(last) < every &&
        !now.isBefore(last)) {
      if (meetingMail.isNotEmpty) await upkeep.run(reading: meetingMail);
      return;
    }
    await uiState.writeString(
        UiStateKeys.calendarKeptUp, now.toIso8601String());
    await upkeep.run();
  } catch (e, stack) {
    debugPrint('[myemail] meeting reminders not brought up to date: $e');
    debugPrint('$stack');
  }
}
