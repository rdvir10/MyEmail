import 'package:flutter/services.dart';

/// The device's calendar, as far as this app needs it: somewhere to hand
/// an event to. The calendar app's own "new event" screen opens with the
/// fields filled in, so the person sees it and picks the calendar; no
/// permission is involved.
abstract class DeviceCalendar {
  Future<bool> available();

  /// True if a calendar app took it. False when there is none.
  Future<bool> insertEvent({
    required String title,
    String? description,
    String? location,
    DateTime? start,
    DateTime? end,
    bool allDay = false,
  });
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
  }) async =>
      await _channel.invokeMethod<bool>('insert', {
        'title': title,
        'description': description,
        'location': location,
        'start': start?.millisecondsSinceEpoch,
        'end': end?.millisecondsSinceEpoch,
        'allDay': allDay,
      }) ??
      false;
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
  });

  final String title;
  final String? description;
  final String? location;
  final DateTime? start;
  final DateTime? end;
  final bool allDay;
}

/// Records what would have gone to the calendar. Tests, and the browser
/// preview.
class FakeDeviceCalendar implements DeviceCalendar {
  FakeDeviceCalendar({this.supported = true});

  final bool supported;
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
  }) async {
    if (!supported) return false;
    inserted.add(InsertedEvent(
      title: title,
      description: description,
      location: location,
      start: start,
      end: end,
      allDay: allDay,
    ));
    return true;
  }
}
