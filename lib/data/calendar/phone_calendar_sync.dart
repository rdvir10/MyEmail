import 'package:flutter/foundation.dart' show debugPrint;

import '../../domain/account.dart';
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
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MailEngine engine;
  final PhoneCalendar phone;
  final DateTime Function() _clock;

  static const back = Duration(days: 30);
  static const ahead = Duration(days: 365);

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
    for (final a in shown) {
      try {
        final events = await engine.calendarEvents(a.id, from, to);
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
        debugPrint('[myemail] phone calendar for ${a.emailAddress}: $result');
      } catch (e) {
        problems[a.id] = e;
      }
    }
    return problems;
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
    final last = DateTime.tryParse(
      uiState.readString(UiStateKeys.phoneCalendarsSynced) ?? '',
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
