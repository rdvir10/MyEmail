import 'package:flutter/foundation.dart';

import 'free_busy.dart' show defaultWorkWeek;
import 'mail_message.dart';

/// Outlook's Follow Up choices, each a day the flag is due, or none.
enum FollowUpChoice {
  today('Today'),
  tomorrow('Tomorrow'),
  thisWeek('This week'),
  nextWeek('Next week'),
  noDate('No date');

  const FollowUpChoice(this.label);

  final String label;
}

/// The day [choice] makes a flag due, from [now], in a week worked on
/// [workWeek]: Outlook's own reading of them. This week is its last working
/// day (today, on a day off), next week the last working day of the next
/// run of them. Null for [FollowUpChoice.noDate].
DateTime? dueFor(
  FollowUpChoice choice,
  DateTime now, {
  Set<int> workWeek = defaultWorkWeek,
}) {
  final today = DateTime(now.year, now.month, now.day);
  DateTime day(int d) => DateTime(today.year, today.month, today.day + d);
  bool worked(DateTime d) => workWeek.contains(d.weekday);

  /// The last day of the run of working days that starts on [first].
  DateTime endOfRun(int first) {
    var d = first;
    while (d < first + 7 && worked(day(d + 1))) {
      d++;
    }
    return day(d);
  }

  switch (choice) {
    case FollowUpChoice.today:
      return today;
    case FollowUpChoice.tomorrow:
      return day(1);
    case FollowUpChoice.noDate:
      return null;
    case FollowUpChoice.thisWeek:
      if (workWeek.isEmpty || !worked(today)) return today;
      return endOfRun(0);
    case FollowUpChoice.nextWeek:
      if (workWeek.isEmpty) return day(7);
      var d = 0;
      // Past the rest of this run of working days, then the days off.
      while (d < 7 && worked(day(d))) {
        d++;
      }
      while (d < 14 && !worked(day(d))) {
        d++;
      }
      return endOfRun(d);
  }
}

/// How a due day reads beside a message: "Due today", "Due tomorrow",
/// "Overdue", or the day.
String dueLabel(DateTime due, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(due.year, due.month, due.day);
  final days = day.difference(today).inHours / 24;
  if (days < -0.5) return 'Overdue';
  if (days < 0.5) return 'Due today';
  if (days < 1.5) return 'Due tomorrow';
  return 'Due ${shortDay(day)}';
}

/// "Fri 30 Oct".
String shortDay(DateTime d) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
}

/// A follow-up as this device keeps it: the due day where the account
/// cannot keep one (Gmail has no dates), the reminder whatever the account,
/// and enough of the message to say what the reminder is about and open it.
///
/// Keyed by [followUpKey], the account and the message's own Message-ID, so
/// it survives the message being moved.
@immutable
class FollowUpRecord {
  const FollowUpRecord({
    required this.accountId,
    required this.messageId,
    required this.subject,
    required this.sender,
    this.due,
    this.remindAt,
  });

  final String accountId;

  /// The message's id in the app when the follow-up was set, which a tap on
  /// the reminder opens.
  final String messageId;
  final String subject;
  final String sender;
  final DateTime? due;
  final DateTime? remindAt;

  FollowUpRecord copyWith({
    Object? due = _keep,
    Object? remindAt = _keep,
    String? messageId,
  }) =>
      FollowUpRecord(
        accountId: accountId,
        messageId: messageId ?? this.messageId,
        subject: subject,
        sender: sender,
        due: identical(due, _keep) ? this.due : due as DateTime?,
        remindAt:
            identical(remindAt, _keep) ? this.remindAt : remindAt as DateTime?,
      );

  Map<String, Object?> toJson() => {
        'accountId': accountId,
        'messageId': messageId,
        'subject': subject,
        'sender': sender,
        if (due != null) 'due': due!.toIso8601String(),
        if (remindAt != null) 'remindAt': remindAt!.toUtc().toIso8601String(),
      };

  static FollowUpRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final accountId = json['accountId'], messageId = json['messageId'];
    if (accountId is! String || messageId is! String) return null;
    DateTime? at(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return FollowUpRecord(
      accountId: accountId,
      messageId: messageId,
      subject: json['subject'] is String ? json['subject'] as String : '',
      sender: json['sender'] is String ? json['sender'] as String : '',
      due: at(json['due']),
      remindAt: at(json['remindAt'])?.toLocal(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FollowUpRecord &&
      other.accountId == accountId &&
      other.messageId == messageId &&
      other.subject == subject &&
      other.sender == sender &&
      other.due == due &&
      other.remindAt == remindAt;

  @override
  int get hashCode =>
      Object.hash(accountId, messageId, subject, sender, due, remindAt);
}

const _keep = Object();

/// Where a message's follow-up is kept: its account and its own
/// Message-ID, or its id in the app where it has none.
String followUpKey(MailMessage m) => '${m.accountId}|${m.messageId ?? m.id}';

/// The notification id of [key]'s reminder: one of its own, apart from the
/// new-mail notifications' ids, which are a message id's hash.
int reminderIdFor(String key) => 0x40000000 | (key.hashCode & 0x3fffffff);
