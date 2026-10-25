import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// The world's time zones, by their IANA names, for a meeting set in
/// another zone and the calendar's second clock. The database is read
/// once, the first time a zone is asked about: ten years of it, which is
/// what a meeting can be set across.

var _loaded = false;

void _load() {
  if (_loaded) return;
  tzdata.initializeTimeZones();
  _loaded = true;
}

/// Whether [name] is a zone the database knows.
bool isTimeZone(String name) {
  _load();
  try {
    tz.getLocation(name);
    return true;
  } catch (_) {
    return false;
  }
}

/// Every zone the database knows, by name, in order.
List<String> allTimeZones() {
  _load();
  return tz.timeZoneDatabase.locations.keys
      .where((n) => n.contains('/') && !n.startsWith('Etc/'))
      .toList()
    ..sort();
}

/// What the clock in [zone] reads at [instant], as a DateTime holding those
/// figures: not an instant of its own.
DateTime wallClockIn(DateTime instant, String zone) {
  _load();
  final t = tz.TZDateTime.from(instant, tz.getLocation(zone));
  return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

/// The instant at which the clock in [zone] reads [wallClock]'s figures.
DateTime instantIn(DateTime wallClock, String zone) {
  _load();
  final t = tz.TZDateTime(
    tz.getLocation(zone),
    wallClock.year,
    wallClock.month,
    wallClock.day,
    wallClock.hour,
    wallClock.minute,
    wallClock.second,
  );
  return DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch);
}

/// How far [zone] is from UTC at [instant], as people write it: "UTC+2",
/// "UTC−5", "UTC+5:30".
String offsetOf(String zone, DateTime instant) {
  _load();
  final offset = tz.TZDateTime.from(instant, tz.getLocation(zone)).timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  final sign = offset.isNegative ? '−' : '+';
  final h = minutes ~/ 60, m = minutes % 60;
  return 'UTC$sign$h${m == 0 ? '' : ':${m.toString().padLeft(2, '0')}'}';
}

/// [zone] as a place, for a person: "America/New_York" is New York.
String placeOf(String zone) => zone.split('/').last.replaceAll('_', ' ');

/// The IANA zone a zone's name means: one already, or a Windows name, which
/// is how Exchange names the zone a meeting was set in. Null for one it
/// does not know.
String? ianaZoneOf(String name) {
  if (isTimeZone(name)) return name;
  return _windowsZones[name];
}

/// Windows' zone names, as Exchange gives them, and the IANA zone each is
/// for: the common ones, from the Unicode list (windowsZones, territory
/// 001).
const _windowsZones = {
  'Dateline Standard Time': 'Etc/GMT+12',
  'UTC': 'Etc/UTC',
  'Hawaiian Standard Time': 'Pacific/Honolulu',
  'Alaskan Standard Time': 'America/Anchorage',
  'Pacific Standard Time': 'America/Los_Angeles',
  'US Mountain Standard Time': 'America/Phoenix',
  'Mountain Standard Time': 'America/Denver',
  'Central Standard Time': 'America/Chicago',
  'Canada Central Standard Time': 'America/Regina',
  'Central America Standard Time': 'America/Guatemala',
  'Central Standard Time (Mexico)': 'America/Mexico_City',
  'Eastern Standard Time': 'America/New_York',
  'US Eastern Standard Time': 'America/Indiana/Indianapolis',
  'SA Pacific Standard Time': 'America/Bogota',
  'Atlantic Standard Time': 'America/Halifax',
  'Newfoundland Standard Time': 'America/St_Johns',
  'E. South America Standard Time': 'America/Sao_Paulo',
  'Argentina Standard Time': 'America/Argentina/Buenos_Aires',
  'GMT Standard Time': 'Europe/London',
  'Greenwich Standard Time': 'Atlantic/Reykjavik',
  'W. Europe Standard Time': 'Europe/Berlin',
  'Romance Standard Time': 'Europe/Paris',
  'Central Europe Standard Time': 'Europe/Budapest',
  'Central European Standard Time': 'Europe/Warsaw',
  'E. Europe Standard Time': 'Europe/Chisinau',
  'FLE Standard Time': 'Europe/Kyiv',
  'GTB Standard Time': 'Europe/Bucharest',
  'Israel Standard Time': 'Asia/Jerusalem',
  'Egypt Standard Time': 'Africa/Cairo',
  'South Africa Standard Time': 'Africa/Johannesburg',
  'Turkey Standard Time': 'Europe/Istanbul',
  'Russian Standard Time': 'Europe/Moscow',
  'Arab Standard Time': 'Asia/Riyadh',
  'Arabian Standard Time': 'Asia/Dubai',
  'Iran Standard Time': 'Asia/Tehran',
  'Pakistan Standard Time': 'Asia/Karachi',
  'India Standard Time': 'Asia/Kolkata',
  'Bangladesh Standard Time': 'Asia/Dhaka',
  'SE Asia Standard Time': 'Asia/Bangkok',
  'China Standard Time': 'Asia/Shanghai',
  'Singapore Standard Time': 'Asia/Singapore',
  'Taipei Standard Time': 'Asia/Taipei',
  'Tokyo Standard Time': 'Asia/Tokyo',
  'Korea Standard Time': 'Asia/Seoul',
  'AUS Eastern Standard Time': 'Australia/Sydney',
  'E. Australia Standard Time': 'Australia/Brisbane',
  'Cen. Australia Standard Time': 'Australia/Adelaide',
  'W. Australia Standard Time': 'Australia/Perth',
  'New Zealand Standard Time': 'Pacific/Auckland',
};
