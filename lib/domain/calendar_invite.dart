import 'mail_message.dart';

/// A meeting request, as it travels inside a message: the `text/calendar`
/// part, iCalendar (RFC 5545) with METHOD:REQUEST, one VEVENT.
///
/// Parsed here from the text, once, into what the reading pane shows and
/// what a reply needs to say. Not a calendar: the app keeps no events. It
/// shows an invitation, answers it, and hands the event to the device's
/// calendar to keep.
class CalendarInvite {
  const CalendarInvite({
    required this.method,
    required this.uid,
    required this.summary,
    required this.start,
    this.end,
    this.isAllDay = false,
    this.timeZone,
    this.location,
    this.description,
    this.organizer,
    this.attendees = const [],
    this.sequence = 0,
    this.dtStamp,
    this.recurrenceId,
    this.startAsWritten,
  });

  /// REQUEST for an invitation, CANCEL for one withdrawn, REPLY for an
  /// answer, PUBLISH for an event with no reply wanted.
  final String method;
  final String uid;
  final String summary;

  /// UTC when the invitation said Z, or named a time zone it defines (every
  /// calendar that sends invitations defines the zones it names); a date at
  /// midnight when it is a whole day. Otherwise the time as written, with
  /// [timeZone] saying whose it is, and [timeIsKnown] false.
  ///
  /// A named zone used to be read as the device's own, so a 13:00 meeting
  /// in New York went into a calendar in Israel at 13:00, seven hours early,
  /// and the answer carried the same wrong time.
  final DateTime start;
  final DateTime? end;
  final bool isAllDay;

  /// The TZID the sender wrote, if any, shown next to the time so a
  /// meeting in another zone is not taken for one in this.
  final String? timeZone;
  final String? location;
  final String? description;
  final MailAddress? organizer;
  final List<MailAddress> attendees;
  final int sequence;
  final DateTime? dtStamp;

  /// Which occurrence of a series this is about, as the line a reply has to
  /// carry, or null for a single event or the whole series. Without it, a
  /// decline of one moved occurrence declined every one.
  final String? recurrenceId;

  /// The DTSTART line as the sender wrote it, for a time whose zone could
  /// not be worked out: a reply echoes that rather than guessing.
  final String? startAsWritten;

  /// Whether [start] is a real instant (or a whole day), rather than a time
  /// in a zone that could not be worked out.
  bool get timeIsKnown => isAllDay || start.isUtc || timeZone == null;

  bool get isRequest => method == 'REQUEST';
  bool get isCancellation => method == 'CANCEL';

  /// Parse the part, or null if there is no VEVENT in it.
  static CalendarInvite? parse(String ics) {
    final lines = [for (final l in _unfold(ics)) ?_Line.parse(l)];
    final zones = _Zone.all(lines);
    var method = 'PUBLISH';
    var inEvent = false;
    // How deep inside the event: its own properties are at 0. A reminder
    // (VALARM) nested in it has a DESCRIPTION of its own, "REMINDER" on
    // every Exchange and Teams invitation, which was taken for the event's.
    var depth = 0;
    var seen = false;
    String? uid;
    String? summary;
    _Line? startLine;
    _Line? endLine;
    _Line? recurrenceLine;
    String? location;
    String? description;
    MailAddress? organizer;
    final attendees = <MailAddress>[];
    var sequence = 0;
    DateTime? stamp;

    for (final line in lines) {
      final name = line.name;
      final value = line.value;
      final params = line.params;

      if (!inEvent) {
        if (name == 'METHOD') method = value.trim().toUpperCase();
        if (name == 'BEGIN' && value.trim().toUpperCase() == 'VEVENT') {
          if (seen) break; // The first event is the invitation.
          inEvent = true;
          seen = true;
        }
        continue;
      }
      if (name == 'BEGIN') {
        depth++;
        continue;
      }
      if (name == 'END') {
        if (depth > 0) {
          depth--;
        } else if (value.trim().toUpperCase() == 'VEVENT') {
          inEvent = false;
        }
        continue;
      }
      if (depth > 0) continue;
      switch (name) {
        case 'UID':
          uid = value.trim();
        case 'SUMMARY':
          summary = _unescape(value);
        case 'DTSTART':
          startLine = line;
        case 'DTEND':
          endLine = line;
        case 'RECURRENCE-ID':
          recurrenceLine = line;
        case 'LOCATION':
          location = _unescape(value);
        case 'DESCRIPTION':
          description = _unescape(value);
        case 'ORGANIZER':
          organizer = _address(value, params);
        case 'ATTENDEE':
          final a = _address(value, params);
          if (a != null) attendees.add(a);
        case 'SEQUENCE':
          sequence = int.tryParse(value.trim()) ?? 0;
        case 'DTSTAMP':
          stamp = _date(value, params, zones).$1;
      }
    }
    if (!seen || startLine == null) return null;
    final (start, allDay) = _date(startLine.value, startLine.params, zones);
    final tz = startLine.params['TZID'];
    final known = allDay || start.isUtc || tz == null;
    return CalendarInvite(
      method: method,
      uid: uid ?? '',
      summary: summary ?? '(No title)',
      start: start,
      end: endLine == null ? null : _date(endLine.value, endLine.params, zones).$1,
      isAllDay: allDay,
      timeZone: tz,
      location: location,
      description: description,
      organizer: organizer,
      attendees: attendees,
      sequence: sequence,
      dtStamp: stamp,
      recurrenceId: recurrenceLine == null
          ? null
          : _asReplyLine(recurrenceLine, zones),
      startAsWritten: known ? null : startLine.raw,
    );
  }
}

/// One content line, split into its name, parameters and value.
class _Line {
  _Line(this.raw, this.name, this.params, this.value);

  final String raw;
  final String name;
  final Map<String, String> params;
  final String value;

  static _Line? parse(String raw) {
    final colon = _valueStart(raw);
    if (colon < 0) return null;
    final parts = raw.substring(0, colon).split(';');
    return _Line(
      raw,
      parts.first.toUpperCase(),
      {
        for (final p in parts.skip(1))
          if (p.contains('='))
            p.substring(0, p.indexOf('=')).toUpperCase():
                p.substring(p.indexOf('=') + 1).replaceAll('"', ''),
      },
      raw.substring(colon + 1),
    );
  }
}

/// A date-time line as a reply should carry it: in UTC where the zone was
/// worked out, which needs no VTIMEZONE beside it; as written otherwise.
String _asReplyLine(_Line line, Map<String, _Zone> zones) {
  final (at, wholeDay) = _date(line.value, line.params, zones);
  if (wholeDay) return '${line.name};VALUE=DATE:${_dateOnly(at)}';
  if (at.isUtc) return '${line.name}:${_stamp(at)}';
  return line.raw;
}

/// A VTIMEZONE: the offsets a named zone keeps, and when it changes them.
///
/// Every calendar that sends invitations defines, beside the event, each
/// zone the event names. Exchange names them the Windows way ("Eastern
/// Standard Time"), which nothing on a phone knows, so the definition is
/// what is read. The rules in them are yearly: a month and the nth or last
/// weekday of it.
class _Zone {
  _Zone(this.observances);

  final List<_Observance> observances;

  static Map<String, _Zone> all(List<_Line> lines) {
    final zones = <String, _Zone>{};
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
        if (id != null) zones[id] = _Zone(observances);
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

  /// The instant a wall-clock time in this zone is, or null if the zone's
  /// rules are not ones this reads.
  DateTime? instantOf(DateTime local) {
    _Observance? inForce;
    DateTime? since;
    for (final o in observances) {
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

  void read(_Line line) {
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

/// How an attendee answers.
enum InviteResponse { accepted, tentative, declined }

extension InviteResponseWords on InviteResponse {
  String get partStat => switch (this) {
        InviteResponse.accepted => 'ACCEPTED',
        InviteResponse.tentative => 'TENTATIVE',
        InviteResponse.declined => 'DECLINED',
      };

  String get word => switch (this) {
        InviteResponse.accepted => 'Accepted',
        InviteResponse.tentative => 'Tentative',
        InviteResponse.declined => 'Declined',
      };
}

/// The reply an attendee sends back: iCalendar with METHOD:REPLY, the same
/// UID, and the attendee's PARTSTAT. This is iMIP (RFC 6047), what every
/// calendar server reads when it arrives in a message to the organizer.
String iMipReply(
  CalendarInvite invite, {
  required MailAddress attendee,
  required InviteResponse response,
  DateTime? now,
}) {
  final stamp = _stamp((now ?? DateTime.now()).toUtc());
  final name = attendee.name?.trim();
  final cn = name == null || name.isEmpty ? '' : ';CN=${_escape(name)}';
  final organizer = invite.organizer;
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'PRODID:-//MyEmail//EN',
    'VERSION:2.0',
    'METHOD:REPLY',
    'BEGIN:VEVENT',
    'UID:${invite.uid}',
    'DTSTAMP:$stamp',
    if (organizer != null) 'ORGANIZER:mailto:${organizer.email}',
    'ATTENDEE$cn;PARTSTAT=${response.partStat}:mailto:${attendee.email}',
    // The occurrence answered, when it is one of a series. Left out, the
    // organiser's calendar applied the answer to every occurrence.
    ?invite.recurrenceId,
    'SUMMARY:${_escape(invite.summary)}',
    if (invite.isAllDay)
      'DTSTART;VALUE=DATE:${_dateOnly(invite.start)}'
    else if (invite.startAsWritten != null)
      invite.startAsWritten!
    else
      'DTSTART:${_stamp(invite.start.toUtc())}',
    'SEQUENCE:${invite.sequence}',
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return '${lines.map(_fold).join('\r\n')}\r\n';
}

/// A subject the organizer's calendar and eye both read.
String inviteReplySubject(CalendarInvite invite, InviteResponse response) =>
    '${response.word}: ${invite.summary}';

// --- the text form ----------------------------------------------------------

List<String> _unfold(String ics) {
  final out = <String>[];
  for (final raw in ics.split(RegExp(r'\r\n|\n|\r'))) {
    if ((raw.startsWith(' ') || raw.startsWith('\t')) && out.isNotEmpty) {
      out[out.length - 1] += raw.substring(1);
    } else if (raw.isNotEmpty) {
      out.add(raw);
    }
  }
  return out;
}

/// The colon that ends the name and its parameters, which may hold quoted
/// colons of their own (`CN="Dvir, Ron":mailto:…`).
int _valueStart(String line) {
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') quoted = !quoted;
    if (c == ':' && !quoted) return i;
  }
  return -1;
}

(DateTime, bool) _date(
  String value,
  Map<String, String> params, [
  Map<String, _Zone> zones = const {},
]) {
  final v = value.trim();
  if (params['VALUE'] == 'DATE' || (v.length == 8 && !v.contains('T'))) {
    return (
      DateTime(
        int.parse(v.substring(0, 4)),
        int.parse(v.substring(4, 6)),
        int.parse(v.substring(6, 8)),
      ),
      true,
    );
  }
  final y = int.parse(v.substring(0, 4));
  final mo = int.parse(v.substring(4, 6));
  final d = int.parse(v.substring(6, 8));
  final h = int.parse(v.substring(9, 11));
  final mi = int.parse(v.substring(11, 13));
  final s = v.length >= 15 ? int.parse(v.substring(13, 15)) : 0;
  if (v.endsWith('Z')) return (DateTime.utc(y, mo, d, h, mi, s), false);
  final local = DateTime(y, mo, d, h, mi, s);
  final zone = zones[params['TZID']];
  return (zone?.instantOf(local) ?? local, false);
}

MailAddress? _address(String value, Map<String, String> params) {
  final v = value.trim();
  final email = v.toLowerCase().startsWith('mailto:') ? v.substring(7) : v;
  if (email.isEmpty) return null;
  return MailAddress(email: email, name: params['CN']);
}

String _unescape(String v) => v
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\N', '\n')
    .replaceAll(r'\,', ',')
    .replaceAll(r'\;', ';')
    .replaceAll(r'\\', r'\');

String _escape(String v) => v
    .replaceAll(r'\', r'\\')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,')
    .replaceAll('\n', r'\n');

String _two(int n) => n.toString().padLeft(2, '0');

String _stamp(DateTime utc) =>
    '${utc.year}${_two(utc.month)}${_two(utc.day)}T'
    '${_two(utc.hour)}${_two(utc.minute)}${_two(utc.second)}Z';

String _dateOnly(DateTime d) => '${d.year}${_two(d.month)}${_two(d.day)}';

/// Lines longer than 75 octets are folded, per the RFC; a server that
/// refuses long lines is rarer than one that is strict, but it exists.
String _fold(String line) {
  if (line.length <= 75) return line;
  final out = StringBuffer(line.substring(0, 75));
  var i = 75;
  while (i < line.length) {
    final next = (i + 74).clamp(0, line.length);
    out.write('\r\n ${line.substring(i, next)}');
    i = next;
  }
  return out.toString();
}
