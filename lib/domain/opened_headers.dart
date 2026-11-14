import 'package:flutter/foundation.dart';

import 'address_suggestions.dart' show isOneBareAddress, splitRecipients;
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

  /// The one address [receiptTo] names, bare, as it is written. Null where
  /// it names none or more than one: a receipt goes only to an address Ron
  /// can be shown, and the header is the sender's to fill with anyone's.
  String? get receiptAddress {
    final pieces = [
      for (final piece in splitRecipients(receiptTo ?? ''))
        if (piece.trim().isNotEmpty) piece.trim(),
    ];
    if (pieces.length != 1) return null;
    final angled = RegExp(r'<([^<>]*)>$').firstMatch(pieces.single);
    final address = (angled?.group(1) ?? pieces.single).trim();
    return isOneBareAddress(address) ? address : null;
  }

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
