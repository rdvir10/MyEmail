// What Edit sends with Repeat left alone is what 3.17.3 sent (calendar
// idea #55, after the review). 3.17.3's code is copied here as it was
// (`git show v3.17.3:...`), and the bodies Graph and Google are sent for
// the same edit are compared: time, title, people, time with people and
// All day; on a meeting on its own, one meeting of a series and every
// meeting of a series; with and without the phone's zone. The meetings
// here name no zone of their own, so a change of every meeting's time
// goes on the phone's clock, as it did; with its zone known it now keeps
// the series in that zone instead (series_repeat_test).
//
// From the reviewer's probe, build/probes/zz_probe_h1_test.dart.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/domain/calendar_change.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/mail_message.dart';

// ---- 3.17.3's code, copied from `git show v3.17.3:...` ----------------------

String _two(int n) => n.toString().padLeft(2, '0');
String _gStamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
String _gDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _gUtc(DateTime t) {
  final u = t.toUtc();
  return '${_gDate(u)}T${_two(u.hour)}:${_two(u.minute)}:${_two(u.second)}Z';
}

EventChange oldBetween(
  CalendarEvent before, {
  required EventNotes notesBefore,
  required String title,
  required DateTime start,
  required DateTime end,
  required bool allDay,
  required String location,
  required String notes,
  required List<MailAddress> attendees,
  String? timeZone,
}) {
  String key(MailAddress a) => a.email.trim().toLowerCase();
  final had = [
    for (final a in before.attendees)
      if (a.response != EventResponse.organizer) key(a.address),
  ]..sort();
  final now = [for (final a in attendees) key(a)]..sort();
  final timesChanged =
      start != before.start || end != before.end || allDay != before.allDay;
  final notesChanged = notes.trim() != notesBefore.text.trim();
  return EventChange(
    title: title.trim() == before.title.trim() ? null : title.trim(),
    start: timesChanged ? start : null,
    end: timesChanged ? end : null,
    allDay: timesChanged ? allDay : null,
    location: location.trim() == before.location.trim() ? null : location.trim(),
    notes: notesChanged ? notes.trim() : null,
    keptBelow: notesChanged ? notesBefore.keptBelow : null,
    attendees: listEquals(had, now) ? null : attendees,
    timeZone: timeZone,
  );
}

EventChange oldForSeries(EventChange change, SeriesTimes series) {
  if (!change.movesIt) return change;
  final start = change.start!, end = change.end!;
  final first = series.allDay
      ? DateTime(series.start.year, series.start.month, series.start.day)
      : series.start.toLocal();
  if (change.allDay ?? series.allDay) {
    final days = DateTime(end.year, end.month, end.day)
        .difference(DateTime(start.year, start.month, start.day))
        .inDays;
    final from = DateTime(first.year, first.month, first.day);
    return EventChange(
      title: change.title,
      start: from,
      end: DateTime(from.year, from.month, from.day + (days < 1 ? 1 : days)),
      allDay: change.allDay,
      location: change.location,
      notes: change.notes,
      keptBelow: change.keptBelow,
      attendees: change.attendees,
      timeZone: change.timeZone,
    );
  }
  final from =
      DateTime(first.year, first.month, first.day, start.hour, start.minute);
  return EventChange(
    title: change.title,
    start: from,
    end: from.add(end.difference(start)),
    allDay: change.allDay,
    location: change.location,
    notes: change.notes,
    keptBelow: change.keptBelow,
    attendees: change.attendees,
    timeZone: change.timeZone,
  );
}

Map<String, Object?> oldGraphChangeJson(EventChange change,
    {required CalendarEvent before, Object? had}) {
  final zone = change.timeZone;
  Map<String, Object?> at(DateTime t, {required bool allDay}) => allDay
      ? {'dateTime': _gStamp(DateTime(t.year, t.month, t.day)), 'timeZone': zone ?? 'UTC'}
      : zone == null
          ? {'dateTime': _gStamp(t.toUtc()), 'timeZone': 'UTC'}
          : {'dateTime': _gStamp(t), 'timeZone': zone};
  final optional = {
    for (final a in before.attendees)
      if (a.optional) a.address.email.trim().toLowerCase(),
  };
  final notes = change.notes;
  String key(Object? email) => '${email ?? ''}'.trim().toLowerCase();
  final people = change.attendees;
  final known = {
    for (final a in before.attendees) key(a.address.email),
    for (final a in people ?? const <MailAddress>[]) key(a.email),
  };
  return {
    if (change.title != null) 'subject': change.title,
    if (change.movesIt) ...{
      'start': at(change.start!, allDay: change.allDay ?? before.allDay),
      'end': at(change.end!, allDay: change.allDay ?? before.allDay),
      'isAllDay': change.allDay ?? before.allDay,
    },
    if (change.location != null) 'location': {'displayName': change.location},
    if (change.reminder case final r?) ...{
      'isReminderOn': r.isOn,
      if (r.isOn) 'reminderMinutesBeforeStart': r.minutes,
    },
    if (notes != null) 'body': {'contentType': 'text', 'content': notes},
    if (people != null)
      'attendees': [
        for (final a in people)
          {
            'emailAddress': {
              'address': a.email,
              if (a.name?.trim().isNotEmpty ?? false) 'name': a.name!.trim(),
            },
            'type': optional.contains(a.email.trim().toLowerCase())
                ? 'optional'
                : 'required',
          },
        for (final a in had is List ? had.whereType<Map>() : const <Map>[])
          if (a['emailAddress'] case final Map address)
            if (key(address['address']) case final email when email.isNotEmpty)
              if (a['type'] == 'resource' || !known.contains(email))
                {
                  'emailAddress': {
                    'address': '${address['address']}'.trim(),
                    if ('${address['name'] ?? ''}'.trim() case final name
                        when name.isNotEmpty)
                      'name': name,
                  },
                  'type': switch (a['type']) {
                    'resource' => 'resource',
                    'optional' => 'optional',
                    _ => 'required',
                  },
                },
      ],
  };
}

Map<String, Object?> oldGoogleChangeJson(EventChange change,
    {required CalendarEvent before}) {
  final allDay = change.allDay ?? before.allDay;
  final zone = change.timeZone;
  Map<String, Object?> at(DateTime t) => allDay
      ? {'date': _gDate(t), 'dateTime': null, 'timeZone': null}
      : zone == null
          ? {'dateTime': _gUtc(t), 'timeZone': null, 'date': null}
          : {'dateTime': _gStamp(t), 'timeZone': zone, 'date': null};
  return {
    if (change.title != null) 'summary': change.title,
    if (change.movesIt) ...{'start': at(change.start!), 'end': at(change.end!)},
    if (change.location != null) 'location': change.location,
    if (change.notes != null) 'description': change.notes,
    if (change.reminder case final r?)
      'reminders': GoogleCalendarApi.remindersJson(r),
  };
}

List<Map<String, Object?>> oldMerged(Object? had, List<MailAddress> now,
    {required CalendarEvent before}) {
  String key(Object? email) => '${email ?? ''}'.trim().toLowerCase();
  final wanted = {for (final a in now) key(a.email)};
  final shown = {for (final a in before.attendees) key(a.address.email)};
  final kept = <String, Map<String, Object?>>{};
  for (final a in had is List ? had.whereType<Map>() : const <Map>[]) {
    final entry = a.cast<String, Object?>();
    final email = key(entry['email']);
    if (entry['organizer'] == true ||
        entry['resource'] == true ||
        wanted.contains(email) ||
        !shown.contains(email)) {
      kept[email] = entry;
    }
  }
  return [
    ...kept.values,
    for (final a in now)
      if (!kept.containsKey(key(a.email)))
        {
          'email': a.email.trim(),
          if (a.name?.trim().isNotEmpty ?? false) 'displayName': a.name!.trim(),
        },
  ];
}

void main() {
  // ---- 1. Repeat untouched: Edit sends what 3.17.3 sent --------------------
  group('Repeat untouched: the bodies are 3.17.3s', () {
    const dana = MailAddress(email: 'Dana@Example.com', name: 'Dana Levi');
    const yossi = MailAddress(email: 'yossi@example.com', name: 'Yossi');
    const new1 = MailAddress(email: 'new@example.com');
    CalendarEvent event({String? seriesId, bool allDay = false}) =>
        CalendarEvent(
          id: 'e',
          accountId: 'a',
          title: 'Review',
          start: allDay ? DateTime(2026, 11, 17) : DateTime(2026, 11, 17, 14),
          end: allDay ? DateTime(2026, 11, 18) : DateTime(2026, 11, 17, 15),
          allDay: allDay,
          isOrganizer: true,
          response: EventResponse.organizer,
          seriesId: seriesId,
          attendees: const [
            EventAttendee(dana, response: EventResponse.accepted),
            EventAttendee(yossi, optional: true),
          ],
        );
    final hadGraph = [
      {
        'emailAddress': {'address': 'Dana@Example.com', 'name': 'Dana Levi'},
        'type': 'required',
        'status': {'response': 'accepted'},
      },
      {
        'emailAddress': {'address': 'yossi@example.com'},
        'type': 'optional',
      },
      {
        'emailAddress': {'address': 'room1@x.com', 'name': 'Room 1'},
        'type': 'resource',
      },
      {
        'emailAddress': {'address': 'outlook-added@x.com'},
        'type': 'optional',
      },
    ];
    final hadGoogle = [
      {'email': 'ron@me.com', 'organizer': true, 'self': true, 'responseStatus': 'accepted'},
      {'email': 'dana@example.com', 'displayName': 'Dana Levi', 'responseStatus': 'accepted', 'comment': 'yes'},
      {'email': 'yossi@example.com', 'optional': true, 'responseStatus': 'needsAction'},
      {'email': 'room@resource.calendar.google.com', 'resource': true},
      {'email': 'added@x.com', 'additionalGuests': 2},
    ];
    final series = (
      start: DateTime(2026, 7, 7, 14).toUtc(),
      end: DateTime(2026, 7, 7, 15).toUtc(),
      allDay: false,
    );

    for (final where in ['alone', 'one of series', 'whole series']) {
      for (final what in ['time', 'title', 'people', 'time+people', 'allDay']) {
        test('$where, $what', () {
          final before = event(
              seriesId: where == 'alone' ? null : 's',
              allDay: false);
          final people = what.contains('people')
              ? [dana, yossi, new1]
              : [dana, yossi];
          final start = what.contains('time')
              ? DateTime(2026, 11, 17, 16)
              : what == 'allDay'
                  ? DateTime(2026, 11, 17)
                  : before.start;
          final end = what.contains('time')
              ? DateTime(2026, 11, 17, 16, 30)
              : what == 'allDay'
                  ? DateTime(2026, 11, 18)
                  : before.end;
          final allDay = what == 'allDay';
          final title = what == 'title' ? 'Review 2' : before.title;
          // What the screen hands `between` with nobody's optional changed:
          // those the event has as optional, among the field's people.
          final optional = {
            for (final a in people)
              if (before.attendees.any((e) =>
                  e.optional &&
                  e.address.email.toLowerCase() == a.email.toLowerCase()))
                a.email.trim().toLowerCase(),
          };
          for (final zone in [null, 'America/New_York']) {
            var now = EventChange.between(before,
                notesBefore: const EventNotes(text: ''),
                title: title,
                start: start,
                end: end,
                allDay: allDay,
                location: '',
                notes: '',
                attendees: people,
                optional: optional,
                timeZone: zone,
                reminder: null,
                repeat: null);
            var old = oldBetween(before,
                notesBefore: const EventNotes(text: ''),
                title: title,
                start: start,
                end: end,
                allDay: allDay,
                location: '',
                notes: '',
                attendees: people,
                timeZone: zone);
            if (where == 'whole series') {
              now = forSeries(now, series);
              old = oldForSeries(old, series);
            }
            expect(now.isEmpty, old.isEmpty);
            expect(
              GraphCalendarApi.changeJson(now, before: before, had: hadGraph),
              oldGraphChangeJson(old, before: before, had: hadGraph),
              reason: 'Graph $where $what $zone',
            );
            expect(
              GoogleCalendarApi.changeJson(now, before: before),
              oldGoogleChangeJson(old, before: before),
              reason: 'Google $where $what $zone',
            );
            if (now.attendees != null) {
              expect(
                GoogleCalendarApi.mergedAttendees(hadGoogle, now.attendees!,
                    before: before, optional: now.optional),
                oldMerged(hadGoogle, old.attendees!, before: before),
                reason: 'Google people $where $what',
              );
            }
          }
        });
      }
    }
  });
}
