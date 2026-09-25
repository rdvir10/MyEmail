import 'oauth_token.dart';

/// What [OAuthTokenRepository] needs of a sign-in provider: a new access
/// token for a refresh token, and a way to let go of the connection.
///
/// One interface for two providers. Microsoft and Google differ in their
/// endpoints, their error codes and whether a refresh hands back a new
/// refresh token, and none of that reaches the repository, which only cares
/// that a token came back or which kind of failure stopped it.
abstract interface class OAuthRefresher {
  /// Spend the refresh token for a new access token.
  ///
  /// Throws [SignInExpired] when the provider rejects the refresh token
  /// itself, [SignInNeedsConsent] when the sign-in is fine but does not
  /// cover [scopes], and [SignInFailed] (or its [SignInUnreachable]) for
  /// anything worth retrying.
  Future<OAuthToken> refresh(OAuthToken token, {List<String>? scopes});

  void close();
}
