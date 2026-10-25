import 'package:flutter/foundation.dart';

/// Who an automatic reply goes to: Outlook's choice for people outside the
/// organisation, and Gmail's two restrictions.
enum ReplyAudience {
  /// Inside the organisation only: Outlook's outside replies off, Gmail's
  /// "only to people in my organisation" (Google Workspace alone).
  insideOnly,

  /// Outside, only to the account's contacts.
  contacts,

  /// Everyone who writes.
  everyone,
}

/// Automatic replies as the server keeps them: Outlook's Automatic Replies,
/// Gmail's vacation responder. Both answer mail on the server, with the
/// phone off.
@immutable
class AutoReply {
  const AutoReply({
    this.on = false,
    this.start,
    this.end,
    this.message = '',
    this.outsideMessage = '',
    this.audience = ReplyAudience.everyone,
    this.subject = '',
  });

  final bool on;

  /// Only between these, where both are set; always while [on] otherwise.
  final DateTime? start;
  final DateTime? end;

  /// What the reply says, as text: to everyone on Gmail, and inside the
  /// organisation on Microsoft.
  final String message;

  /// Microsoft only: what it says to people outside the organisation,
  /// where that is to differ. Empty for the same as [message].
  final String outsideMessage;
  final ReplyAudience audience;

  /// Gmail only: the reply's subject. Empty for "Re:" and theirs.
  final String subject;

  bool get scheduled => start != null && end != null;

  AutoReply copyWith({
    bool? on,
    Object? start = _keep,
    Object? end = _keep,
    String? message,
    String? outsideMessage,
    ReplyAudience? audience,
    String? subject,
  }) =>
      AutoReply(
        on: on ?? this.on,
        start: identical(start, _keep) ? this.start : start as DateTime?,
        end: identical(end, _keep) ? this.end : end as DateTime?,
        message: message ?? this.message,
        outsideMessage: outsideMessage ?? this.outsideMessage,
        audience: audience ?? this.audience,
        subject: subject ?? this.subject,
      );

  @override
  bool operator ==(Object other) =>
      other is AutoReply &&
      other.on == on &&
      other.start == start &&
      other.end == end &&
      other.message == message &&
      other.outsideMessage == outsideMessage &&
      other.audience == audience &&
      other.subject == subject;

  @override
  int get hashCode =>
      Object.hash(on, start, end, message, outsideMessage, audience, subject);
}

/// A rule the server runs on mail as it arrives: Outlook's Inbox rules and
/// Gmail's filters, as far as the two agree. When it is from someone, or
/// its subject has some words, move it to a folder, mark it read, or delete
/// it. The server runs it with the phone off, and Outlook on the PC shows it.
@immutable
class MailRule {
  const MailRule({
    this.id,
    this.name = '',
    this.enabled = true,
    this.from = const [],
    this.subjectContains = const [],
    this.moveTo,
    this.markRead = false,
    this.delete = false,
    this.partly = false,
  });

  /// The server's, once it has made it.
  final String? id;

  /// Outlook's name for it. Gmail's filters have none: empty there.
  final String name;

  /// Gmail's filters cannot be turned off; theirs are always on.
  final bool enabled;

  /// Addresses, or parts of them: any of these.
  final List<String> from;

  /// Words, any of which in the subject.
  final List<String> subjectContains;

  /// The folder it moves mail to, by path.
  final String? moveTo;
  final bool markRead;
  final bool delete;

  /// The server's rule does more than this says: conditions, exceptions or
  /// actions only Outlook or Gmail on the web can show. Read here, never
  /// made here.
  final bool partly;

  /// Something to match and something to do.
  bool get isValid =>
      (from.isNotEmpty || subjectContains.isNotEmpty) &&
      (moveTo != null || markRead || delete);

  /// Its name, or what it does where it has none.
  String get title => name.trim().isEmpty ? summary : name.trim();

  MailRule copyWith({String? id, bool? enabled}) => MailRule(
        id: id ?? this.id,
        name: name,
        enabled: enabled ?? this.enabled,
        from: from,
        subjectContains: subjectContains,
        moveTo: moveTo,
        markRead: markRead,
        delete: delete,
        partly: partly,
      );

  /// "From dana@example.com: move to Receipts, mark read".
  String get summary {
    final when = [
      if (from.isNotEmpty) 'From ${from.join(' or ')}',
      if (subjectContains.isNotEmpty)
        '${from.isEmpty ? 'S' : 's'}ubject has '
            '${subjectContains.map((w) => '"$w"').join(' or ')}',
    ].join(', ');
    final what = [
      if (delete) 'delete',
      if (moveTo != null && !delete) 'move to ${moveTo!.split('/').last}',
      if (markRead) 'mark read',
    ].join(', ');
    return '${when.isEmpty ? 'All mail' : when}: '
        '${what.isEmpty ? 'nothing this app can show' : what}';
  }

  @override
  bool operator ==(Object other) =>
      other is MailRule &&
      other.id == id &&
      other.name == name &&
      other.enabled == enabled &&
      listEquals(other.from, from) &&
      listEquals(other.subjectContains, subjectContains) &&
      other.moveTo == moveTo &&
      other.markRead == markRead &&
      other.delete == delete &&
      other.partly == partly;

  @override
  int get hashCode => Object.hash(id, name, enabled, Object.hashAll(from),
      Object.hashAll(subjectContains), moveTo, markRead, delete, partly);

  @override
  String toString() => 'MailRule($id, $title)';
}

const _keep = Object();
