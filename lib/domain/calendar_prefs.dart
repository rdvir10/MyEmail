import 'dart:convert';

import 'package:flutter/foundation.dart';

/// How the calendar shows the day, chosen in Settings, Calendar, and
/// carried by the backup: whether meetings you declined still show, the
/// working day, where Day and Week open and outside which the hours are
/// shaded, a second clock down Day and Week's side, and whether the dates
/// in mail are underlined.
@immutable
class CalendarPrefs {
  const CalendarPrefs({
    this.showDeclined = false,
    this.dayStart = 9,
    this.dayEnd = 17,
    this.secondZone,
    this.datesInMail = true,
  });

  /// A meeting you declined that its calendar keeps (Google's do; Outlook
  /// takes them off itself): shown faint and struck through, or not at all.
  final bool showDeclined;

  /// The working day in whole hours, [dayStart] before [dayEnd].
  final int dayStart;
  final int dayEnd;

  /// A second time zone's hours beside the phone's own, by its IANA name,
  /// as Outlook's Time zones shows one: null for none.
  final String? secondZone;

  /// Dates and times in a message underlined, a tap making a meeting then.
  final bool datesInMail;

  CalendarPrefs copyWith({
    bool? showDeclined,
    int? dayStart,
    int? dayEnd,
    String? secondZone,
    bool noSecondZone = false,
    bool? datesInMail,
  }) {
    final start = dayStart ?? this.dayStart;
    final end = dayEnd ?? this.dayEnd;
    return CalendarPrefs(
      showDeclined: showDeclined ?? this.showDeclined,
      dayStart: start,
      // Never a day that ends before it starts: the other end gives way.
      dayEnd: end > start ? end : (start + 1).clamp(1, 24),
      secondZone: noSecondZone ? null : secondZone ?? this.secondZone,
      datesInMail: datesInMail ?? this.datesInMail,
    );
  }

  Map<String, Object?> toJson() => {
        'showDeclined': showDeclined,
        'dayStart': dayStart,
        'dayEnd': dayEnd,
        if (secondZone != null) 'secondZone': secondZone,
        'datesInMail': datesInMail,
      };

  /// What [toJson] wrote; anything missing or out of range is the default.
  factory CalendarPrefs.fromJson(Object? json) {
    if (json is! Map) return const CalendarPrefs();
    int hour(Object? v, int otherwise, int min, int max) =>
        v is int && v >= min && v <= max ? v : otherwise;
    final start = hour(json['dayStart'], 9, 0, 23);
    final end = hour(json['dayEnd'], 17, 1, 24);
    final zone = json['secondZone'];
    return CalendarPrefs(
      showDeclined: json['showDeclined'] == true,
      dayStart: end > start ? start : 9,
      dayEnd: end > start ? end : 17,
      secondZone: zone is String && zone.contains('/') ? zone : null,
      datesInMail: json['datesInMail'] != false,
    );
  }

  /// The prefs kept as text, or null for text that is not them.
  static CalendarPrefs? tryParse(String text) {
    try {
      final json = jsonDecode(text);
      return json is Map ? CalendarPrefs.fromJson(json) : null;
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarPrefs &&
      other.showDeclined == showDeclined &&
      other.dayStart == dayStart &&
      other.dayEnd == dayEnd &&
      other.secondZone == secondZone &&
      other.datesInMail == datesInMail;

  @override
  int get hashCode =>
      Object.hash(showDeclined, dayStart, dayEnd, secondZone, datesInMail);
}
