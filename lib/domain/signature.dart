import 'dart:convert';

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

  /// Every signature in [raw] that can be read, by account, or null when
  /// [raw] is not a list of signatures at all.
  ///
  /// One at a time, so one damaged entry costs that account's signature and
  /// not everyone's. A stored value of the wrong shape used to throw out of
  /// the signatures provider, and compose failed on every account until the
  /// app's data was cleared.
  static Map<String, Signature>? mapFromJson(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (json is! List) return null;
    return {
      for (final s in [for (final j in json) ?_tryFromJson(j)]) s.accountId: s,
    };
  }

  static Signature? _tryFromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    try {
      return fromJson(j);
    } on TypeError {
      return null;
    }
  }
}
