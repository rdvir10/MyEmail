import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calendar/device_calendar.dart';
import '../domain/calendar_invite.dart';

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
