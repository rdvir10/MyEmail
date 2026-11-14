import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, setEquals;

import '../../domain/account.dart';
import '../../domain/calendar_event.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../mail_engine.dart';
import '../ui_state_store.dart';
import 'phone_calendar.dart';

/// Microsoft accounts' calendars in the phone's own calendar, as Outlook for
/// Android's Sync calendars puts them there: Settings, Calendar. One way,
/// from Outlook to the phone, a year ahead and a month back, read only in
/// the calendar app.
class PhoneCalendarSync {
  PhoneCalendarSync({
    required this.engine,
    required this.phone,
    required this.uiState,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MailEngine engine;
  final PhoneCalendar phone;

  /// Where what each pass gave the phone is kept, for the next: see
  /// [_eventsOf].
  final UiStateStore uiState;
  final DateTime Function() _clock;

  static const back = Duration(days: 30);
  static const ahead = Duration(days: 365);

  /// How far ahead of today each pass reads the calendar again. The rest
  /// of the months the phone is given, behind and beyond, is read again
  /// once [restEvery] has passed, and given from what the device kept of
  /// it in between: thirteen months every quarter hour was seconds of
  /// radio and of rewriting the app's own copy, for almost no change.
  static const soon = Duration(days: 28);
  static const restEvery = Duration(hours: 6);

  /// Whether [account]'s calendar can go into the phone's: one signed in
  /// with Microsoft itself. A Google account's is there already, through
  /// Google's own calendar sync on the phone.
  static bool canShow(Account account) =>
      account.provider == MailProvider.outlook &&
      account.authMethod == AuthMethod.oauth &&
      !account.isShared;

  /// The accounts in [on] into the phone's calendar, and the calendars of
  /// any others taken out (switched off, or removed). Answers what went
  /// wrong, by account; never throws for one account's trouble.
  Future<Map<String, Object>> run(List<Account> accounts, Set<String> on) async {
    final shown = [
      for (final a in accounts)
        if (on.contains(a.id) && canShow(a)) a,
    ];
    if (!await phone.hasPermission()) {
      return {for (final a in shown) a.id: const PhoneCalendarNotAllowed()};
    }
    final keep = {for (final a in shown) a.id};
    for (final row in await phone.calendars()) {
      if (!keep.contains(row.key)) await phone.remove(row.key);
    }
    final now = _clock();
    final from = DateTime(now.year, now.month, now.day).subtract(back);
    final to = from.add(back + ahead);
    final problems = <String, Object>{};
    final given = await _given();
    // One that fails below keeps what it was given before; one switched
    // off, its calendar taken out above, is left out.
    final gave = {
      for (final a in shown) a.id: ?given[a.id],
    };
    for (final a in shown) {
      try {
        final events =
            await _eventsOf(a.id, from, to, now, given: given[a.id]);
        final id = await phone.ensureCalendar(
          key: a.id,
          account: a.emailAddress,
          name: a.displayName,
          color: a.colorValue,
        );
        final result = await phone.sync(
          calendarId: id,
          account: a.emailAddress,
          from: from,
          events: events,
        );
        gave[a.id] = {
          for (final e in events)
            if (goesToPhone(e)) digestOf(e.id),
        };
        debugPrint('[myemail] phone calendar for ${a.emailAddress}: $result');
      } catch (e) {
        problems[a.id] = e;
      }
    }
    await _keepGiven(given, gave);
    return problems;
  }

  /// [accountId]'s events from [from] to [to], every one of them, since
  /// the phone's calendar takes out what a pass does not give it: the
  /// next [soon] read from the server, and the rest as kept, where all of
  /// it was read in the last [restEvery]. Otherwise all of it is read: the
  /// first time, and wherever one the phone was [given] last time (the
  /// digests of their ids) would be missing, moved or gone where the
  /// server was not asked. What the device kept is no guide to that: the
  /// reminders and the calendar screen read days of their own and rewrite
  /// it, and one moved out of those days leaves no trace in it.
  Future<List<CalendarEvent>> _eventsOf(
    String accountId,
    DateTime from,
    DateTime to,
    DateTime now, {
    required Set<String>? given,
  }) async {
    if (given == null) return engine.calendarEvents(accountId, from, to);
    final today = DateTime(now.year, now.month, now.day);
    final split = DateTime(today.year, today.month, today.day + soon.inDays);
    bool fresh(KeptCalendar kept) => switch (kept.readAt) {
          final at? => !now.isBefore(at) && now.difference(at) < restEvery,
          null => false,
        };
    final behind = await engine.keptCalendarEvents(accountId, from, today);
    final beyond = await engine.keptCalendarEvents(accountId, split, to);
    if (!fresh(behind) || !fresh(beyond)) {
      return engine.calendarEvents(accountId, from, to);
    }
    final near = await engine.calendarEvents(accountId, today, split);
    final ids = {for (final e in near) e.id};
    final events = [
      ...near,
      // One across a boundary is in both: the read wins.
      for (final e in [...behind.events, ...beyond.events])
        if (ids.add(e.id)) e,
    ];
    final here = {for (final id in ids) digestOf(id)};
    if (!here.containsAll(given)) {
      return engine.calendarEvents(accountId, from, to);
    }
    return events;
  }

  /// What the last pass gave the phone, by account: the digests of the
  /// events' ids. As the device has it, since the background's passes and
  /// the app's each write it.
  Future<Map<String, Set<String>>> _given() async {
    try {
      final json = jsonDecode(
        await uiState.readFresh(UiStateKeys.phoneCalendarsGiven) ?? '{}',
      );
      return {
        if (json is Map)
          for (final MapEntry(:key, :value) in json.entries)
            if (key is String && value is List)
              key: {for (final d in value) '$d'},
      };
    } on FormatException {
      return {};
    }
  }

  /// [gave] kept for the next pass, where it is not what was [given].
  Future<void> _keepGiven(
    Map<String, Set<String>> given,
    Map<String, Set<String>> gave,
  ) async {
    final same = given.length == gave.length &&
        gave.entries.every((e) => setEquals(given[e.key], e.value));
    if (same) return;
    await uiState.writeString(
      UiStateKeys.phoneCalendarsGiven,
      jsonEncode({
        for (final MapEntry(:key, :value) in gave.entries)
          key: value.toList()..sort(),
      }),
    );
  }
}

/// The phone's calendar cannot be written: its permission was refused, or
/// taken back in Android's settings.
class PhoneCalendarNotAllowed implements Exception, ReadableError {
  const PhoneCalendarNotAllowed();

  @override
  String get message =>
      "MyEmail is not allowed into the phone's calendar. Allow it in "
      "Android's settings for MyEmail, under Permissions, Calendar.";

  @override
  String toString() => message;
}

/// The phone's calendar brought up to date, where some account is shown
/// there and [every] has passed since it last was: called from the
/// background passes and as the app comes to the front. Never throws.
Future<void> syncPhoneCalendarsIfDue(
  MailEngine engine,
  UiStateStore uiState, {
  PhoneCalendar phone = const AndroidPhoneCalendar(),
  Duration every = const Duration(minutes: 30),
  DateTime Function() clock = DateTime.now,
}) async {
  try {
    final on = uiState.readIds(UiStateKeys.phoneCalendars);
    if (on.isEmpty) return;
    final now = clock();
    // As the device has it: the worker's copy of the settings and the
    // app's are each their own, and both bring the phone's calendar up to
    // date.
    final last = DateTime.tryParse(
      await uiState.readFresh(UiStateKeys.phoneCalendarsSynced) ?? '',
    );
    if (last != null && now.difference(last) < every && !now.isBefore(last)) {
      return;
    }
    await uiState.writeString(
      UiStateKeys.phoneCalendarsSynced,
      now.toIso8601String(),
    );
    final problems = await PhoneCalendarSync(
      engine: engine,
      phone: phone,
      uiState: uiState,
      clock: clock,
    ).run(await engine.loadAccounts(), on);
    for (final MapEntry(:key, :value) in problems.entries) {
      debugPrint('[myemail] phone calendar for $key not brought up to date: '
          '$value');
    }
  } catch (e) {
    debugPrint('[myemail] phone calendar not brought up to date: $e');
  }
}
