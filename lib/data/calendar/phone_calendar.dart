import 'dart:convert';

import 'package:flutter/services.dart';

import '../../domain/calendar_event.dart';

/// One of the calendars the app made in the phone's calendar.
typedef PhoneCalendarRow = ({int id, String key, String account, String name});

/// How many events one pass added, rewrote and took out.
typedef PhoneSyncResult = ({int added, int changed, int removed});

/// The phone's own calendar, written to: Android's calendar provider,
/// through the phone_calendar plugin (packages/phone_calendar), which is
/// registered in the background worker's engine as well as the app's. A
/// calendar per account, read only in the calendar app; see
/// `PhoneCalendarSync`.
abstract class PhoneCalendar {
  Future<bool> hasPermission();

  /// Android's own dialog. False where it was refused, or could not be
  /// shown (the background has no screen to show it on).
  Future<bool> requestPermission();

  /// The calendars this app made.
  Future<List<PhoneCalendarRow>> calendars();

  /// [key]'s calendar, made under [account] if it is not there, and named
  /// and coloured as given. Answers its id.
  Future<int> ensureCalendar({
    required String key,
    required String account,
    required String name,
    required int color,
  });

  /// [events] into calendar [calendarId]: new ones added, changed ones
  /// rewritten, and ones from [from] on that are not among them taken out.
  Future<PhoneSyncResult> sync({
    required int calendarId,
    required String account,
    required DateTime from,
    required List<CalendarEvent> events,
  });

  /// [key]'s calendar taken out, its events with it. False where there was
  /// none.
  Future<bool> remove(String key);
}

/// Whether [e] goes into the phone's calendar at all: not one cancelled,
/// nor one turned down, which Outlook takes off the calendar too.
bool goesToPhone(CalendarEvent e) =>
    !e.cancelled && e.response != EventResponse.declined;

/// [e] as the plugin takes it, with a digest of what it says, so a pass
/// rewrites only what changed. A whole day runs from midnight to midnight
/// in UTC, as the calendar provider wants it.
Map<String, Object?> phoneEventOf(CalendarEvent e) {
  int at(DateTime t) => e.allDay
      ? DateTime.utc(t.year, t.month, t.day).millisecondsSinceEpoch
      : t.millisecondsSinceEpoch;
  final description = [
    if (e.preview.isNotEmpty) e.preview,
    if (e.joinUrl != null) 'Join: ${e.joinUrl}',
  ].join('\n\n');
  final fields = <String, Object?>{
    'id': e.id,
    'title': e.title.isEmpty ? '(No title)' : e.title,
    'start': at(e.start),
    'end': at(e.end),
    'allDay': e.allDay,
    'location': e.location,
    'description': description,
    'organizer': e.organizer?.email,
    // CalendarContract's AVAILABILITY_BUSY, _FREE and _TENTATIVE.
    'availability': switch (e.showAs) {
      EventShowAs.free || EventShowAs.workingElsewhere => 1,
      EventShowAs.tentative => 2,
      _ => 0,
    },
    'tentative': e.response == EventResponse.tentative,
    'reminder': e.reminderMinutes,
  };
  return {...fields, 'digest': digestOf(jsonEncode(fields))};
}

/// FNV-1a, 64 bits, as hex: the same on every run, which String.hashCode
/// is not promised to be.
String digestOf(String text) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final unit in utf8.encode(text)) {
    hash = ((hash ^ BigInt.from(unit)) * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

class AndroidPhoneCalendar implements PhoneCalendar {
  const AndroidPhoneCalendar();

  static const _channel = MethodChannel('mailtree/phone-calendar');

  @override
  Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<List<PhoneCalendarRow>> calendars() async {
    final rows = await _channel.invokeListMethod<Map>('calendars') ?? const [];
    return [
      for (final r in rows)
        (
          id: (r['id'] as num).toInt(),
          key: '${r['key']}',
          account: '${r['account']}',
          name: '${r['name']}',
        ),
    ];
  }

  @override
  Future<int> ensureCalendar({
    required String key,
    required String account,
    required String name,
    required int color,
  }) async {
    final id = await _channel.invokeMethod<num>('ensureCalendar', {
      'key': key,
      'account': account,
      'name': name,
      // The provider takes a signed 32-bit colour.
      'color': color.toSigned(32),
    });
    return id!.toInt();
  }

  @override
  Future<PhoneSyncResult> sync({
    required int calendarId,
    required String account,
    required DateTime from,
    required List<CalendarEvent> events,
  }) async {
    final answer = await _channel.invokeMapMethod<String, Object?>('sync', {
      'calendarId': calendarId,
      'account': account,
      'from': from.millisecondsSinceEpoch,
      'events': [
        for (final e in events)
          if (goesToPhone(e)) phoneEventOf(e),
      ],
    });
    int count(String key) => (answer?[key] as num?)?.toInt() ?? 0;
    return (added: count('added'), changed: count('changed'), removed: count('removed'));
  }

  @override
  Future<bool> remove(String key) async =>
      await _channel.invokeMethod<bool>('remove', {'key': key}) ?? false;
}

/// The phone's calendar in memory, for tests.
class FakePhoneCalendar implements PhoneCalendar {
  FakePhoneCalendar({this.allowed = true, this.grants = true});

  bool allowed;

  /// What the dialog answers.
  bool grants;

  /// Calendars by key, and their events by id.
  final Map<String, ({int id, String account, String name, int color})> made = {};
  final Map<String, Map<String, Map<String, Object?>>> eventsOf = {};
  var _next = 0;

  @override
  Future<bool> hasPermission() async => allowed;

  @override
  Future<bool> requestPermission() async => allowed = allowed || grants;

  @override
  Future<List<PhoneCalendarRow>> calendars() async => [
        for (final MapEntry(:key, :value) in made.entries)
          (id: value.id, key: key, account: value.account, name: value.name),
      ];

  @override
  Future<int> ensureCalendar({
    required String key,
    required String account,
    required String name,
    required int color,
  }) async {
    final id = made[key]?.id ?? ++_next;
    made[key] = (id: id, account: account, name: name, color: color);
    return id;
  }

  @override
  Future<PhoneSyncResult> sync({
    required int calendarId,
    required String account,
    required DateTime from,
    required List<CalendarEvent> events,
  }) async {
    final key = made.entries.firstWhere((e) => e.value.id == calendarId).key;
    final here = eventsOf.putIfAbsent(key, () => {});
    var added = 0, changed = 0, removed = 0;
    final seen = <String>{};
    for (final e in events.where(goesToPhone)) {
      final row = phoneEventOf(e);
      seen.add(e.id);
      final was = here[e.id];
      if (was == null) {
        added++;
      } else if (was['digest'] != row['digest']) {
        changed++;
      } else {
        continue;
      }
      here[e.id] = row;
    }
    for (final id in here.keys.toList()) {
      if (seen.contains(id)) continue;
      if ((here[id]!['start'] as int) < from.millisecondsSinceEpoch) continue;
      here.remove(id);
      removed++;
    }
    return (added: added, changed: changed, removed: removed);
  }

  @override
  Future<bool> remove(String key) async {
    eventsOf.remove(key);
    return made.remove(key) != null;
  }
}
