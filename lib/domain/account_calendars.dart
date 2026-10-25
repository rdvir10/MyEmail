import 'package:flutter/foundation.dart';

import 'calendar_event.dart';

/// One of an account's calendars: its main one, one made beside it, or one
/// it follows, Google's holidays and birthdays. Outlook's My Calendars and
/// Google's calendar list, as Calendars shown lists them.
@immutable
class CalendarInfo {
  const CalendarInfo({
    required this.accountId,
    required this.id,
    required this.name,
    this.colour,
    this.canEdit = true,
  });

  /// The account's main calendar, before its others are known.
  const CalendarInfo.main(this.accountId)
      : id = CalendarEvent.mainCalendar,
        name = 'Calendar',
        colour = null,
        canEdit = true;

  final String accountId;

  /// [CalendarEvent.mainCalendar] for the main one, the calendar's own id
  /// for the rest.
  final String id;
  final String name;

  /// ARGB, as the calendar shows it; null for the account's own colour.
  /// The main calendar is always the account's.
  final int? colour;

  /// Whether meetings can be made, answered and changed on it: false for
  /// one the account only reads.
  final bool canEdit;

  bool get isMain => id == CalendarEvent.mainCalendar;

  /// Its key in Calendars shown: see [calendarKey].
  String get key => calendarKey(accountId, id);

  Map<String, Object?> toJson() => {
        'accountId': accountId,
        'id': id,
        'name': name,
        if (colour != null) 'colour': colour,
        if (!canEdit) 'canEdit': false,
      };

  static CalendarInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final accountId = json['accountId'], id = json['id'], name = json['name'];
    if (accountId is! String || id is! String || name is! String) return null;
    final colour = json['colour'];
    return CalendarInfo(
      accountId: accountId,
      id: id,
      name: name,
      colour: colour is int ? colour : null,
      canEdit: json['canEdit'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarInfo &&
      other.accountId == accountId &&
      other.id == id &&
      other.name == name &&
      other.colour == colour &&
      other.canEdit == canEdit;

  @override
  int get hashCode => Object.hash(accountId, id, name, colour, canEdit);

  @override
  String toString() => 'CalendarInfo($accountId, $name)';
}

/// One calendar of one account in Calendars shown, left out when its key is
/// among the hidden. An account's id alone stands for all of its
/// calendars, as it did before there were more than one.
String calendarKey(String accountId, String calendarId) =>
    '$accountId|$calendarId';

/// [CalendarEvent]'s calendar, by [calendarKey].
String calendarKeyOf(CalendarEvent event) =>
    calendarKey(event.accountId, event.calendarId);

/// Whether [event] is shown, with [hidden] the keys of what is not: its
/// account, or its own calendar.
bool calendarShown(CalendarEvent event, Set<String> hidden) =>
    !hidden.contains(event.accountId) && !hidden.contains(calendarKeyOf(event));

/// The colour [event] is drawn in, ARGB: its own (a category, or one picked
/// for it), else its calendar's, else its account's, [accountColour].
int eventColour(
  CalendarEvent event,
  int accountColour, {
  Map<String, CalendarInfo> calendars = const {},
}) =>
    event.colour ?? calendars[calendarKeyOf(event)]?.colour ?? accountColour;

/// A colour written "#rrggbb", as Google and Outlook give one, as ARGB.
int? colourFromHex(Object? hex) {
  if (hex is! String) return null;
  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(hex.trim());
  return m == null ? null : 0xFF000000 | int.parse(m[1]!, radix: 16);
}

/// Google Calendar's event colours, by the colorId an event carries: the
/// eleven its colour picker offers, Lavender to Tomato.
const googleEventColours = {
  '1': 0xFF7986CB,
  '2': 0xFF33B679,
  '3': 0xFF8E24AA,
  '4': 0xFFE67C73,
  '5': 0xFFF6BF26,
  '6': 0xFFF4511E,
  '7': 0xFF039BE5,
  '8': 0xFF616161,
  '9': 0xFF3F51B5,
  '10': 0xFF0B8043,
  '11': 0xFFD50000,
};

/// Outlook's category colours, by the preset a category names: Red,
/// Orange, Brown, Yellow, Green, Teal, Olive, Blue, Purple, Cranberry,
/// Steel, Dark steel, Gray, Dark gray, Black, then the dark ones.
const outlookCategoryColours = {
  'preset0': 0xFFE74856,
  'preset1': 0xFFFF8C00,
  'preset2': 0xFFAB8F72,
  'preset3': 0xFFFFB900,
  'preset4': 0xFF13A10E,
  'preset5': 0xFF00B7C3,
  'preset6': 0xFF7F8B52,
  'preset7': 0xFF0078D4,
  'preset8': 0xFF8764B8,
  'preset9': 0xFFC30052,
  'preset10': 0xFF69797E,
  'preset11': 0xFF4A5459,
  'preset12': 0xFF8A8886,
  'preset13': 0xFF484644,
  'preset14': 0xFF1B1A19,
  'preset15': 0xFFA4262C,
  'preset16': 0xFFCA5010,
  'preset17': 0xFF8E562E,
  'preset18': 0xFFC19C00,
  'preset19': 0xFF0B6A0B,
  'preset20': 0xFF005B70,
  'preset21': 0xFF5C6B2E,
  'preset22': 0xFF004E8C,
  'preset23': 0xFF5C2E91,
  'preset24': 0xFF750B1C,
};

/// Outlook's own calendar colours, where a calendar gives a name for its
/// colour and no hex: "auto" is none, the account's.
const outlookCalendarColours = {
  'lightBlue': 0xFF5DA9E9,
  'lightGreen': 0xFF5CB85C,
  'lightOrange': 0xFFF0A04B,
  'lightGray': 0xFF9E9E9E,
  'lightYellow': 0xFFE6C229,
  'lightTeal': 0xFF3BB9B0,
  'lightPink': 0xFFE57AB3,
  'lightBrown': 0xFFB08A6A,
  'lightRed': 0xFFE5605E,
};
