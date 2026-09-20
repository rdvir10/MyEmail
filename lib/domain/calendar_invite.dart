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
  });

  /// REQUEST for an invitation, CANCEL for one withdrawn, REPLY for an
  /// answer, PUBLISH for an event with no reply wanted.
  final String method;
  final String uid;
  final String summary;

  /// Local time on the device when the invitation named a time zone the
  /// device does not know; UTC when it said Z; a date at midnight when it
  /// is a whole day.
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

  bool get isRequest => method == 'REQUEST';
  bool get isCancellation => method == 'CANCEL';

  /// Parse the part, or null if there is no VEVENT in it.
  static CalendarInvite? parse(String ics) {
    final lines = _unfold(ics);
    var method = 'PUBLISH';
    var inEvent = false;
    var seen = false;
    String? uid;
    String? summary;
    DateTime? start;
    DateTime? end;
    var allDay = false;
    String? tz;
    String? location;
    String? description;
    MailAddress? organizer;
    final attendees = <MailAddress>[];
    var sequence = 0;
    DateTime? stamp;

    for (final line in lines) {
      final colon = _valueStart(line);
      if (colon < 0) continue;
      final head = line.substring(0, colon);
      final value = line.substring(colon + 1);
      final parts = head.split(';');
      final name = parts.first.toUpperCase();
      final params = <String, String>{
        for (final p in parts.skip(1))
          if (p.contains('='))
            p.substring(0, p.indexOf('=')).toUpperCase():
                p.substring(p.indexOf('=') + 1).replaceAll('"', ''),
      };

      if (!inEvent) {
        if (name == 'METHOD') method = value.trim().toUpperCase();
        if (name == 'BEGIN' && value.trim().toUpperCase() == 'VEVENT') {
          if (seen) break; // The first event is the invitation.
          inEvent = true;
          seen = true;
        }
        continue;
      }
      if (name == 'END' && value.trim().toUpperCase() == 'VEVENT') {
        inEvent = false;
        continue;
      }
      switch (name) {
        case 'UID':
          uid = value.trim();
        case 'SUMMARY':
          summary = _unescape(value);
        case 'DTSTART':
          final (at, wholeDay) = _date(value, params);
          start = at;
          allDay = wholeDay;
          tz ??= params['TZID'];
        case 'DTEND':
          end = _date(value, params).$1;
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
          stamp = _date(value, params).$1;
      }
    }
    if (!seen || start == null) return null;
    return CalendarInvite(
      method: method,
      uid: uid ?? '',
      summary: summary ?? '(No title)',
      start: start,
      end: end,
      isAllDay: allDay,
      timeZone: tz,
      location: location,
      description: description,
      organizer: organizer,
      attendees: attendees,
      sequence: sequence,
      dtStamp: stamp,
    );
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
    'SUMMARY:${_escape(invite.summary)}',
    if (invite.isAllDay)
      'DTSTART;VALUE=DATE:${_dateOnly(invite.start)}'
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

(DateTime, bool) _date(String value, Map<String, String> params) {
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
  return (DateTime(y, mo, d, h, mi, s), false);
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
