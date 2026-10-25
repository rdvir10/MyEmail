import 'package:flutter/material.dart';

import '../../domain/account_calendars.dart';
import '../../domain/calendar_event.dart';

/// The colour each event is drawn in, as the calendar views draw it: its
/// own (an Outlook category, or one picked in Google Calendar), else its
/// calendar's, else its account's.
@immutable
class EventColours {
  const EventColours({this.accounts = const {}, this.calendars = const {}});

  /// Each account's colour, by id.
  final Map<String, Color> accounts;

  /// Each calendar, by [calendarKey], with the colour it shows in.
  final Map<String, CalendarInfo> calendars;

  /// [event]'s colour, or null where neither it, its calendar nor its
  /// account has one: the theme's then.
  Color? operator [](CalendarEvent event) {
    final own = event.colour ?? calendars[calendarKeyOf(event)]?.colour;
    return own != null ? Color(own) : accounts[event.accountId];
  }

  /// The account's colour, as a thin edge beside an event drawn in a
  /// colour of its own; null where the event is in its account's.
  Color? edgeOf(CalendarEvent event) {
    final account = accounts[event.accountId];
    final drawn = this[event];
    return account == null || drawn == account ? null : account;
  }
}
