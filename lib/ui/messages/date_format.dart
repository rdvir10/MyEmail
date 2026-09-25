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

/// The bar that separates one day from the next in a list.
///
/// "Today", "Yesterday", then the weekday and date. The two words carry
/// more than a date does: most of what anyone is looking for is in them,
/// and a row of numbers makes that a thing to work out rather than read.
String formatDateBar(DateTime date, {DateTime? now}) {
  final n = (now ?? DateTime.now()).toLocal();
  final d = date.toLocal();
  // Calendar days, counted in UTC where every day is 24 hours. Between
  // local midnights the night the clocks go forward is 23, which made
  // yesterday a second "Today" the day after.
  final today = DateTime.utc(n.year, n.month, n.day);
  final day = DateTime.utc(d.year, d.month, d.day);
  final difference = today.difference(day).inDays;
  final written = '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}'
      '${d.year == n.year ? '' : ' ${d.year}'}';
  if (difference == 0) return 'Today \u00b7 $written';
  if (difference == 1) return 'Yesterday \u00b7 $written';
  return written;
}

/// Whether two moments fall on different days, in the reader's own zone.
bool startsNewDay(DateTime a, DateTime b) {
  final x = a.toLocal();
  final y = b.toLocal();
  return x.year != y.year || x.month != y.month || x.day != y.day;
}

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
