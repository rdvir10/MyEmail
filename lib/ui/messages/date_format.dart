import 'package:flutter/foundation.dart' show immutable;

import '../../domain/mail_message.dart';
import '../../domain/message_sort.dart';

/// The date column of a message list, Outlook style: the time for today, day
/// and month within the current year, the full date otherwise.
///
/// Hand-rolled rather than pulling in intl for three formats; revisit if the
/// app ever localises.
///
/// The time is written the way the phone's clock is set: [use24h] comes
/// from `MediaQuery.alwaysUse24HourFormatOf`, which is Android's own
/// 24-hour switch. "20:14" on a phone that says "8:14 PM" everywhere else
/// was this app being the odd one out.
String formatMessageDate(DateTime date, {DateTime? now, bool use24h = true}) {
  final n = (now ?? DateTime.now()).toLocal();
  final d = date.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');

  if (d.year == n.year && d.month == n.month && d.day == n.day) {
    return formatClock(d, use24h: use24h);
  }
  if (d.year == n.year) {
    return '${d.day} ${_months[d.month - 1]}';
  }
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

/// Which bar a message sits under in a list sorted by date, the way
/// Outlook groups one: today and yesterday, each day earlier this week, then
/// last week, two and three weeks ago, earlier this month, last month, and
/// everything older.
///
/// The days keep their dates ("Today · Tue 29 Sep", "Sun 27 Sep"); past
/// this week a date is a thing to work out rather than read, and the span
/// says what is wanted: how long ago.
///
/// The week starts on Sunday, as Ron's Outlook starts it. [firstDayOfWeek]
/// (0 for Sunday, 1 for Monday) is there so the arithmetic can be tested
/// for other starts; the app has no localizations that could say the
/// phone's own.
@immutable
class DateGroup {
  const DateGroup._(this.key, this.label);

  /// Equal for two messages under the same bar.
  final String key;

  /// What the bar says.
  final String label;

  factory DateGroup.of(DateTime date, {DateTime? now, int firstDayOfWeek = 0}) {
    final n = (now ?? DateTime.now()).toLocal();
    final d = date.toLocal();
    // Calendar days, counted in UTC where every day is 24 hours. Between
    // local midnights the night the clocks go forward is 23, which made
    // yesterday a second "Today" the day after.
    final today = DateTime.utc(n.year, n.month, n.day);
    final day = DateTime.utc(d.year, d.month, d.day);
    final ago = today.difference(day).inDays;
    final written = '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}'
        '${d.year == n.year ? '' : ' ${d.year}'}';
    // A clock ahead on the sender's side is still today's mail, and the bar
    // says today's date: labelled by the first row under it, a message
    // stamped tomorrow told the whole Inbox that today was tomorrow.
    if (ago <= 0) {
      return DateGroup._('today', 'Today · ${formatDay(n, now: n)}');
    }
    if (ago == 1) return DateGroup._('yesterday', 'Yesterday · $written');

    final intoWeek = (today.weekday % 7 - firstDayOfWeek + 7) % 7;
    final thisWeek = today.subtract(Duration(days: intoWeek));
    if (!day.isBefore(thisWeek)) {
      return DateGroup._('day:${day.toIso8601String()}', written);
    }
    const spans = ['Last Week', 'Two Weeks Ago', 'Three Weeks Ago'];
    for (var i = 0; i < spans.length; i++) {
      if (!day.isBefore(thisWeek.subtract(Duration(days: 7 * (i + 1))))) {
        return DateGroup._('week:$i', spans[i]);
      }
    }
    if (day.year == today.year && day.month == today.month) {
      return const DateGroup._('thisMonth', 'Earlier this Month');
    }
    final lastMonth = DateTime.utc(today.year, today.month - 1);
    if (day.year == lastMonth.year && day.month == lastMonth.month) {
      return const DateGroup._('lastMonth', 'Last Month');
    }
    return const DateGroup._('older', 'Older');
  }

  @override
  bool operator ==(Object other) => other is DateGroup && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// Whether a row sits under one of the [closed] bars, as `visibleMessages`
/// asks it. Null when none can: nothing closed, or a list sorted by sender
/// or subject, which has no bars to close.
bool Function(MailMessage row)? foldedUnder(
  Set<String>? closed,
  MessageSort sort, {
  DateTime? now,
}) {
  if (closed == null || closed.isEmpty || !sort.byDate) return null;
  final n = now ?? DateTime.now();
  return (row) => closed.contains(DateGroup.of(row.date, now: n).key);
}

/// What the bar above [date]'s group says: see [DateGroup].
String formatDateBar(DateTime date, {DateTime? now, int firstDayOfWeek = 0}) =>
    DateGroup.of(date, now: now, firstDayOfWeek: firstDayOfWeek).label;

/// The reading pane's fuller form, e.g. "Mon 14 Sep 2026, 09:41", or
/// "Mon 14 Sep 2026, 9:41 AM" on a phone set to a 12-hour clock.
String formatMessageDateLong(DateTime date, {bool use24h = true}) {
  final d = date.toLocal();
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} '
      '${d.year}, ${formatClock(d, use24h: use24h)}';
}

/// A time of day as the phone's clock writes it: "20:14" or "8:14 PM".
String formatClock(DateTime time, {required bool use24h}) {
  final t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  if (use24h) return '${two(t.hour)}:${two(t.minute)}';
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$hour:${two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// A day as the list writes one, "Thu 1 Oct", with the year when it is
/// not this year's: for a date that is chosen rather than read.
String formatDay(DateTime date, {DateTime? now}) {
  final d = date.toLocal();
  final year = (now ?? DateTime.now()).year;
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}'
      '${d.year == year ? '' : ' ${d.year}'}';
}
