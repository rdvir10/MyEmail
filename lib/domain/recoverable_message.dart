import 'package:flutter/foundation.dart';

import 'mail_message.dart';

/// A message emptied out of Deleted Items, which Exchange keeps out of
/// sight for a few weeks (two unless the organisation chose otherwise):
/// what Outlook's Recover Deleted Items lists.
@immutable
class RecoverableMessage {
  const RecoverableMessage({
    required this.id,
    required this.subject,
    required this.from,
    required this.received,
    this.deletedOn,
    this.preview = '',
    this.hasAttachments = false,
  });

  /// The server's id for it where it is kept: only for putting it back.
  final String id;
  final String subject;
  final MailAddress from;
  final DateTime received;

  /// When it left Deleted Items, where the server says.
  final DateTime? deletedOn;
  final String preview;
  final bool hasAttachments;

  @override
  bool operator ==(Object other) =>
      other is RecoverableMessage && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'RecoverableMessage($id, "$subject")';
}
