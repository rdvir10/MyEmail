import 'package:flutter/foundation.dart';

import 'unsubscribe.dart';

/// What a message's headers say that its list row does not carry, read
/// when it is opened: how its mailing list says to leave it, and whether
/// its sender asked to be told it was read.
@immutable
class OpenedHeaders {
  const OpenedHeaders({this.unsubscribe, this.receiptTo});

  /// See [UnsubscribeOptions]. Null where the message names no way out.
  final UnsubscribeOptions? unsubscribe;

  /// Where the sender asked for a read receipt to go, as the
  /// `Disposition-Notification-To` header names it (RFC 8098). Null where
  /// none was asked for.
  final String? receiptTo;

  static const none = OpenedHeaders();

  /// The headers this is read from, as they are asked for.
  static const headerNames = [
    'List-Unsubscribe',
    'List-Unsubscribe-Post',
    'Disposition-Notification-To',
  ];

  /// From what a header lookup found, keyed by name in lower case.
  factory OpenedHeaders.fromHeaders(Map<String, String> found) {
    final receipt = found['disposition-notification-to']?.trim();
    return OpenedHeaders(
      unsubscribe: UnsubscribeOptions.parse(
        found['list-unsubscribe'],
        found['list-unsubscribe-post'],
      ),
      receiptTo: receipt == null || !receipt.contains('@') ? null : receipt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OpenedHeaders &&
      other.unsubscribe == unsubscribe &&
      other.receiptTo == receiptTo;

  @override
  int get hashCode => Object.hash(unsubscribe, receiptTo);
}
