import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'account.dart';

/// How the calendar shows the day, chosen in Settings, Calendar, and
/// carried by the backup: whether meetings you declined still show, the
/// working day, where Day and Week open and outside which the hours are
/// shaded, a second clock down Day and Week's side, whether the dates in
/// mail are underlined, whose meetings MyEmail reminds you of, and when
/// the morning's agenda comes.
@immutable
class CalendarPrefs {
  const CalendarPrefs({
    this.showDeclined = false,
    this.dayStart = 9,
    this.dayEnd = 17,
    this.secondZone,
    this.datesInMail = true,
    this.meetingReminders = const {},
    this.agendaAt = defaultAgendaAt,
    this.deleteAnsweredInvites = true,
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

  /// MyEmail's own reminders before meetings, by account id, where one was
  /// switched; see [remindsFor] for the rest.
  final Map<String, bool> meetingReminders;

  /// When the morning's agenda comes on a working day, in minutes past
  /// midnight; null for never.
  final int? agendaAt;

  /// Half past seven.
  static const defaultAgendaAt = 7 * 60 + 30;

  /// An invitation answered, from its card or its notification, goes to
  /// Deleted Items, as Outlook's "Delete meeting request from Inbox when
  /// responding" sends it; the meeting stays on the calendar.
  final bool deleteAnsweredInvites;

  /// Whether MyEmail reminds before [account]'s meetings: as switched, or
  /// else for a Microsoft account whose calendar is not in the phone's own
  /// ([inPhoneCalendar]), where nothing else would. Google Calendar on the
  /// phone reminds of a Google account's meetings already.
  bool remindsFor(Account account, {bool inPhoneCalendar = false}) =>
      meetingReminders[account.id] ??
      (account.provider == MailProvider.outlook && !inPhoneCalendar);

  CalendarPrefs copyWith({
    bool? showDeclined,
    int? dayStart,
    int? dayEnd,
    String? secondZone,
    bool noSecondZone = false,
    bool? datesInMail,
    Map<String, bool>? meetingReminders,
    int? agendaAt,
    bool noAgenda = false,
    bool? deleteAnsweredInvites,
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
      meetingReminders: meetingReminders ?? this.meetingReminders,
      agendaAt: noAgenda ? null : agendaAt ?? this.agendaAt,
      deleteAnsweredInvites:
          deleteAnsweredInvites ?? this.deleteAnsweredInvites,
    );
  }

  Map<String, Object?> toJson() => {
        'showDeclined': showDeclined,
        'dayStart': dayStart,
        'dayEnd': dayEnd,
        if (secondZone != null) 'secondZone': secondZone,
        'datesInMail': datesInMail,
        if (meetingReminders.isNotEmpty) 'reminders': meetingReminders,
        'agenda': agendaAt ?? false,
        'deleteAnswered': deleteAnsweredInvites,
      };

  /// What [toJson] wrote; anything missing or out of range is the default.
  factory CalendarPrefs.fromJson(Object? json) {
    if (json is! Map) return const CalendarPrefs();
    int hour(Object? v, int otherwise, int min, int max) =>
        v is int && v >= min && v <= max ? v : otherwise;
    final start = hour(json['dayStart'], 9, 0, 23);
    final end = hour(json['dayEnd'], 17, 1, 24);
    final zone = json['secondZone'];
    final reminders = json['reminders'];
    final agenda = json['agenda'];
    return CalendarPrefs(
      showDeclined: json['showDeclined'] == true,
      dayStart: end > start ? start : 9,
      dayEnd: end > start ? end : 17,
      secondZone: zone is String && zone.contains('/') ? zone : null,
      datesInMail: json['datesInMail'] != false,
      meetingReminders: {
        if (reminders is Map)
          for (final MapEntry(:key, :value) in reminders.entries)
            if (key is String && value is bool) key: value,
      },
      agendaAt: agenda == false
          ? null
          : agenda is int && agenda >= 0 && agenda < 24 * 60
              ? agenda
              : defaultAgendaAt,
      deleteAnsweredInvites: json['deleteAnswered'] != false,
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
      other.datesInMail == datesInMail &&
      mapEquals(other.meetingReminders, meetingReminders) &&
      other.agendaAt == agendaAt &&
      other.deleteAnsweredInvites == deleteAnsweredInvites;

  @override
  int get hashCode => Object.hash(
        showDeclined,
        dayStart,
        dayEnd,
        secondZone,
        datesInMail,
        Object.hashAllUnordered([
          for (final MapEntry(:key, :value) in meetingReminders.entries)
            Object.hash(key, value),
        ]),
        agendaAt,
        deleteAnsweredInvites,
      );
}
