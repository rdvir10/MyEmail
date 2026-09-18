import 'package:flutter/foundation.dart';

import 'account.dart';

/// What the app can offer to do about an error, beyond describing it.
///
/// Only things that are genuinely one tap and genuinely likely to work. An
/// offer that fails leaves someone worse off than no offer at all: they have
/// tried the fix, it did not work, and now they have no idea what else to do.
enum ErrorRemedy {
  /// The credential is stale or does not cover enough. Signing in again
  /// replaces it and keeps every cached message.
  signInAgain('Sign in again'),

  /// Nothing was wrong with the request; the server or the connection was
  /// having a moment.
  retry('Try again'),

  /// Describable but not fixable from here — an administrator has to act, or
  /// it is a bug. Offering a button would only waste a tap.
  none('');

  const ErrorRemedy(this.label);

  final String label;

  bool get isOffered => this != ErrorRemedy.none;
}

/// What the app should offer for this failure.
///
/// Deliberately driven by the exception type rather than by matching on
/// message text: the messages are written for people and get reworded, and a
/// remedy that silently stops being offered because a sentence changed is
/// worse than one that was never there.
ErrorRemedy remedyFor(Object error) {
  if (error is NeedsSignIn) {
    return error.needsAdministrator ? ErrorRemedy.none : ErrorRemedy.signInAgain;
  }
  if (error is Retryable) return ErrorRemedy.retry;
  return ErrorRemedy.none;
}

/// Implemented by failures a fresh sign-in would clear.
abstract interface class NeedsSignIn {
  /// True when the person cannot fix it themselves because their organisation
  /// does not let its users approve outside apps. Signing in again then loops
  /// without ever succeeding.
  bool get needsAdministrator;
}

/// Implemented by failures worth simply trying again.
abstract interface class Retryable {}

/// Implemented by failures that already carry a sentence written for a person.
///
/// Everything the app throws on purpose does. What does not is a bug rather
/// than a condition, and shows as itself — which is the right outcome: a
/// StateError deserves to look like one rather than being dressed up as
/// something the person did wrong.
abstract interface class ReadableError {
  String get message;
}

/// One failure, with enough around it to describe, act on and report.
///
/// Every screen that can fail holds one of these rather than a bare string.
/// The string was all that was needed to show a sentence; the error itself is
/// what decides which remedy to offer and what a report should say.
@immutable
class ProblemReport {
  const ProblemReport({
    required this.doing,
    required this.error,
    this.account,
  });

  /// What the app was attempting, as a sentence. Usually the part that
  /// identifies a problem: the same failure reads very differently coming
  /// from a send than from a folder load.
  final String doing;

  final Object error;
  final Account? account;

  String get message =>
      error is ReadableError ? (error as ReadableError).message : '$error';

  ErrorRemedy get remedy => remedyFor(error);

  String text({String? appVersion, int? build, bool redactAddress = false}) =>
      buildErrorReport(
        doing: doing,
        error: error,
        account: account,
        appVersion: appVersion,
        build: build,
        redactAddress: redactAddress,
      );

  String get issueTitle => IssueTracker.titleFor(doing: doing, error: error);
}

/// Everything worth knowing about a failure, as text to paste somewhere.
///
/// The point is that one paste replaces a screenshot and a conversation. A
/// screenshot shows the sentence; this shows the build it came from, the
/// account it happened to and what the app was doing at the time, which is
/// usually what actually identifies the problem.
///
/// No secret ever reaches this. The app passwords and tokens live in the
/// Keystore and nothing here reads them; what is included is the account's
/// address and how it signs in, because without those a report cannot be
/// matched to an account at all.
String buildErrorReport({
  required String doing,
  required Object error,
  Account? account,
  String? appVersion,
  int? build,
  DateTime? at,
  bool redactAddress = false,
}) {
  final when = (at ?? DateTime.now()).toUtc();
  final lines = <String>[
    'MyEmail problem report',
    'When: ${when.toIso8601String()}',
    if (appVersion != null)
      'Version: $appVersion${build == null ? '' : ' (build $build)'}',
    'Doing: $doing',
    if (account != null) ...[
      'Account: ${account.displayName}',
      'Address: ${redactAddress ? maskAddress(account.emailAddress) : account.emailAddress}',
      'Provider: ${account.provider.label}',
      'Signs in with: ${switch (account.authMethod) {
        AuthMethod.appPassword => 'an app password',
        AuthMethod.oauth => '${account.provider.label} sign-in',
      }}',
    ],
    '',
    // The runtime type as well as the message. Two different failures often
    // read the same to a person and are nothing alike underneath.
    'Error: ${error.runtimeType}',
    '$error',
  ];
  return lines.join('\n');
}

/// An address with its local part hidden, for a report going somewhere public.
///
/// The first character and the domain stay, which is enough to tell one of
/// your own accounts from another without publishing an address for anyone to
/// collect. The full address still goes on the clipboard, because that goes
/// wherever you put it.
String maskAddress(String address) {
  final at = address.indexOf('@');
  if (at <= 0) return '***';
  return '${address[0]}***${address.substring(at)}';
}

/// Where a problem report can be filed.
abstract final class IssueTracker {
  /// The repository the app is released from.
  static const repository = 'rdvir10/MyEmail';

  /// A prefilled "new issue" page, ready to look over and submit.
  ///
  /// A URL and not an API call, deliberately: posting through the API would
  /// need a GitHub token living inside the app, and a token shipped in an APK
  /// is a token anyone who has the APK can use. This way the app opens a page,
  /// GitHub authenticates the person as it normally does, and nothing secret
  /// has to exist. It also means the report is read and submitted on purpose
  /// rather than sent the instant something goes wrong.
  static Uri newIssueUrl({required String title, required String report}) {
    return Uri.https('github.com', '/$repository/issues/new', {
      'title': title,
      // Fenced, so a stack trace or a Microsoft error paragraph keeps its
      // shape instead of being reflowed into one line by Markdown.
      'body': 'What happened:\n\n```\n$report\n```\n',
      'labels': 'from the app',
    });
  }

  /// A one-line title: what failed, and what it was.
  static String titleFor({required String doing, required Object error}) =>
      '$doing — ${error.runtimeType}';
}
