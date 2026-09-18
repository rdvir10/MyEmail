import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'oauth_token.dart';

/// Sign-in to a personal Microsoft account, by the device authorization grant
/// (RFC 8628).
///
/// Why this flow and not the usual authorization code with PKCE: that one
/// needs a redirect URI, a custom URL scheme, an intent filter, and a package
/// to drive the browser and catch the callback. The device flow needs none of
/// it. The app shows a short code, the person types it into
/// microsoft.com/devicelogin in any browser on any device, and the app polls
/// an ordinary HTTPS endpoint until a token falls out. It costs one extra
/// step for the person and removes a dependency and a platform integration
/// from us, which on this project has been the better trade every time.
///
/// Microsoft requires "Allow public client flows" = Yes on the registration
/// for this flow. Without it the sign-in fails with AADSTS7000218, which
/// reads as a missing client secret; [_readableAadError] translates it.
class MicrosoftOAuth {
  MicrosoftOAuth({
    required this.clientId,
    http.Client? httpClient,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    this.authority = commonAuthority,
  })  : _http = httpClient ?? http.Client(),
        _clock = clock ?? DateTime.now,
        _sleep = sleep ?? _realSleep;

  /// The Application (client) ID from the app registration. Not a secret:
  /// public clients cannot keep one, which is why this flow does not use it.
  final String clientId;

  final http.Client _http;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  /// Which Microsoft sign-in endpoint to talk to. Overridden only by tests,
  /// which point it at a local fake.
  final String authority;

  /// Accepts a personal Microsoft account or a work or school one.
  ///
  /// `/consumers` would take only personal accounts and `/organizations` only
  /// work ones. `/common` is the pair that matches how this app is actually
  /// registered, and the mismatch is not obvious: an app registration has to
  /// live in a directory, and a personal account cannot have one, so the
  /// registration sits in a work tenant while the mailbox being added is
  /// usually a personal Outlook.com address. `/common` is the only authority
  /// that serves both, and it means one registration covers the work mailbox
  /// too if that is ever wanted.
  ///
  /// The registration's "Supported account types" must agree: accounts in any
  /// organizational directory **and** personal Microsoft accounts.
  static const commonAuthority =
      'https://login.microsoftonline.com/common/oauth2/v2.0';

  /// Exactly what Microsoft documents for IMAP and SMTP access. These strings
  /// are load-bearing and case-sensitive; the shorter Graph-style names
  /// (`IMAP.AccessAsUser.All` alone) are a different API and are refused.
  static const scopes = [
    'https://outlook.office.com/IMAP.AccessAsUser.All',
    'https://outlook.office.com/SMTP.Send',
    // Without this there is no refresh token, and the account would have to
    // sign in again every hour.
    'offline_access',
  ];

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  Uri get _deviceCodeUri => Uri.parse('$authority/devicecode');
  Uri get _tokenUri => Uri.parse('$authority/token');

  /// Step one: ask Microsoft for a code to show the user.
  ///
  /// The clock starts here — the code is good for about fifteen minutes — so
  /// only call this when the person is actually looking at the screen.
  Future<DeviceCodePrompt> requestDeviceCode() async {
    final Map<String, Object?> json;
    try {
      json = await _post(_deviceCodeUri, {
        'client_id': clientId,
        'scope': scopes.join(' '),
      });
    } on _OAuthErrorResponse catch (e) {
      // Unlike the token endpoint, nothing here is a "keep waiting" answer:
      // every error is final. This is also where a wrong client ID and a
      // registration without public client flows turn up, so the message
      // matters more than usual — without this the internal error type
      // escaped and reached the screen as "Instance of _OAuthErrorResponse".
      throw SignInFailed(_readableAadError(e));
    }

    final deviceCode = json['device_code'];
    final userCode = json['user_code'];
    final uri = json['verification_uri'];
    if (deviceCode is! String || userCode is! String || uri is! String) {
      throw const SignInFailed(
        'Microsoft sent a sign-in response the app could not read.',
      );
    }

    return DeviceCodePrompt(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: Uri.parse(uri),
      expiresAt: _clock()
          .toUtc()
          .add(Duration(seconds: _intOr(json['expires_in'], 900))),
      interval: Duration(seconds: _intOr(json['interval'], 5)),
    );
  }

  /// Step two: poll until the person finishes signing in, or gives up, or the
  /// code expires.
  ///
  /// Completes with the token, or throws [SignInDeclined], [SignInTimedOut],
  /// [SignInCancelled] or [SignInFailed]. Resolving [stopSignal] abandons the
  /// poll, which is what backing out of the add-account screen does.
  Future<OAuthToken> awaitToken(
    DeviceCodePrompt prompt, {
    Future<void>? stopSignal,
  }) async {
    var cancelled = false;
    stopSignal?.then((_) => cancelled = true);

    // Microsoft's documented errors do not include slow_down, but RFC 8628
    // defines it and their servers do send it under load. Ignoring it gets
    // the client throttled, so it is handled even though the docs omit it.
    var interval = prompt.interval;

    while (true) {
      await _sleep(interval);
      if (cancelled) throw const SignInCancelled();
      if (!_clock().toUtc().isBefore(prompt.expiresAt)) {
        throw const SignInTimedOut();
      }

      final Map<String, Object?> json;
      try {
        json = await _post(_tokenUri, {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'client_id': clientId,
          'device_code': prompt.deviceCode,
        });
      } on _OAuthErrorResponse catch (e) {
        switch (e.error) {
          case 'authorization_pending':
            continue;
          case 'slow_down':
            interval += const Duration(seconds: 5);
            continue;
          case 'authorization_declined':
            throw const SignInDeclined();
          case 'expired_token':
            throw const SignInTimedOut();
          default:
            throw SignInFailed(_readableAadError(e));
        }
      }

      return OAuthToken.fromResponseJson(json, now: _clock());
    }
  }

  /// Spend the refresh token for a new access token.
  ///
  /// Throws [SignInExpired] when Microsoft rejects the refresh token itself,
  /// which is the one failure the app cannot retry its way out of: the person
  /// has to sign in again. Everything else — no network, a 5xx — comes back
  /// as [SignInFailed] so the caller retries rather than signing the account
  /// out over a flaky connection.
  Future<OAuthToken> refresh(OAuthToken token) async {
    final Map<String, Object?> json;
    try {
      json = await _post(_tokenUri, {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'scope': scopes.join(' '),
        'refresh_token': token.refreshToken,
      });
    } on _OAuthErrorResponse catch (e) {
      // invalid_grant is the refresh token being revoked, expired, or
      // invalidated by a password change. Nothing to do but sign in again.
      if (e.error == 'invalid_grant') {
        throw SignInExpired(_readableAadError(e));
      }
      throw SignInFailed(_readableAadError(e));
    }

    return OAuthToken.fromResponseJson(
      json,
      now: _clock(),
      previousRefreshToken: token.refreshToken,
    );
  }

  void close() => _http.close();

  // --- plumbing --------------------------------------------------------------

  Future<Map<String, Object?>> _post(Uri uri, Map<String, String> form) async {
    final http.Response response;
    try {
      response = await _http.post(
        uri,
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: form,
      );
    } catch (e) {
      throw SignInFailed('Could not reach Microsoft to sign in. ($e)');
    }

    final Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      throw SignInFailed(
        'Microsoft answered with something that was not JSON '
        '(HTTP ${response.statusCode}).',
      );
    }
    if (body is! Map) {
      throw SignInFailed(
        'Microsoft answered with an unexpected shape '
        '(HTTP ${response.statusCode}).',
      );
    }
    final json = body.cast<String, Object?>();

    // The device flow signals "still waiting" as HTTP 400 with an error code
    // in the body, so a non-2xx is not automatically a failure here.
    final error = json['error'];
    if (error is String) {
      throw _OAuthErrorResponse(
        error: error,
        description: json['error_description'] as String?,
      );
    }
    if (response.statusCode >= 400) {
      throw SignInFailed(
        'Microsoft refused the request (HTTP ${response.statusCode}).',
      );
    }
    return json;
  }

  /// Microsoft's error_description is a paragraph with a correlation ID, a
  /// timestamp and a trace ID in it. The first line carries the meaning; the
  /// rest is for a support ticket.
  static String _readableAadError(_OAuthErrorResponse e) {
    final description = e.description ?? '';
    if (description.contains('AADSTS700016') ||
        description.contains('AADSTS900023')) {
      return 'Microsoft does not recognise this app registration. Check the '
          'client ID the build was made with.';
    }
    if (description.contains('AADSTS7000218')) {
      return 'The app registration does not allow this kind of sign-in. In '
          'the Entra portal, under Authentication, set "Allow public client '
          'flows" to Yes.';
    }
    final firstLine = description.split('\n').first.trim();
    if (firstLine.isEmpty) return 'Microsoft refused the sign-in (${e.error}).';
    return firstLine;
  }

  static int _intOr(Object? value, int fallback) => switch (value) {
        final int i => i,
        final String s => int.tryParse(s) ?? fallback,
        _ => fallback,
      };
}

/// What to put on screen while waiting: the person types [userCode] at
/// [verificationUri]. [deviceCode] is the app's half and is never shown.
@immutable
class DeviceCodePrompt {
  const DeviceCodePrompt({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final DateTime expiresAt;
  final Duration interval;

  @override
  String toString() => 'DeviceCodePrompt($userCode at $verificationUri)';
}

/// The token endpoint answering with an `error` field rather than a token.
/// Internal: callers see the typed exceptions below.
@immutable
class _OAuthErrorResponse implements Exception {
  const _OAuthErrorResponse({required this.error, this.description});
  final String error;
  final String? description;
}

/// Sign-in did not work, and it is worth trying again.
@immutable
class SignInFailed implements Exception {
  const SignInFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Consent was not given.
///
/// Usually the person pressed no. On a work or school account it can also
/// arrive without anyone choosing anything: many organisations stop their
/// users consenting to outside apps, so the sign-in page offers to ask an
/// administrator instead and the app is simply refused. The two are
/// indistinguishable from here, so the message names both rather than
/// blaming the person for a decision their employer made.
@immutable
class SignInDeclined implements Exception {
  const SignInDeclined();
  String get message =>
      'Microsoft did not grant access. If this is a work or school account, '
      'your organisation may require an administrator to approve the app '
      'before anyone there can sign in to it.';
  @override
  String toString() => message;
}

/// Nobody finished signing in before the code expired.
@immutable
class SignInTimedOut implements Exception {
  const SignInTimedOut();
  String get message =>
      'The sign-in code expired. Start again to get a new one.';
  @override
  String toString() => message;
}

/// The app stopped waiting, because the person left the screen.
@immutable
class SignInCancelled implements Exception {
  const SignInCancelled();
  String get message => 'Sign-in was cancelled.';
  @override
  String toString() => message;
}

/// The stored refresh token is no longer good. Unlike [SignInFailed] this
/// does not come back on its own; the account must sign in again.
@immutable
class SignInExpired implements Exception {
  const SignInExpired(this.message);
  final String message;
  @override
  String toString() => message;
}
