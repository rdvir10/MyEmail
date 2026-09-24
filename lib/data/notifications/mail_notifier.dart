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

  /// Stable for a given message. Android knows a notification by this and
  /// the message id together (see [MailNotifier.withdraw]), which is how one
  /// message's notification is found again to be taken down.
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

  /// The messages that have a new-mail notification showing, by message id.
  Future<Set<String>> shownMessageIds();

  /// Take down the new-mail notifications of the messages [which] picks out:
  /// read, moved or deleted since they were announced. Left up, their
  /// buttons act on mail that is no longer there, and Delete says it failed.
  /// An account's summary row goes too once nothing is left under it.
  ///
  /// Never throws. A notification that could not be taken down is not a
  /// reason for the delete that prompted it to fail.
  Future<void> withdraw(bool Function(String messageId) which);

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

  /// How many times Android's permission dialog would have been shown.
  int permissionRequests = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permitted;
  }

  @override
  Future<bool> isPermitted() async => permitted;

  @override
  Future<void> showNewMail({
    required Account account,
    required MailFolder folder,
    required List<MailNotification> notifications,
  }) async {
    batches.add((account: account, folder: folder, notifications: notifications));
    withdrawn.removeAll([for (final n in notifications) n.payload]);
  }

  /// The messages whose notifications have been taken down.
  final Set<String> withdrawn = {};

  @override
  Future<Set<String>> shownMessageIds() async =>
      {for (final n in posted) n.payload}.difference(withdrawn);

  @override
  Future<void> withdraw(bool Function(String messageId) which) async =>
      withdrawn.addAll((await shownMessageIds()).where(which));

  /// How many times everything showing was taken down.
  int cancelAllCalls = 0;

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    batches.clear();
  }

  /// What a tapped notification carried. Set by a test; read once.
  String? launchPayload;

  @override
  Future<String?> takeLaunchPayload() async {
    final payload = launchPayload;
    launchPayload = null;
    return payload;
  }
}
