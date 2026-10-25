/// A time of day as the phone's clock writes it: "20:14" or "8:14 PM".
///
/// Here rather than with the list's dates, so what is written away from
/// the screen, a meeting's reminder or the morning's agenda, writes a time
/// the same way.
String formatClock(DateTime time, {required bool use24h}) {
  final t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  if (use24h) return '${two(t.hour)}:${two(t.minute)}';
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$hour:${two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
}
