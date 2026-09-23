import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/error_report.dart';
import 'pkce.dart';
import 'oauth_token.dart';

/// Signing in to a Microsoft account, personal or work.
///
/// Two flows live here, and which one is used is not a matter of taste.
///
/// [authorizationUrl] and [exchangeCode] are the authorization code flow with
/// PKCE, and they are the path the app takes. The person signs in on a real
/// Microsoft page shown inside the app, and the redirect carries a code that
/// is redeemed with a verifier that never went near the browser.
///
/// [requestDeviceCode] and [awaitToken] are the device authorization grant
/// (RFC 8628), kept as a fallback for the case where the embedded browser
/// cannot be used at all.
///
/// The device flow was the original choice, because it needs no redirect URI
/// and no browser integration. That was defensible for a personal mailbox and
/// wrong for anything else: Microsoft's security defaults block the device
/// code flow outright, and from 1 July 2026 every new tenant has them on. A
/// work account meets
///
///   AADSTS530035: Access has been blocked by security defaults
///
/// which says nothing about which flow is at fault. PKCE is not blocked, so it
/// leads; the device flow stays because the two fail in different
/// circumstances and having the second costs little.
///
/// Microsoft requires "Allow public client flows" = Yes on the registration
/// for either. Without it the sign-in fails with AADSTS7000218, which reads as
/// a missing client secret; [_readableAadError] translates it.
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

  /// Everything a Microsoft account needs, and nothing else.
  ///
  /// One resource, so one token and one consent. That is only true because
  /// the app stopped using IMAP and SMTP for these accounts: an access token
  /// is issued per resource and Microsoft refuses a request that mixes
  /// `outlook.office.com` with `graph.microsoft.com`, so while reading went
  /// over IMAP and sending over Graph, signing in meant collecting consent
  /// twice and asking the person to approve two screens in a row.
  ///
  /// `Mail.ReadWrite` covers reading, flags, moves and folders; `Mail.Send`
  /// covers sending. Without `offline_access` there is no refresh token and
  /// the account would have to sign in again every hour.
  static const scopes = [
    'https://graph.microsoft.com/Mail.ReadWrite',
    'https://graph.microsoft.com/Mail.Send',
    'offline_access',
  ];

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// Where the redirect lands after a successful sign-in.
  ///
  /// Microsoft's documented redirect for a native app using an embedded
  /// browser. It is an ordinary https URL that never actually loads: the app
  /// watches for the browser trying to navigate here and takes the code out of
  /// the query string instead. A custom scheme would work too, but an unknown
  /// scheme makes some embedded browsers raise an error before the app is
  /// asked about it.
  ///
  /// It must be listed on the app registration, under Mobile and desktop
  /// applications.
  static const redirectUri =
      'https://login.microsoftonline.com/common/oauth2/nativeclient';

  Uri get _deviceCodeUri => Uri.parse('$authority/devicecode');
  Uri get _tokenUri => Uri.parse('$authority/token');
  Uri get _authorizeUri => Uri.parse('$authority/authorize');

  /// Where to send the browser to start a sign-in.
  ///
  /// [loginHint] pre-fills the address box with what the person already typed,
  /// so they are not asked for it twice.
  Uri authorizationUrl({
    required PkcePair pkce,
    required String state,
    String? loginHint,
    List<String>? scopes,
  }) =>
      _authorizeUri.replace(queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'response_mode': 'query',
        'scope': (scopes ?? MicrosoftOAuth.scopes).join(' '),
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': PkcePair.method,
        // Always ask which account. Without it a second mailbox silently
        // reuses whichever session the browser already has, and the person
        // ends up adding the same account twice without being told.
        'prompt': 'select_account',
        if (loginHint != null && loginHint.isNotEmpty) 'login_hint': loginHint,
      });

  /// Redeem the code the redirect carried.
  Future<OAuthToken> exchangeCode({
    required String code,
    required PkcePair pkce,
  }) async {
    // No scope parameter: the code was issued against whatever was asked for
    // at the authorize step, and naming a different resource here is refused.
    final Map<String, Object?> json;
    try {
      json = await _post(_tokenUri, {
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'code': code,
        'redirect_uri': redirectUri,
        'code_verifier': pkce.verifier,
      });
    } on _OAuthErrorResponse catch (e) {
      throw SignInFailed(_readableAadError(e));
    }
    return OAuthToken.fromResponseJson(json, now: _clock());
  }

  /// Pull the result out of a redirect the browser tried to follow.
  ///
  /// Returns null for any URL that is not the redirect, which is every other
  /// navigation during a sign-in. Throws when the redirect is ours but carries
  /// a refusal, or a state that does not match the request this app made.
  String? codeFromRedirect(Uri uri, {required String expectedState}) {
    if (!_isRedirect(uri)) return null;

    final error = uri.queryParameters['error'];
    if (error != null) {
      final description = uri.queryParameters['error_description'] ?? '';
      if (error == 'access_denied') throw const SignInDeclined();
      throw SignInFailed(_readableAadError(
        _OAuthErrorResponse(error: error, description: description),
      ));
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
      throw const SignInFailed('Microsoft sent no sign-in code back.');
    }
    return code;
  }

  static bool _isRedirect(Uri uri) {
    final target = Uri.parse(redirectUri);
    return uri.scheme == target.scheme &&
        uri.host == target.host &&
        uri.path == target.path;
  }

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
  /// [scopes] names which resource the access token is for. Defaults to the
  /// IMAP and SMTP set; pass [graphScopes] for a Graph token. Either works
  /// from the same refresh token once both have been consented to.
  Future<OAuthToken> refresh(
    OAuthToken token, {
    List<String>? scopes,
  }) async {
    final Map<String, Object?> json;
    try {
      json = await _post(_tokenUri, {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'scope': (scopes ?? MicrosoftOAuth.scopes).join(' '),
        'refresh_token': token.refreshToken,
      });
    } on _OAuthErrorResponse catch (e) {
      // Consent for this resource was never given, or was withdrawn. Distinct
      // from a dead refresh token: the sign-in is fine, the app simply has not
      // been allowed this particular thing, and the way out is to ask rather
      // than to sign in again.
      final description = e.description ?? '';
      if (description.contains('AADSTS65001') ||
          description.contains('AADSTS70000') ||
          e.error == 'consent_required' ||
          e.error == 'interaction_required') {
        throw SignInNeedsConsent(
          _readableAadError(e),
          // 65001 in a tenant that has locked consent down is the one case
          // nobody signing in can clear.
          needsAdministrator: description.contains('AADSTS65001'),
        );
      }
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
      throw SignInUnreachable('Could not reach Microsoft to sign in. ($e)');
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
    // AADSTS70000 is what an account signed in before the app asked for a
    // scope meets: the refresh token is real and the sign-in is live, but the
    // consent behind it does not cover what is now being asked for. Microsoft
    // reports it as a paragraph with two trace IDs in it, which tells the
    // person nothing they can act on, and the remedy is not the "remove and
    // add it again" that a dead sign-in would need — signing in again keeps
    // every cached message.
    if (description.contains('AADSTS70000')) {
      return 'This account needs signing in again. It was set up before the '
          'app asked permission for this, so the permission it has is no '
          'longer enough. Open Settings, then Accounts, tap the account and '
          'use "Sign in again" — nothing cached is lost.';
    }
    if (description.contains('AADSTS65001')) {
      // The same shortfall, but nobody here can fix it by signing in: this is
      // the tenant refusing to let its users consent at all.
      return 'This account has not been allowed to do that. If it is a work '
          'or school account, an administrator has to approve the app for '
          'your organisation before anyone there can use it.';
    }
    if (description.contains('AADSTS530035')) {
      return 'Your organisation blocks this way of signing in. Sign in again '
          'and use the ordinary sign-in page rather than a code.';
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
class SignInFailed implements Exception, ReadableError {
  const SignInFailed(this.message);
  @override
  final String message;
  @override
  String toString() => message;
}

/// The sign-in could not be tried at all: no connection to Microsoft.
///
/// A [SignInFailed] still, for every screen that shows one, but also
/// [Retryable], and read as being offline by whatever was only after a
/// token for something else. As a sign-in failure it went past every place
/// that falls back to the cache when there is no connection, so a Microsoft
/// account more than an hour into a flight showed errors instead of mail.
@immutable
class SignInUnreachable extends SignInFailed implements Retryable {
  const SignInUnreachable(super.message);
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
class SignInDeclined implements Exception, ReadableError {
  const SignInDeclined();
  @override
  String get message =>
      'Microsoft did not grant access. If this is a work or school account, '
      'your organisation may require an administrator to approve the app '
      'before anyone there can sign in to it.';
  @override
  String toString() => message;
}

/// Nobody finished signing in before the code expired.
@immutable
class SignInTimedOut implements Exception, ReadableError {
  const SignInTimedOut();
  @override
  String get message =>
      'The sign-in code expired. Start again to get a new one.';
  @override
  String toString() => message;
}

/// The app stopped waiting, because the person left the screen.
@immutable
class SignInCancelled implements Exception, ReadableError {
  const SignInCancelled();
  @override
  String get message => 'Sign-in was cancelled.';
  @override
  String toString() => message;
}

/// The app has not been allowed to do this particular thing yet.
///
/// Separate from [SignInExpired] because the account is fine and signing in
/// again is not the remedy: what is missing is consent for one set of scopes,
/// which either the person or their administrator grants once. In a tenant
/// that stops its users consenting to outside apps, only an administrator
/// can.
@immutable
class SignInNeedsConsent implements Exception, NeedsSignIn, ReadableError {
  const SignInNeedsConsent(this.message, {this.needsAdministrator = false});
  @override
  final String message;

  /// True when the tenant does not let its users consent at all. Signing in
  /// again then loops without ever succeeding, so the app offers no button
  /// and the message names the administrator instead.
  @override
  final bool needsAdministrator;

  @override
  String toString() => message;
}

/// The stored refresh token is no longer good. Unlike [SignInFailed] this
/// does not come back on its own; the account must sign in again.
@immutable
class SignInExpired implements Exception, NeedsSignIn, ReadableError {
  const SignInExpired(this.message);
  @override
  final String message;

  @override
  bool get needsAdministrator => false;

  @override
  String toString() => message;
}
