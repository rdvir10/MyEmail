import '../../domain/calendar_change.dart' show everyoneOn, isOwnEvent;
import '../../domain/calendar_event.dart';
import '../../domain/draft.dart';
import '../../domain/mail_message.dart' show MailAddress;
import '../compose/reply_draft.dart' show escapeHtml;

/// How late, as Outlook for Android offers it.
const lateBy = [5, 10, 15];

/// Who is told that [event] starts late for the account at [ownEmail]: its
/// organiser, or everyone on it when it is the account's own.
List<MailAddress> toldRunningLate(CalendarEvent event, String ownEmail) {
  if (isOwnEvent(event)) return everyoneOn(event, ownEmail);
  final organiser = event.organizer;
  if (organiser == null ||
      organiser.email.trim().toLowerCase() == ownEmail.trim().toLowerCase()) {
    return const [];
  }
  return [organiser];
}

/// The message saying [event] starts [minutes] late for the account at
/// [ownEmail], sent straight away from the meeting's sheet or its
/// reminder; null where there is nobody to tell.
Draft? runningLateDraft(
  CalendarEvent event, {
  required String ownEmail,
  required int minutes,
}) {
  final to = toldRunningLate(event, ownEmail);
  if (to.isEmpty) return null;
  final words = "I'm running about $minutes minutes late"
      "${isOwnEvent(event) ? '; please wait for me before we start' : ''}.";
  return Draft(
    accountId: event.accountId,
    kind: ComposeKind.newMessage,
    to: to,
    subject: 'Running late: ${event.title}',
    htmlBody: '<p>${escapeHtml(words)}</p>',
  );
}

/// The minutes in what was picked or typed into a reminder's Running
/// late: "10 min" is ten. The first of [lateBy] where it says none.
int lateMinutesIn(String? typed) {
  final m = RegExp(r'\d{1,3}').firstMatch(typed ?? '');
  final minutes = m == null ? null : int.tryParse(m[0]!);
  return minutes == null || minutes <= 0 ? lateBy.first : minutes;
}
