/// The zones an iCalendar text defines beside its events (VTIMEZONE),
/// read by their offsets and rules: for an invitation
/// (`CalendarInvite.parse`) and for a calendar file (`IcsFeed.parse`).
library;

/// A content line's name, upper-cased, and its value as written.
typedef IcsLine = ({String name, String value});

/// A VTIMEZONE: the offsets a named zone keeps, and when it changes them.
///
/// Every calendar that sends invitations defines, beside the event, each
/// zone the event names. Exchange names them the Windows way ("Eastern
/// Standard Time"), which nothing on a phone knows, so the definition is
/// what is read. The rules in them are yearly: a month and the nth or last
/// weekday of it. A calendar file from anywhere may name a zone of its own
/// ("Customized Time Zone", as Outlook exports one) and define it beside
/// its events the same way (calendar idea #67).
class IcsZone {
  IcsZone._(this._observances);

  final List<_Observance> _observances;

  static Map<String, IcsZone> all(Iterable<IcsLine> lines) {
    final zones = <String, IcsZone>{};
    String? id;
    List<_Observance>? observances;
    _Observance? current;
    for (final line in lines) {
      final value = line.value.trim().toUpperCase();
      if (line.name == 'BEGIN' && value == 'VTIMEZONE') {
        id = null;
        observances = [];
      } else if (observances == null) {
        continue;
      } else if (line.name == 'END' && value == 'VTIMEZONE') {
        if (id != null) zones[id] = IcsZone._(observances);
        observances = null;
      } else if (line.name == 'BEGIN' &&
          (value == 'STANDARD' || value == 'DAYLIGHT')) {
        current = _Observance();
      } else if (line.name == 'END' &&
          (value == 'STANDARD' || value == 'DAYLIGHT')) {
        if (current != null && current.isComplete) observances.add(current);
        current = null;
      } else if (line.name == 'TZID' && current == null) {
        id = line.value.trim();
      } else if (current != null) {
        current.read(line);
      }
    }
    return zones;
  }

  /// What the clock in this zone reads at [instant], as a DateTime holding
  /// those figures; null where its rules are not ones this reads. The one
  /// of its offsets whose wall clock comes back to [instant].
  DateTime? wallClockOf(DateTime instant) {
    final utc = instant.toUtc();
    for (final o in _observances) {
      final offset = o.offsetTo;
      if (offset == null) continue;
      final w = utc.add(offset);
      final wall = DateTime(w.year, w.month, w.day, w.hour, w.minute, w.second);
      if (instantOf(wall)?.isAtSameMomentAs(utc) ?? false) return wall;
    }
    return null;
  }

  /// The instant a wall-clock time in this zone is, or null if the zone's
  /// rules are not ones this reads.
  DateTime? instantOf(DateTime local) {
    _Observance? inForce;
    DateTime? since;
    for (final o in _observances) {
      final onset = o.lastOnsetAtOrBefore(local);
      if (onset == null) continue;
      if (since == null || onset.isAfter(since)) {
        since = onset;
        inForce = o;
      }
    }
    final offset = inForce?.offsetTo;
    if (offset == null) return null;
    return DateTime.utc(local.year, local.month, local.day, local.hour,
            local.minute, local.second)
        .subtract(offset);
  }
}

/// A STANDARD or DAYLIGHT part of a zone: the offset from its onset on, and
/// the rule for when that onset comes round again.
class _Observance {
  DateTime? start;
  Duration? offsetTo;
  int? month;
  int? ordinal;
  int? weekday;
  int? monthDay;
  DateTime? until;
  bool unreadable = false;
  final List<DateTime> extra = [];

  bool get isComplete => start != null && offsetTo != null && !unreadable;

  void read(IcsLine line) {
    switch (line.name) {
      case 'DTSTART':
        start = _wallClock(line.value.trim());
      case 'TZOFFSETTO':
        offsetTo = _offset(line.value.trim());
      case 'RDATE':
        for (final v in line.value.split(',')) {
          final at = _wallClock(v.trim());
          if (at != null) extra.add(at);
        }
      case 'RRULE':
        final rule = {
          for (final part in line.value.split(';'))
            if (part.contains('='))
              part.substring(0, part.indexOf('=')).toUpperCase():
                  part.substring(part.indexOf('=') + 1).toUpperCase(),
        };
        if (rule['FREQ'] != 'YEARLY') {
          unreadable = true;
          return;
        }
        month = int.tryParse(rule['BYMONTH'] ?? '');
        monthDay = int.tryParse(rule['BYMONTHDAY'] ?? '');
        final byDay = RegExp(r'^([+-]?\d)?(MO|TU|WE|TH|FR|SA|SU)$')
            .firstMatch(rule['BYDAY'] ?? '');
        if (byDay != null) {
          ordinal = int.tryParse(byDay[1] ?? '1');
          weekday = const ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU']
                  .indexOf(byDay[2]!) +
              1;
        }
        final untilText = rule['UNTIL'];
        if (untilText != null) until = _wallClock(untilText);
        if (month == null || (weekday == null && monthDay == null)) {
          unreadable = true;
        }
    }
  }

  /// When this last took effect at or before [local], wall clock to wall
  /// clock; null if not yet.
  DateTime? lastOnsetAtOrBefore(DateTime local) {
    final first = start;
    if (first == null || first.isAfter(local)) return null;
    DateTime? best;
    void consider(DateTime at) {
      if (at.isAfter(local) || at.isBefore(first)) return;
      if (until != null && at.isAfter(until!)) return;
      if (best == null || at.isAfter(best!)) best = at;
    }

    if (month == null) {
      consider(first);
    } else {
      for (final year in [local.year, local.year - 1]) {
        final day = _dayIn(year);
        if (day == null) continue;
        consider(DateTime(year, month!, day, first.hour, first.minute,
            first.second));
      }
    }
    extra.forEach(consider);
    return best;
  }

  int? _dayIn(int year) {
    if (monthDay != null) return monthDay;
    final n = ordinal ?? 1;
    if (n > 0) {
      final firstOfMonth = DateTime(year, month!);
      final shift = (weekday! - firstOfMonth.weekday + 7) % 7;
      final day = 1 + shift + (n - 1) * 7;
      return day <= DateTime(year, month! + 1, 0).day ? day : null;
    }
    final last = DateTime(year, month! + 1, 0);
    final shift = (last.weekday - weekday! + 7) % 7;
    final day = last.day - shift - (-n - 1) * 7;
    return day >= 1 ? day : null;
  }

  static DateTime? _wallClock(String v) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?')
        .firstMatch(v);
    if (m == null) return null;
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!),
        int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6] ?? '0'));
  }

  static Duration? _offset(String v) {
    final m = RegExp(r'^([+-])(\d{2})(\d{2})(\d{2})?$').firstMatch(v);
    if (m == null) return null;
    final size = Duration(
      hours: int.parse(m[2]!),
      minutes: int.parse(m[3]!),
      seconds: int.parse(m[4] ?? '0'),
    );
    return m[1] == '-' ? -size : size;
  }
}
