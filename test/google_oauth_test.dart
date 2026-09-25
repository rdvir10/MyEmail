import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/google_oauth.dart';
import 'package:myemail/data/auth/google_oauth_config.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart'
    show
        SignInDeclined,
        SignInExpired,
        SignInFailed,
        SignInNeedsConsent,
        SignInUnreachable;
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/auth/pkce.dart';

/// Signing in to Google: the request, the way back, and the tokens.
void main() {
  const clientId = '1234-abcd.apps.googleusercontent.com';
  const scheme = 'com.googleusercontent.apps.1234-abcd';
  final now = DateTime.utc(2026, 9, 25, 9);

  /// An ID token as Google signs it: three parts, the middle one the claims.
  /// The signature is not checked, so anything will do for it.
  String idToken(Map<String, Object?> claims) =>
      'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

  GoogleOAuth oauth({
    Future<http.Response> Function(http.Request request)? handler,
  }) =>
      GoogleOAuth(
        clientId: clientId,
        clock: () => now,
        httpClient: http_testing.MockClient(
          handler ?? (_) async => http.Response('{}', 500),
        ),
      );

  http.Response json(Map<String, Object?> body, {int status = 200}) =>
      http.Response(jsonEncode(body), status,
          headers: const {'content-type': 'application/json'});

  group('the redirect scheme', () {
    test('is the client ID reversed, as Google wants for Android', () {
      expect(googleRedirectScheme(clientId), scheme);
      expect(googleRedirectUri(clientId), '$scheme:/oauth2redirect');
    });
  });

  group('the request', () {
    test('asks for mail, the calendar and who signed in, offline', () async {
      final pkce = await PkcePair.generate();
      final url = oauth().authorizationUrl(
        pkce: pkce,
        state: 'st-1',
        loginHint: 'ron@gmail.com',
      );
      final q = url.queryParameters;

      expect(url.host, 'accounts.google.com');
      expect(q['client_id'], clientId);
      expect(q['redirect_uri'], '$scheme:/oauth2redirect');
      expect(q['response_type'], 'code');
      expect(q['scope'], contains('https://mail.google.com/'));
      expect(q['scope'], contains('calendar.events'));
      expect(q['scope'], contains('openid'));
      expect(q['access_type'], 'offline',
          reason: 'without it there is no refresh token');
      expect(q['prompt'], contains('consent'),
          reason: 'a sign-in again must come back with a refresh token too');
      expect(q['code_challenge'], pkce.challenge);
      expect(q['code_challenge_method'], 'S256');
      expect(q['state'], 'st-1');
      expect(q['login_hint'], 'ron@gmail.com');
      expect(url.toString(), isNot(contains(pkce.verifier)),
          reason: 'the verifier never goes near the browser');
    });
  });

  group('the way back', () {
    final o = oauth();

    test('any other URL is not it', () {
      expect(
        o.codeFromRedirect(Uri.parse('https://example.com/?code=x&state=s'),
            expectedState: 's'),
        isNull,
      );
    });

    test('carries the code, whatever case Android gives the scheme', () {
      expect(
        o.codeFromRedirect(
          Uri.parse('${scheme.toUpperCase()}:/oauth2redirect?code=c-1&state=s'),
          expectedState: 's',
        ),
        'c-1',
      );
    });

    test('a refusal is said in words about Google', () {
      expect(
        () => o.codeFromRedirect(
          Uri.parse('$scheme:/oauth2redirect?error=access_denied&state=s'),
          expectedState: 's',
        ),
        throwsA(isA<SignInDeclined>()
            .having((e) => e.message, 'message', contains('Google'))),
      );
    });

    test('a state that is not this request\'s is refused', () {
      expect(
        () => o.codeFromRedirect(
          Uri.parse('$scheme:/oauth2redirect?code=c-1&state=other'),
          expectedState: 's',
        ),
        throwsA(isA<SignInFailed>()),
      );
    });
  });

  group('redeeming the code', () {
    test('sends the verifier and comes back with the token and who it is for',
        () async {
      final pkce = await PkcePair.generate();
      late Map<String, String> form;
      final o = oauth(handler: (request) async {
        expect(request.url.toString(), GoogleOAuth.defaultTokenEndpoint);
        form = Uri.splitQueryString(request.body);
        return json({
          'access_token': 'ya29.access',
          'refresh_token': '1//refresh',
          'expires_in': 3599,
          'scope': GoogleOAuth.scopes.join(' '),
          'id_token': idToken({'sub': '10203', 'email': 'Ron@Gmail.com'}),
        });
      });

      final result = await o.exchangeCode(code: 'c-1', pkce: pkce);

      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'c-1');
      expect(form['code_verifier'], pkce.verifier);
      expect(form['redirect_uri'], '$scheme:/oauth2redirect');
      expect(form['client_id'], clientId);
      expect(form.containsKey('client_secret'), isFalse,
          reason: 'a phone app has none');
      expect(result.token.accessToken, 'ya29.access');
      expect(result.token.refreshToken, '1//refresh');
      expect(result.token.expiresAt, now.add(const Duration(seconds: 3599)));
      expect(result.identity?.email, 'ron@gmail.com');
      expect(result.identity?.subject, '10203');
    });

    test('with no ID token, nobody is named', () async {
      final o = oauth(handler: (_) async => json({
            'access_token': 'a',
            'refresh_token': 'r',
            'expires_in': 3600,
          }));
      final result =
          await o.exchangeCode(code: 'c', pkce: await PkcePair.generate());
      expect(result.identity, isNull);
    });

    test('the one misconfiguration says what to click', () async {
      final o = oauth(handler: (_) async =>
          json({'error': 'redirect_uri_mismatch'}, status: 400));
      final pkce = await PkcePair.generate();
      expect(
        () => o.exchangeCode(code: 'c', pkce: pkce),
        throwsA(isA<SignInFailed>().having(
            (e) => e.message, 'message', contains('custom URI schemes'))),
      );
    });
  });

  group('a desktop client', () {
    // The one kind of client Google lets an unreviewed app make with a way
    // back into the app: it comes with a secret that is not one, and takes
    // the loopback address as its redirect.
    GoogleOAuth desktop({
      required Future<http.Response> Function(http.Request request) handler,
    }) =>
        GoogleOAuth(
          clientId: clientId,
          clientSecret: 'GOCSPX-not-really-secret',
          clock: () => now,
          httpClient: http_testing.MockClient(handler),
        );

    test('the request goes to the loopback address it was given', () async {
      final pkce = await PkcePair.generate();
      final url = desktop(handler: (_) async => json({})).authorizationUrl(
        pkce: pkce,
        state: 's',
        redirectUri: 'http://127.0.0.1:43210/',
      );
      expect(url.queryParameters['redirect_uri'], 'http://127.0.0.1:43210/');
    });

    test('the way back is that address, port and all', () {
      final o = desktop(handler: (_) async => json({}));
      const mine = 'http://127.0.0.1:43210/';
      expect(
        o.codeFromRedirect(
          Uri.parse('http://127.0.0.1:43210/?code=c-1&state=s'),
          expectedState: 's',
          redirectUri: mine,
        ),
        'c-1',
      );
      expect(
        o.codeFromRedirect(
          Uri.parse('http://127.0.0.1:43211/?code=c-1&state=s'),
          expectedState: 's',
          redirectUri: mine,
        ),
        isNull,
        reason: 'another port is another sign-in',
      );
      expect(
        o.codeFromRedirect(
          Uri.parse('$scheme:/oauth2redirect?code=c-1&state=s'),
          expectedState: 's',
        ),
        'c-1',
        reason: 'the custom scheme still counts, with no address given',
      );
    });

    test('the secret and the address go with the code', () async {
      final pkce = await PkcePair.generate();
      late Map<String, String> form;
      final o = desktop(handler: (request) async {
        form = Uri.splitQueryString(request.body);
        return json({
          'access_token': 'a',
          'refresh_token': 'r',
          'expires_in': 3600,
        });
      });

      await o.exchangeCode(
        code: 'c-1',
        pkce: pkce,
        redirectUri: 'http://127.0.0.1:43210/',
      );

      expect(form['client_secret'], 'GOCSPX-not-really-secret');
      expect(form['redirect_uri'], 'http://127.0.0.1:43210/');
      expect(form['code_verifier'], pkce.verifier,
          reason: 'PKCE stays: the secret protects nothing on a phone');
    });

    test('and with every refresh', () async {
      late Map<String, String> form;
      final o = desktop(handler: (request) async {
        form = Uri.splitQueryString(request.body);
        return json({'access_token': 'a', 'expires_in': 3600});
      });
      await o.refresh(OAuthToken(
        accessToken: 'old',
        refreshToken: 'r',
        expiresAt: now,
      ));
      expect(form['client_secret'], 'GOCSPX-not-really-secret');
    });

    test('an Android client sends no secret, having none', () async {
      late Map<String, String> form;
      final o = oauth(handler: (request) async {
        form = Uri.splitQueryString(request.body);
        return json({'access_token': 'a', 'expires_in': 3600});
      });
      await o.refresh(OAuthToken(
        accessToken: 'old',
        refreshToken: 'r',
        expiresAt: now,
      ));
      expect(form.containsKey('client_secret'), isFalse);
    });
  });

  group('refreshing', () {
    final stored = OAuthToken(
      accessToken: 'old',
      refreshToken: '1//refresh',
      expiresAt: now.subtract(const Duration(minutes: 1)),
    );

    test('keeps the refresh token Google does not send back', () async {
      late Map<String, String> form;
      final o = oauth(handler: (request) async {
        form = Uri.splitQueryString(request.body);
        return json({
          'access_token': 'new',
          'expires_in': 3600,
          'scope': GoogleOAuth.scopes.join(' '),
        });
      });

      final refreshed = await o.refresh(stored);

      expect(form['grant_type'], 'refresh_token');
      expect(form['refresh_token'], '1//refresh');
      expect(refreshed.accessToken, 'new');
      expect(refreshed.refreshToken, '1//refresh');
    });

    test('a refresh token Google no longer takes is a sign-out', () async {
      final o = oauth(handler: (_) async => json(
          {'error': 'invalid_grant', 'error_description': 'Bad Request'},
          status: 400));
      expect(() => o.refresh(stored), throwsA(isA<SignInExpired>()));
    });

    test('a sign-in from before the calendar was asked for needs consent',
        () async {
      // The refresh works, and the token it gives cannot touch the calendar:
      // Google grants what was consented to at sign-in and no more.
      final o = oauth(handler: (_) async => json({
            'access_token': 'new',
            'expires_in': 3600,
            'scope': 'https://mail.google.com/ openid email',
          }));

      expect(
        () => o.refresh(stored,
            scopes: const ['https://www.googleapis.com/auth/calendar.events']),
        throwsA(isA<SignInNeedsConsent>()
            .having((e) => e.needsAdministrator, 'needsAdministrator', isFalse)),
      );
      expect(await o.refresh(stored), isA<OAuthToken>(),
          reason: 'for mail alone the same sign-in is fine');
    });

    test('no connection is not a sign-out either', () async {
      final o = oauth(handler: (_) async => throw Exception('offline'));
      expect(() => o.refresh(stored), throwsA(isA<SignInUnreachable>()));
    });
  });
}
