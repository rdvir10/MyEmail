import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calendar/device_calendar.dart';
import '../domain/calendar_invite.dart';
import '../domain/calendar_meeting.dart';
import 'message_providers.dart';
import 'providers.dart';

/// The device's calendar. main() overrides this on Android; tests and the
/// browser preview record instead.
final deviceCalendarProvider =
    Provider<DeviceCalendar>((ref) => FakeDeviceCalendar(supported: false));

final calendarAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(deviceCalendarProvider).available(),
);

/// How each invitation was answered this session, by message id, so the
/// card says "You accepted" after the reply has gone rather than offering
/// the three buttons again. In memory: the organizer's calendar is the
/// record, and the next sync shows the message the way the server has it.
class InviteResponses extends Notifier<Map<String, InviteResponse>> {
  @override
  Map<String, InviteResponse> build() => const {};

  void record(String messageId, InviteResponse response) =>
      state = {...state, messageId: response};
}

final inviteResponsesProvider =
    NotifierProvider<InviteResponses, Map<String, InviteResponse>>(
  InviteResponses.new,
);

/// The meeting a message is about, as its account's calendar has it now, by
/// message id; null where it is not on it. See `MailEngine.meetingOnCalendar`
/// for what it throws.
///
/// Read again each time the message is opened, never kept: the calendar is
/// the record, and Outlook and the server change it as well as this app.
/// Only for the mail that has something to check: an invitation (moved or
/// cancelled since?), a cancellation (still there?) and a new time proposed
/// (where is it now?).
///
/// A failure is said at once and never retried by itself: Riverpod would
/// otherwise ask ten times over half a minute, the card saying "Checking"
/// throughout, for a calendar that is not there or a phone that is offline.
/// The card offers Try again where trying again can help.
final meetingOnCalendarProvider =
    FutureProvider.autoDispose.family<CalendarMeeting?, String>(
  (ref, messageId) async {
    final invite = ref.watch(messageInviteProvider(messageId));
    if (invite == null ||
        !(invite.isRequest || invite.isCancellation || invite.isCounter)) {
      return null;
    }
    return ref.watch(mailEngineProvider).meetingOnCalendar(messageId, invite);
  },
  retry: (_, _) => null,
);

/// What the card under a meeting message did this session.
enum MeetingAction {
  /// Took a cancelled meeting off the calendar.
  removed,

  /// Moved the meeting to the time proposed.
  moved,

  /// Told the proposer the meeting stays as it is.
  proposalDeclined,
}

/// What was done to the meeting each message is about this session, by
/// message id, so the card says so rather than offering it again. In
/// memory, as [InviteResponses] is: the calendar is the record.
class MeetingActions extends Notifier<Map<String, MeetingAction>> {
  @override
  Map<String, MeetingAction> build() => const {};

  void record(String messageId, MeetingAction action) =>
      state = {...state, messageId: action};
}

final meetingActionsProvider =
    NotifierProvider<MeetingActions, Map<String, MeetingAction>>(
  MeetingActions.new,
);
