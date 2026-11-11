import 'package:flutter/foundation.dart' show immutable;

/// What Microsoft says about a work account's password: when it was last
/// changed, and whether it is set never to expire. How long a password
/// lasts is the organisation's rule, and reading that needs its
/// administrator, so it is typed in instead; see [PasswordExpiry].
@immutable
class PasswordAge {
  const PasswordAge({this.lastChanged, this.neverExpires = false});

  /// Nothing known: an account that is not Microsoft's, a shared mailbox,
  /// or a personal Microsoft account, whose profile does not say.
  static const unknown = PasswordAge();

  /// When the password was last changed, or first set.
  final DateTime? lastChanged;

  /// The account's own `DisablePasswordExpiration`.
  final bool neverExpires;

  @override
  bool operator ==(Object other) =>
      other is PasswordAge &&
      other.lastChanged == lastChanged &&
      other.neverExpires == neverExpires;

  @override
  int get hashCode => Object.hash(lastChanged, neverExpires);
}

/// When an account's password runs out, by its [PasswordAge] and how many
/// days the organisation lets a password last.
@immutable
class PasswordExpiry {
  const PasswordExpiry({required this.lastChanged, required this.expires});

  /// Hadco's rule, and Microsoft's own default for an organisation that set
  /// one before 2021. A different number, or 0 for never, per account.
  static const defaultDays = 90;

  /// How long before the day the folder list starts saying so, and the
  /// days before it the phone reminds.
  static const warnDays = 14;
  static const reminderDays = [14, 3];

  /// The hour a reminder comes, on its day.
  static const reminderHour = 9;

  final DateTime lastChanged;
  final DateTime expires;

  /// Null where nothing can be said: no date, never expires, or [days] 0.
  static PasswordExpiry? of(PasswordAge age, int days) {
    final changed = age.lastChanged;
    if (changed == null || age.neverExpires || days <= 0) return null;
    // Calendar days in the phone's time, not 24-hour ones: across a change
    // of the clocks those land an hour off.
    final l = changed.toLocal();
    return PasswordExpiry(
      lastChanged: changed,
      expires: DateTime(l.year, l.month, l.day + days, l.hour, l.minute),
    );
  }

  /// Whole days from [now]'s day to the day it expires: 0 on the day,
  /// negative once it has gone by.
  int daysLeft(DateTime now) {
    final e = expires.toLocal();
    final n = now.toLocal();
    return DateTime.utc(e.year, e.month, e.day)
        .difference(DateTime.utc(n.year, n.month, n.day))
        .inDays;
  }

  /// Whether the folder list should say so by [now].
  bool isNear(DateTime now) => daysLeft(now) <= warnDays;

  /// "in 9 days", "tomorrow", "today", "2 days ago".
  String when(DateTime now) => switch (daysLeft(now)) {
        0 => 'today',
        1 => 'tomorrow',
        -1 => 'yesterday',
        final d when d < 0 => '${-d} days ago',
        final d => 'in $d days',
      };

  /// The line under the account in the folder list.
  String warning(DateTime now) => daysLeft(now) < 0
      ? 'Password expired ${when(now)}'
      : 'Password expires ${when(now)}';

  /// The reminders still to come after [now]: [days] before, at
  /// [reminderHour] that morning, each with what it says.
  List<({int daysBefore, DateTime at})> reminders(DateTime now) {
    final e = expires.toLocal();
    return [
      for (final d in reminderDays)
        if (DateTime(e.year, e.month, e.day - d, reminderHour)
            case final at when at.isAfter(now))
          (daysBefore: d, at: at),
    ];
  }

  /// The id a reminder [daysBefore] the day is set under for [accountId]:
  /// the same every time, so setting it again replaces it. FNV-1a, not
  /// `hashCode`, which Dart does not promise to keep between runs.
  static int reminderId(String accountId, int daysBefore) {
    var h = 0x811c9dc5;
    for (final c in 'password:$accountId:$daysBefore'.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h & 0x7fffffff;
  }
}

const _password = 'myemail-password:';

/// A notification's payload that opens [accountId]'s settings.
String passwordPayload(String accountId) => '$_password$accountId';

/// The account in a [passwordPayload]; null for anything else.
String? passwordAccountOf(String? payload) =>
    payload != null && payload.startsWith(_password)
        ? payload.substring(_password.length)
        : null;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Thu 24 Dec 2026", in the phone's own time.
String passwordDay(DateTime t) {
  final d = t.toLocal();
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} '
      '${d.year}';
}
