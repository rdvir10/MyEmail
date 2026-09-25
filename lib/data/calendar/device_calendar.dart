import 'package:flutter/services.dart';

/// The device's calendar, as far as this app needs it: somewhere to hand
/// an event to. The calendar app's own "new event" screen opens with the
/// fields filled in, so the person sees it and picks the calendar; no
/// permission is involved.
abstract class DeviceCalendar {
  Future<bool> available();

  /// True if a calendar app took it. False when there is none.
  ///
  /// [attendees] are addresses, which the calendar app invites once the
  /// event is saved there: the way a meeting is sent from an account whose
  /// calendar this app cannot reach itself.
  Future<bool> insertEvent({
    required String title,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
    bool allDay = false,
    List<String> attendees = const [],
  });

  /// The device's time zone by its IANA name, "Asia/Jerusalem", or null
  /// where the device will not say. Dart knows the zone's offset and its
  /// abbreviation, and neither is what a calendar server is told a meeting's
  /// time is in.
  Future<String?> timeZoneId();
}

class AndroidDeviceCalendar implements DeviceCalendar {
  const AndroidDeviceCalendar();

  static const _channel = MethodChannel('mailtree/calendar');

  @override
  Future<bool> available() async =>
      await _channel.invokeMethod<bool>('available') ?? false;

  @override
  Future<bool> insertEvent({
    required String title,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
    bool allDay = false,
    List<String> attendees = const [],
  }) async =>
      await _channel.invokeMethod<bool>('insert', {
        'title': title,
        'description': description,
        'location': location,
        'start': start?.millisecondsSinceEpoch,
        'end': end?.millisecondsSinceEpoch,
        'allDay': allDay,
        'attendees': attendees,
      }) ??
      false;

  @override
  Future<String?> timeZoneId() => _channel.invokeMethod<String>('timeZone');
}

/// One event handed over, as the fake remembers it.
class InsertedEvent {
  const InsertedEvent({
    required this.title,
    this.description,
    this.location,
    this.start,
    this.end,
    this.allDay = false,
    this.attendees = const [],
  });

  final String title;
  final String? description;
  final String? location;
  final DateTime? start;
  final DateTime? end;
  final bool allDay;
  final List<String> attendees;
}

/// Records what would have gone to the calendar. Tests, and the browser
/// preview.
class FakeDeviceCalendar implements DeviceCalendar {
  FakeDeviceCalendar({this.supported = true, this.timeZone});

  final bool supported;

  /// What the device says its zone is; null, the default, for one that
  /// will not say.
  final String? timeZone;

  final List<InsertedEvent> inserted = [];

  @override
  Future<bool> available() async => supported;

  @override
  Future<bool> insertEvent({
    required String title,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
    bool allDay = false,
    List<String> attendees = const [],
  }) async {
    if (!supported) return false;
    inserted.add(InsertedEvent(
      title: title,
      description: description,
      location: location,
      start: start,
      end: end,
      allDay: allDay,
      attendees: attendees,
    ));
    return true;
  }

  @override
  Future<String?> timeZoneId() async => timeZone;
}
