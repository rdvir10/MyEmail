/// The date column of a message list, Outlook style: the time for today, day
/// and month within the current year, the full date otherwise.
///
/// Hand-rolled rather than pulling in intl for three formats; revisit if the
/// app ever localises.
String formatMessageDate(DateTime date, {DateTime? now}) {
  final n = (now ?? DateTime.now()).toLocal();
  final d = date.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');

  if (d.year == n.year && d.month == n.month && d.day == n.day) {
    return '${two(d.hour)}:${two(d.minute)}';
  }
  if (d.year == n.year) {
    return '${d.day} ${_months[d.month - 1]}';
  }
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

/// The reading pane's fuller form, e.g. "Mon 14 Sep 2026, 09:41".
String formatMessageDateLong(DateTime date) {
  final d = date.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} '
      '${d.year}, ${two(d.hour)}:${two(d.minute)}';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
