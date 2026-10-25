import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:home_widget/home_widget.dart';

import '../../domain/meeting_alerts.dart' show MeetingRef;

/// Tapping a widget opens the folder it was counting, or for the calendar
/// widget, the meeting tapped or the calendar.
///
/// The widget hands over a `myemail://folder?id=…` link, or
/// `myemail://event?…` and `myemail://calendar`, which arrives one of two
/// ways: on the intent that started the app, or — if the app was already
/// running — through the plugin's stream. Both are needed, and they are the
/// same answer, so callers take one callback and get it from wherever it
/// turns up.

/// The folder a link names, or null if it is not one of ours.
String? folderFromWidgetLink(Uri? uri) {
  if (uri == null) return null;
  if (uri.scheme != 'myemail' || uri.host != 'folder') return null;
  final id = uri.queryParameters['id'];
  if (id == null || id.isEmpty) return null;
  return id;
}

/// What a calendar widget's link opens: the calendar on [day], with
/// [meeting]'s sheet where a meeting was tapped.
typedef CalendarLink = ({DateTime day, MeetingRef? meeting});

/// The calendar a link names, or null if it is not one of the calendar
/// widget's.
CalendarLink? calendarFromWidgetLink(Uri? uri, {DateTime? now}) {
  if (uri == null || uri.scheme != 'myemail') return null;
  final today = now ?? DateTime.now();
  if (uri.host == 'calendar') {
    return (day: DateTime(today.year, today.month, today.day), meeting: null);
  }
  if (uri.host != 'event') return null;
  final q = uri.queryParameters;
  final account = q['account'], id = q['id'];
  final start = int.tryParse(q['start'] ?? '');
  if (account == null || account.isEmpty || id == null || id.isEmpty) {
    return null;
  }
  if (start == null) return null;
  final at = DateTime.fromMillisecondsSinceEpoch(start);
  final end = int.tryParse(q['end'] ?? '');
  return (
    day: DateTime(at.year, at.month, at.day),
    meeting: MeetingRef(
      accountId: account,
      eventId: id,
      calendarId: q['calendar'] ?? '',
      start: at,
      end: end == null ? at : DateTime.fromMillisecondsSinceEpoch(end),
    ),
  );
}

/// The link the app was opened with, if it was opened by tapping a widget.
Future<Uri?> widgetLinkAppOpenedOn() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return await HomeWidget.initiallyLaunchedFromHomeWidget();
  } catch (e) {
    debugPrint('[myemail] could not read the widget link: $e');
    return null;
  }
}

/// The folder the app was opened on, if it was opened by tapping a widget.
Future<String?> folderAppOpenedOn() async =>
    folderFromWidgetLink(await widgetLinkAppOpenedOn());

/// Later taps, while the app is already open.
StreamSubscription<Uri?>? listenForWidgetTaps(
  void Function(String folderId) onFolder, {
  void Function(CalendarLink link)? onCalendar,
}) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return HomeWidget.widgetClicked.listen((uri) {
      final folderId = folderFromWidgetLink(uri);
      if (folderId != null) onFolder(folderId);
      final calendar = calendarFromWidgetLink(uri);
      if (calendar != null) onCalendar?.call(calendar);
    });
  } catch (e) {
    debugPrint('[myemail] could not listen for widget taps: $e');
    return null;
  }
}
