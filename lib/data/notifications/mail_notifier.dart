import 'package:flutter/foundation.dart';

import '../../domain/account.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';

/// One notification, already reduced to what a notification can show.
@immutable
class MailNotification {
  const MailNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
    required this.when,
  });

  /// Stable for a given message, so a message that is still unread on the next
  /// pass updates its notification instead of posting a second one.
  final int id;

  /// Who it is from. The sender's name where there is one, their address
  /// otherwise; the subject goes in the body, as every mail app does it.
  final String title;
  final String body;

  /// The message id, so tapping the notification can open that message.
  final String payload;

  final DateTime when;

  /// Android notification ids are 32-bit signed and there is no id registry to
  /// allocate from, so the message id is hashed into that space. A collision
  /// means one notification replaces another rather than anything worse, and
  /// two unread messages colliding inside one mailbox is not a case worth
  /// carrying a registry for.
  static int idForMessage(String messageId) => messageId.hashCode & 0x7fffffff;

  factory MailNotification.forMessage(MailMessage message) {
    final subject = message.subject.trim();
    final preview = message.preview.trim();
    return MailNotification(
      id: idForMessage(message.id),
      title: message.from.display,
      body: [
        if (subject.isEmpty) '(No subject)' else subject,
        if (preview.isNotEmpty) preview,
      ].join('\n'),
      payload: message.id,
      when: message.date,
    );
  }
}

/// Posting new-mail notifications, behind an interface so the background pass
/// can be tested without a platform channel.
abstract class MailNotifier {
  /// Create the channel and ask for permission if it has not been granted.
  /// Safe to call more than once.
  Future<void> ensureReady();

  /// Ask the user for notification permission, returning whether it is now
  /// granted. Android 13 and later refuse to show anything without it.
  Future<bool> requestPermission();

  /// Whether notifications are permitted at the OS level. A user who turned
  /// them off in Android settings has overruled the in-app switch, and the
  /// settings screen has to say so rather than claim the feature is on.
  Future<bool> isPermitted();

  /// Post one batch: the messages, plus a summary row that groups them under
  /// the account they arrived in.
  Future<void> showNewMail({
    required Account account,
    required MailFolder folder,
    required List<MailNotification> notifications,
  });

  Future<void> cancelAll();

  /// The message id a notification tap launched the app with, if any. Consumed
  /// once: asking twice returns null, so a rebuild does not reopen it.
  Future<String?> takeLaunchPayload();
}

/// Records instead of posting. Used by the tests and by the browser preview,
/// which has no notifications at all.
class FakeMailNotifier implements MailNotifier {
  FakeMailNotifier({this.permitted = true});

  bool permitted;
  int readyCalls = 0;
  final List<({Account account, MailFolder folder, List<MailNotification> notifications})>
      batches = [];

  List<MailNotification> get posted =>
      [for (final b in batches) ...b.notifications];

  @override
  Future<void> ensureReady() async => readyCalls++;

  @override
  Future<bool> requestPermission() async => permitted;

  @override
  Future<bool> isPermitted() async => permitted;

  @override
  Future<void> showNewMail({
    required Account account,
    required MailFolder folder,
    required List<MailNotification> notifications,
  }) async {
    batches.add((account: account, folder: folder, notifications: notifications));
  }

  @override
  Future<void> cancelAll() async => batches.clear();

  @override
  Future<String?> takeLaunchPayload() async => null;
}
