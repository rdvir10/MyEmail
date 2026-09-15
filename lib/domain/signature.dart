import 'package:flutter/foundation.dart';

/// A per-account signature, stored as HTML because that is what the editor
/// and the sent message use.
@immutable
class Signature {
  const Signature({
    required this.accountId,
    required this.html,
    this.onReply = true,
  });

  final String accountId;
  final String html;

  /// Whether it is inserted on replies and forwards as well as new messages.
  /// Off is a common preference: a signature on every reply in a long thread
  /// piles up.
  final bool onReply;

  bool get isEmpty => html.trim().isEmpty;

  Signature copyWith({String? html, bool? onReply}) => Signature(
        accountId: accountId,
        html: html ?? this.html,
        onReply: onReply ?? this.onReply,
      );

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'html': html,
        'onReply': onReply,
      };

  static Signature fromJson(Map<String, dynamic> j) => Signature(
        accountId: j['accountId'] as String,
        html: j['html'] as String,
        onReply: j['onReply'] as bool? ?? true,
      );
}
