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
}) {
  final when = (at ?? DateTime.now()).toUtc();
  final lines = <String>[
    'MyEmail problem report',
    'When: ${when.toIso8601String()}',
    if (appVersion != null)
      'Version: $appVersion${build == null ? '' : ' (build $build)'}',
    'Doing: $doing',
    if (account != null) ...[
      'Account: ${account.emailAddress}',
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
