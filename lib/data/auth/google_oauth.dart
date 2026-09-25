import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'google_oauth_config.dart';
import 'microsoft_oauth.dart'
    show
        SignInDeclined,
        SignInExpired,
        SignInFailed,
        SignInNeedsConsent,
        SignInUnreachable;
import 'oauth_refresher.dart';
import 'oauth_token.dart';
import 'pkce.dart';

/// Signing in to a Google account.
///
/// The authorization code flow with PKCE, the same shape as the Microsoft
/// one, with one difference that decides the whole design: Google refuses to
/// sign anyone in inside an embedded browser (`disallowed_useragent`), so
/// the page cannot be shown in a WebView the way Microsoft's is. It opens in
/// the phone's own browser instead, and the way back is a custom URI scheme
/// that Android hands to the app; see [googleRedirectScheme] and
/// OAuthRedirects.
///
/// What comes back is a token for IMAP and SMTP (`https://mail.google.com/`,
/// the one scope Google's mail servers take), the calendar, and an ID token
/// saying which account signed in, which is how the address is known without
/// anyone typing it.
class GoogleOAuth implements OAuthRefresher {
  GoogleOAuth({
    required this.clientId,
    this.clientSecret = '',
    http.Client? httpClient,
    DateTime Function()? clock,
    this.authorizeEndpoint = defaultAuthorizeEndpoint,
    this.tokenEndpoint = defaultTokenEndpoint,
  })  : _http = httpClient ?? http.Client(),
        _clock = clock ?? DateTime.now;

  /// The OAuth client ID. Not a secret; see [googleClientId].
  final String clientId;

  /// The desktop client's "secret", sent with every token request when
  /// there is one. Empty for an Android client, which has none. See
  /// [googleClientSecret] for why a phone app carries it.
  final String clientSecret;

  final http.Client _http;
  final DateTime Function() _clock;

  /// Overridden only by tests, which point them at a local fake.
  final String authorizeEndpoint;
  final String tokenEndpoint;

  static const defaultAuthorizeEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const defaultTokenEndpoint = 'https://oauth2.googleapis.com/token';

  /// Everything a Google account needs, asked for together so there is one
  /// consent screen and one refresh token.
  ///
  /// `https://mail.google.com/` is the only scope Gmail's IMAP and SMTP
  /// servers accept for XOAUTH2; the narrower Gmail API scopes do not
  /// work there. `calendar.events` is for meetings created in the app.
  /// `openid` and `email` bring back an ID token naming the account.
  static const scopes = [
    'https://mail.google.com/',
    'https://www.googleapis.com/auth/calendar.events',
    'openid',
    'email',
  ];

  /// The custom-scheme way back, for an Android client that has it enabled.
  /// The loopback way back is a URI per sign-in, given to each call.
  String get redirectUri => googleRedirectUri(clientId);

  /// Where to send the browser to start a sign-in.
  ///
  /// `access_type=offline` is what earns a refresh token, and
  /// `prompt=consent` makes Google hand one out every time rather than only
  /// on the first consent: a sign-in again with no refresh token in it would
  /// be an hour's worth of sign-in. `select_account` beside it asks which
  /// account, so a second mailbox is not silently the first one again.
  Uri authorizationUrl({
    required PkcePair pkce,
    required String state,
    String? loginHint,
    List<String>? scopes,
    String? redirectUri,
  }) =>
      Uri.parse(authorizeEndpoint).replace(queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri ?? this.redirectUri,
        'response_type': 'code',
        'scope': (scopes ?? GoogleOAuth.scopes).join(' '),
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': PkcePair.method,
        'access_type': 'offline',
        'prompt': 'consent select_account',
        'include_granted_scopes': 'true',
        if (loginHint != null && loginHint.isNotEmpty) 'login_hint': loginHint,
      });

  /// Pull the result out of the URL Android handed the app.
  ///
  /// Null for any URL that is not the redirect. Throws when the redirect is
  /// ours but carries a refusal, or a state that does not match the request
  /// this app made.
  String? codeFromRedirect(
    Uri uri, {
    required String expectedState,
    String? redirectUri,
  }) {
    if (!isRedirect(uri, redirectUri: redirectUri)) return null;

    final error = uri.queryParameters['error'];
    if (error != null) {
      if (error == 'access_denied') {
        throw const SignInDeclined(
          'Google did not grant access. If this is a Google Workspace '
          'account, your organisation may not allow outside apps to read '
          'its mail.',
        );
      }
      throw SignInFailed(_readable(error, uri.queryParameters['error_description']));
    }

    // A redirect that did not come from this request. Nothing good follows
    // from redeeming a code that arrived out of nowhere.
    if (uri.queryParameters['state'] != expectedState) {
      throw const SignInFailed(
        'The sign-in response did not match the request. Start again.',
      );
    }

    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const SignInFailed('Google sent no sign-in code back.');
    }
    return code;
  }

  /// Whether [uri] is the app's own redirect, whoever handed it over: the
  /// custom scheme, or the loopback address of this sign-in, port and all.
  bool isRedirect(Uri uri, {String? redirectUri}) {
    final target = Uri.parse(redirectUri ?? this.redirectUri);
    if (uri.scheme.toLowerCase() != target.scheme.toLowerCase()) return false;
    if (target.scheme == 'http') {
      return uri.host == target.host &&
          uri.port == target.port &&
          uri.path == target.path;
    }
    return uri.path == target.path;
  }

  /// Redeem the code the redirect carried.
  ///
  /// Comes back with who signed in as well as the token, read from the ID
  /// token Google sends beside it. Nothing in the app asks Google for a
  /// profile: the address is in what the sign-in already returned.
  Future<GoogleSignIn> exchangeCode({
    required String code,
    required PkcePair pkce,
    String? redirectUri,
  }) async {
    final Map<String, Object?> json;
    try {
      json = await _post({
        'grant_type': 'authorization_code',
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'code': code,
        'redirect_uri': redirectUri ?? this.redirectUri,
        'code_verifier': pkce.verifier,
      });
    } on _OAuthErrorResponse catch (e) {
      throw SignInFailed(_readable(e.error, e.description));
    }
    return GoogleSignIn(
      token: OAuthToken.fromResponseJson(json, now: _clock()),
      identity: GoogleIdentity.fromIdToken(json['id_token']),
    );
  }

  /// Spend the refresh token for a new access token.
  ///
  /// Google keeps the refresh token as it is, so the new record carries the
  /// old one forward. When [scopes] are named, the answer must cover them:
  /// an account signed in before the app asked for the calendar has a
  /// refresh token that never will, and that is [SignInNeedsConsent], which
  /// a sign-in again clears, not a dead sign-in.
  @override
  Future<OAuthToken> refresh(
    OAuthToken token, {
    List<String>? scopes,
  }) async {
    final Map<String, Object?> json;
    try {
      json = await _post({
        'grant_type': 'refresh_token',
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'refresh_token': token.refreshToken,
      });
    } on _OAuthErrorResponse catch (e) {
      // invalid_grant is the refresh token revoked, expired or replaced by
      // a password change. Nothing to do but sign in again.
      if (e.error == 'invalid_grant') {
        throw SignInExpired(
          'Google no longer accepts this sign-in. Sign in again.',
        );
      }
      throw SignInFailed(_readable(e.error, e.description));
    }

    if (scopes != null) {
      final granted = '${json['scope'] ?? ''}'.split(' ').toSet();
      final missing = [
        for (final s in scopes)
          if (!granted.contains(s)) s,
      ];
      if (missing.isNotEmpty) {
        throw const SignInNeedsConsent(
          'This Google account needs signing in again: it was set up before '
          'the app asked permission for the calendar. Open Settings, then '
          'Accounts, tap the account and use "Sign in with Google" — nothing '
          'cached is lost.',
        );
      }
    }

    return OAuthToken.fromResponseJson(
      json,
      now: _clock(),
      previousRefreshToken: token.refreshToken,
    );
  }

  @override
  void close() => _http.close();

  // --- plumbing --------------------------------------------------------------

  Future<Map<String, Object?>> _post(Map<String, String> form) async {
    final http.Response response;
    try {
      response = await _http.post(
        Uri.parse(tokenEndpoint),
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: form,
      );
    } catch (e) {
      throw SignInUnreachable('Could not reach Google to sign in. ($e)');
    }

    final Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      throw SignInFailed(
        'Google answered with something that was not JSON '
        '(HTTP ${response.statusCode}).',
      );
    }
    if (body is! Map) {
      throw SignInFailed(
        'Google answered with an unexpected shape '
        '(HTTP ${response.statusCode}).',
      );
    }
    final json = body.cast<String, Object?>();
    final error = json['error'];
    if (error is String) {
      throw _OAuthErrorResponse(
        error: error,
        description: json['error_description'] as String?,
      );
    }
    if (response.statusCode >= 400) {
      throw SignInFailed(
        'Google refused the request (HTTP ${response.statusCode}).',
      );
    }
    return json;
  }

  /// Google's error codes, in words a person can act on. The description
  /// Google sends beside them is usually "Bad Request".
  static String _readable(String error, String? description) =>
      switch (error) {
        'invalid_client' || 'unauthorized_client' =>
          'Google does not recognise this app. Check the client ID the build '
              'was made with.',
        'redirect_uri_mismatch' =>
          'Google refused the way back into the app. In the Google Cloud '
              'client, under Advanced settings, enable custom URI schemes.',
        'invalid_grant' =>
          'The sign-in code was not accepted. Start again.',
        'admin_policy_enforced' || 'org_internal' =>
          'Your organisation\'s Google Workspace does not allow this app.',
        'disallowed_useragent' =>
          'Google will not sign in from inside another app. Sign in through '
              'the browser.',
        _ => description == null || description.isEmpty
            ? 'Google refused the sign-in ($error).'
            : '$description ($error)',
      };
}

/// What a Google sign-in comes back with: the token, and who it is for.
@immutable
class GoogleSignIn {
  const GoogleSignIn({required this.token, this.identity});

  final OAuthToken token;

  /// Null when Google sent no ID token, which it only does when `openid` was
  /// not asked for.
  final GoogleIdentity? identity;
}

/// Who signed in, read from the ID token Google sends beside the access
/// token.
///
/// Read, not verified: it came straight from Google's token endpoint over
/// TLS in answer to this app's own request, which is the check a signature
/// would make. The address is what the account is filed under.
@immutable
class GoogleIdentity {
  const GoogleIdentity({required this.subject, this.email});

  /// Google's own id for the account, stable across address changes.
  final String subject;

  /// The address, where Google says it. Lower-cased: Google does.
  final String? email;

  static GoogleIdentity? fromIdToken(Object? idToken) {
    if (idToken is! String) return null;
    final parts = idToken.split('.');
    if (parts.length != 3) return null;
    try {
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (claims is! Map) return null;
      final sub = claims['sub'];
      if (sub is! String || sub.isEmpty) return null;
      final email = claims['email'];
      return GoogleIdentity(
        subject: sub,
        email: email is String && email.contains('@')
            ? email.toLowerCase()
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The token endpoint answering with an `error` field rather than a token.
@immutable
class _OAuthErrorResponse implements Exception {
  const _OAuthErrorResponse({required this.error, this.description});
  final String error;
  final String? description;
}
