import 'package:flutter/foundation.dart';

/// What Exchange says about one recipient before a message goes: Outlook's
/// MailTips. That they are away (with the start of their automatic reply),
/// that they are outside the organisation, that a list will reach many
/// people, that a mailbox is full or will not take mail from here.
@immutable
class MailTip {
  const MailTip({
    required this.email,
    this.autoReply,
    this.external = false,
    this.memberCount,
    this.mailboxFull = false,
    this.restricted = false,
  });

  final String email;

  /// The start of their automatic reply, as words, while one is on.
  final String? autoReply;

  /// Outside the sending account's organisation.
  final bool external;

  /// How many people a list reaches, where it is one.
  final int? memberCount;
  final bool mailboxFull;

  /// The recipient takes no mail from this sender.
  final bool restricted;

  /// Whether there is anything to say.
  bool get isEmpty =>
      autoReply == null &&
      !external &&
      (memberCount == null || memberCount! < largeList) &&
      !mailboxFull &&
      !restricted;

  /// Past this many, a list is worth a word before sending, as Outlook's
  /// large-audience tip.
  static const largeList = 25;

  /// What the line under To says, for [name] (their name, or address).
  List<String> linesFor(String name) => [
        if (autoReply != null) '$name has an automatic reply on: "$autoReply"',
        if (restricted) "$name doesn't take mail from you.",
        if (mailboxFull) "$name's mailbox is full.",
        if (memberCount != null && memberCount! >= largeList)
          '$name is a list of $memberCount people.',
        if (external) '$name is outside your organisation.',
      ];

  @override
  bool operator ==(Object other) =>
      other is MailTip &&
      other.email == email &&
      other.autoReply == autoReply &&
      other.external == external &&
      other.memberCount == memberCount &&
      other.mailboxFull == mailboxFull &&
      other.restricted == restricted;

  @override
  int get hashCode => Object.hash(
      email, autoReply, external, memberCount, mailboxFull, restricted);
}
