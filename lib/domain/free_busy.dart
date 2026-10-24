/// A stretch of time on a calendar: busy, in a calendar's answer, or free,
/// in what is worked out from it.
typedef TimeSpan = ({DateTime start, DateTime end});

/// The days a week is worked, until it is said otherwise: Monday to
/// Friday, as `DateTime.weekday` numbers them.
const defaultWorkWeek = {
  DateTime.monday,
  DateTime.tuesday,
  DateTime.wednesday,
  DateTime.thursday,
  DateTime.friday,
};

/// [busy] in order, each overlap or touch made one stretch.
List<TimeSpan> mergeBusy(Iterable<TimeSpan> busy) {
  final sorted = [
    for (final b in busy)
      if (b.end.isAfter(b.start)) b,
  ]..sort((a, b) => a.start.compareTo(b.start));
  final merged = <TimeSpan>[];
  for (final b in sorted) {
    if (merged.isNotEmpty && !b.start.isAfter(merged.last.end)) {
      final last = merged.removeLast();
      merged.add((
        start: last.start,
        end: b.end.isAfter(last.end) ? b.end : last.end,
      ));
    } else {
      merged.add(b);
    }
  }
  return merged;
}

/// The free stretches of [day], between [from] and [to] o'clock local time,
/// at least [shortest] long, around [busy]. Nothing before [notBefore],
/// where given: a stretch of today already gone is not free time.
List<TimeSpan> freeOn(
  DateTime day,
  List<TimeSpan> busy, {
  int from = 9,
  int to = 17,
  Duration shortest = const Duration(minutes: 30),
  DateTime? notBefore,
}) {
  final local = day.toLocal();
  var start = DateTime(local.year, local.month, local.day, from);
  final end = DateTime(local.year, local.month, local.day, to);
  if (notBefore != null && notBefore.isAfter(start)) {
    // From the next half hour: free from 10:17 reads as free from 10:30.
    final at = notBefore.toLocal();
    final rounded = DateTime(at.year, at.month, at.day, at.hour,
        at.minute == 0 ? 0 : (at.minute <= 30 ? 30 : 60));
    start = rounded;
  }
  final free = <TimeSpan>[];
  var cursor = start;
  for (final b in mergeBusy(busy)) {
    final bs = b.start.toLocal(), be = b.end.toLocal();
    if (!be.isAfter(cursor)) continue;
    if (!bs.isBefore(end)) break;
    if (bs.isAfter(cursor)) {
      _keep(free, cursor, bs.isBefore(end) ? bs : end, shortest);
    }
    if (be.isAfter(cursor)) cursor = be;
  }
  if (cursor.isBefore(end)) _keep(free, cursor, end, shortest);
  return free;
}

void _keep(List<TimeSpan> into, DateTime start, DateTime end, Duration shortest) {
  if (end.difference(start) >= shortest) into.add((start: start, end: end));
}

/// The first [length] that every one of [calendars] has free, from [after]
/// on, between [from] and [to] o'clock on a day of [workWeek], looking
/// [days] ahead. Null where there is none: Outlook's Next free time on the
/// Scheduling Assistant.
TimeSpan? nextFree(
  List<List<TimeSpan>> calendars, {
  required DateTime after,
  required Duration length,
  int from = 8,
  int to = 18,
  int days = 14,
  Set<int> workWeek = defaultWorkWeek,
}) {
  final everyone = mergeBusy([for (final c in calendars) ...c]);
  final first = after.toLocal();
  for (var d = 0; d < days; d++) {
    final day = DateTime(first.year, first.month, first.day + d);
    if (!workWeek.contains(day.weekday)) continue;
    for (final free in freeOn(
      day,
      everyone,
      from: from,
      to: to,
      shortest: length,
      notBefore: d == 0 ? first : null,
    )) {
      return (start: free.start, end: free.start.add(length));
    }
  }
  return null;
}

/// The free times written into a message, as Outlook's Share availability
/// writes them: a line to say what they are, then a day a line, each with
/// its stretches. [byDay] in day order; a day with none says so.
String freeTimesHtml(
  Map<DateTime, List<TimeSpan>> byDay, {
  required bool use24h,
  required String zone,
}) {
  final days = byDay.keys.toList()..sort();
  final buffer = StringBuffer(
    '<div>Times I am free ($zone):</div><ul>',
  );
  for (final day in days) {
    final free = byDay[day]!;
    final when = free.isEmpty
        ? 'no free time'
        : free
            .map((s) => '${_clock(s.start, use24h)}–${_clock(s.end, use24h)}')
            .join(', ');
    buffer.write('<li>${_day(day)}: $when</li>');
  }
  buffer.write('</ul>');
  return buffer.toString();
}

const _weekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December',
];

String _day(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

String _clock(DateTime t, bool use24h) {
  final local = t.toLocal();
  final minutes = local.minute.toString().padLeft(2, '0');
  if (use24h) return '${local.hour.toString().padLeft(2, '0')}:$minutes';
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  return '$hour:$minutes ${local.hour < 12 ? 'AM' : 'PM'}';
}
