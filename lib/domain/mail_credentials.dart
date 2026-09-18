import 'package:flutter/foundation.dart';

/// How a connection proves who it is, at the moment it is opened.
///
/// This replaced a plain `String secret` when Microsoft accounts arrived. An
/// app password is a value: you read it once and it works forever. An OAuth
/// access token is not — it expires hourly, so what a transport must hold is
/// not a token but the means of asking for a current one. The two cannot
/// share a type without one of them lying, hence the sealed pair.
sealed class MailCredentials {
  const MailCredentials();
}

/// Gmail with an app password, and any IMAP server still accepting one.
@immutable
final class PasswordCredentials extends MailCredentials {
  const PasswordCredentials(this.password);
  final String password;

  /// No password in it. This type ends up in error messages.
  @override
  String toString() => 'PasswordCredentials(...)';
}

/// OAuth, where the token is fetched per connection.
@immutable
final class OAuthCredentials extends MailCredentials {
  const OAuthCredentials(this.accessToken);

  /// Returns a token with enough life left to complete an operation,
  /// refreshing behind the scenes if needed.
  ///
  /// Called on every connect, so the common path — a cached token that is
  /// still good — must not touch the network.
  ///
  /// [force] is for the retry after a server rejects a token we believed was
  /// fresh, which is what a skewed device clock looks like from here.
  final Future<String> Function({bool force}) accessToken;

  @override
  String toString() => 'OAuthCredentials(...)';
}
