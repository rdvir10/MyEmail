import 'package:flutter/foundation.dart';

import 'mail_message.dart';

/// A meeting being set up: what goes on the calendar, and who is asked.
///
/// The account's own calendar keeps the event and sends the invitations, so
/// nothing here outlives the screen's Send: the server collects the answers
/// and every client the account has shows them on the event. What is here
/// is what the person typed, on the device's own clock.
@immutable
class MeetingDraft {
  const MeetingDraft({
    required this.accountId,
    required this.title,
    this.attendees = const [],
    required this.start,
    required this.end,
    this.allDay = false,
    this.location = '',
    this.notes = '',
    this.timeZone,
    this.online,
    this.prepared,
  });

  /// Whose calendar it goes on, and who the invitations come from.
  final String accountId;

  final String title;

  /// Everyone invited. Empty is allowed: the event still goes on the
  /// calendar, with nobody to tell.
  final List<MailAddress> attendees;

  /// On the device's clock. For a whole day, [start] is the first day and
  /// [end] the last, both at midnight, so a meeting on one day has the two
  /// equal; a calendar that wants the day after is given it on the wire.
  final DateTime start;
  final DateTime end;
  final bool allDay;

  final String location;

  /// Plain text. The calendars take it as the event's body.
  final String notes;

  /// The device's zone by its IANA name, "Asia/Jerusalem": what the times
  /// are in, and what a calendar server is told beside them. Null where the
  /// device would not say; the times then go as UTC, which every calendar
  /// reads and shows on its own clock the same.
  final String? timeZone;

  /// Held online as well, with a link to join it, of this kind: Teams or
  /// Google Meet, one of those the screen offered for the account (see
  /// `MailEngine.onlineMeetingsFor`). Null for a meeting held in the room
  /// alone. The account's own calendar makes the link where it can; Google
  /// Meet on a Microsoft account is made by a Gmail account signed in with
  /// Google, and the Outlook invitation carries it.
  final OnlineMeetingKind? online;

  bool get isOnline => online != null;

  /// The online meeting made while the screen was open, whose invite text
  /// the screen showed: the invitation goes out with that one rather than
  /// with one made at Send. Used only where it is this account's and of
  /// the kind [online] asks for; otherwise Send makes its own, as it did
  /// before there was any.
  final PreparedMeeting? prepared;

  /// [prepared], where it belongs to this meeting as it stands.
  PreparedMeeting? get preparedHere => prepared != null &&
          prepared!.accountId == accountId &&
          prepared!.kind == online
      ? prepared
      : null;

  bool get hasAttendees => attendees.isNotEmpty;

  /// This meeting as the event made ahead of Send ([PreparedMeeting]):
  /// nobody on it and no notes, since it is not being sent, a title before
  /// one is typed, and an end after its start, since a calendar refuses
  /// any other. Send gives the event everything as it then stands. No
  /// location either: one typed now and cleared before Send would stay on
  /// a Teams event, where Send leaves an empty location out so that
  /// Exchange's own ("Microsoft Teams Meeting") stands.
  MeetingDraft get shell {
    final ends = allDay ? !end.isBefore(start) : end.isAfter(start);
    return MeetingDraft(
      accountId: accountId,
      title: title.trim().isEmpty ? 'New meeting' : title,
      start: start,
      end: ends ? end : (allDay ? start : start.add(const Duration(hours: 1))),
      allDay: allDay,
      timeZone: timeZone,
      online: online,
    );
  }

  /// What stops this being created, as a sentence, or null when nothing
  /// does.
  String? get problem {
    if (title.trim().isEmpty) return 'Give the meeting a title.';
    if (allDay) {
      if (end.isBefore(start)) return 'The last day cannot be before the first.';
    } else if (!end.isAfter(start)) {
      return 'The meeting has to end after it starts.';
    }
    return null;
  }

  bool get isValid => problem == null;

  /// The times a calendar server is told, and the zone they are in: on the
  /// device's clock where it named its zone, in UTC otherwise. A whole day
  /// is dates, which no zone moves, so those stay as they are.
  ({DateTime start, DateTime end, String timeZone}) get asSent =>
      timeZone == null && !allDay
          ? (start: start.toUtc(), end: end.toUtc(), timeZone: 'UTC')
          : (start: start, end: end, timeZone: timeZone ?? 'UTC');
}

/// Where a meeting is held online, which is what the screen's switch is
/// labelled with, or its menu lists where there is a choice.
enum OnlineMeetingKind {
  teams('Teams meeting', 'a Teams link'),
  skype('Skype meeting', 'a Skype link'),
  googleMeet('Google Meet', 'a Google Meet link'),
  other('Online meeting', 'an online meeting link');

  const OnlineMeetingKind(this.label, this.link);

  /// The switch's label.
  final String label;

  /// What went out with the invitation, for the message that says so.
  final String link;
}

/// An online meeting made before anyone is invited, so the text its
/// invitation will carry can be shown while the meeting is written: Ron
/// asked for the Teams block in the notes, as Outlook puts it there.
///
/// For Teams and for a Gmail account's own Meet, the meeting is the event
/// itself, on the account's calendar with nobody on it, so nobody is told
/// anything; Send gives it its details and then its attendees, and adding
/// them is what sends the invitations. For Meet on a Microsoft account it
/// is only a link, with no event anywhere.
@immutable
class PreparedMeeting {
  const PreparedMeeting({
    required this.accountId,
    required this.kind,
    this.eventId,
    required this.joinUrl,
    required this.inviteText,
    this.bodyHtml,
  });

  /// Whose calendar it is on.
  final String accountId;

  final OnlineMeetingKind kind;

  /// The event with nobody on it, or null where there is none to undo: a
  /// Meet link made for a Microsoft account.
  final String? eventId;

  /// Where to join.
  final String joinUrl;

  /// What the invitation says about joining, as plain text for the screen.
  final String inviteText;

  /// Microsoft's: the event's body as Exchange wrote it, Teams block and
  /// all. The invitation carries it unchanged below the notes: a body sent
  /// without the block, or with it rewritten, loses the meeting.
  final String? bodyHtml;

  /// What is kept to find it again after the app was closed with it still
  /// made: enough to delete it, and nothing of what it said.
  Map<String, Object?> toJson() => {
        'accountId': accountId,
        'kind': kind.name,
        'eventId': ?eventId,
        'joinUrl': joinUrl,
      };

  /// Null for anything not written by [toJson].
  static PreparedMeeting? fromJson(Object? json) {
    if (json is! Map) return null;
    final accountId = json['accountId'];
    final kind = OnlineMeetingKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    final eventId = json['eventId'];
    final joinUrl = json['joinUrl'];
    if (accountId is! String || kind == null || joinUrl is! String) {
      return null;
    }
    return PreparedMeeting(
      accountId: accountId,
      kind: kind,
      eventId: eventId is String ? eventId : null,
      joinUrl: joinUrl,
      inviteText: '',
    );
  }
}

/// What creating a meeting left behind.
@immutable
class CreatedMeeting {
  const CreatedMeeting({this.id, this.joinUrl});

  /// The event's id on the calendar, or null where the calendar did not
  /// say.
  final String? id;

  /// Where to join it online, when it was held online and the calendar
  /// said where. Null otherwise.
  final String? joinUrl;
}

/// The day after [day]'s date, at midnight: where a whole-day event ends
/// on every calendar's wire, which count the end as exclusive.
///
/// Built from the parts rather than by adding a day, which adds 24 hours
/// and lands at 23:00 or 01:00 on the day the clocks change.
DateTime dayAfter(DateTime day) => day.isUtc
    ? DateTime.utc(day.year, day.month, day.day + 1)
    : DateTime(day.year, day.month, day.day + 1);
