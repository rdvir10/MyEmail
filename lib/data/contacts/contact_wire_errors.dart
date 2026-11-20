import 'package:flutter/foundation.dart' show immutable;

import '../../domain/error_report.dart';

// The failures the two contact clients (GoogleContactsApi and
// GraphContactsApi) throw beyond the app's usual ones, shared so that the
// runner reads both servers the same way.
//
// None carries a server's own sentence. Contact servers echo back what they
// were sent, and a refused contact's name, address or number in an error
// would reach the log and every screen that shows one. What is kept is the
// HTTP status and the error's reason code, which say enough to look it up.

/// Where a feed of changes was read up to is no good any more: Google's sync
/// token has expired, or Graph's delta link has (410, `syncStateNotFound`).
/// Not a failure to show: the answer is a full listing, which starts a new
/// feed.
@immutable
class ContactFeedExpired implements Exception {
  const ContactFeedExpired(this.status);

  /// The HTTP status it came with, for the log.
  final int status;

  @override
  String toString() => 'The contact feed has expired (HTTP $status).';
}

/// A server would not take, or give, what was asked of it: a 400-class
/// answer other than the ones with types of their own. On a write it is
/// about that one contact (too long a field, too big a contact), which is
/// held as refused while the rest go on. On a read it is the run's.
@immutable
class ContactRefused implements Exception, ReadableError {
  const ContactRefused(this.message, {required this.status, this.reason});

  /// [server]'s refusal with [status] and [reason], in a sentence that
  /// names only those.
  factory ContactRefused.by(String server, int status, String? reason) =>
      ContactRefused(
        '$server would not take the contact '
        '(HTTP $status${reason == null ? '' : ', $reason'}).',
        status: status,
        reason: reason,
      );

  @override
  final String message;

  final int status;

  /// The error's reason code (`INVALID_ARGUMENT`, `ErrorInvalidProperty`),
  /// where it gave one that looks like a code.
  final String? reason;

  @override
  String toString() => message;
}

/// Google's etag clash: the contact changed since it was read, so the write
/// was not made. Read it again, merge again and try once more.
@immutable
class ContactChangedMeanwhile implements Exception, ReadableError {
  const ContactChangedMeanwhile();

  @override
  String get message =>
      'The contact changed while it was being synced. It is tried again.';

  @override
  String toString() => message;
}

/// The contact, or the folder, is not there (404).
@immutable
class ContactGone implements Exception, ReadableError {
  const ContactGone();

  @override
  String get message => 'The contact is not there any more.';

  @override
  String toString() => message;
}

/// Google's daily quota for the account's contacts is spent: nothing more
/// goes until [until], when it is renewed.
@immutable
class ContactQuotaSpent implements Exception, Retryable, ReadableError {
  const ContactQuotaSpent(this.until);

  final DateTime until;

  @override
  String get message =>
      "Google's daily limit on contact changes is used up. Contact sync "
      'carries on tomorrow.';

  @override
  String toString() => message;
}

/// The People API is switched off in the app's Google Cloud project: a
/// setting to change there, which neither signing in nor waiting changes.
@immutable
class ContactsSwitchedOff implements Exception, ReadableError {
  const ContactsSwitchedOff();

  @override
  String get message =>
      "The People API is switched off in the app's Google Cloud project. "
      'Open APIs & Services, Library, People API and enable it, then sync '
      'again.';

  @override
  String toString() => message;
}

/// [code] if it looks like an error code, and nothing if it looks like
/// anything else: only a code is kept from what a server says.
String? errorCode(Object? code) {
  if (code is! String) return null;
  return RegExp(r'^[A-Za-z][A-Za-z0-9_.]{0,63}$').hasMatch(code)
      ? code
      : null;
}
