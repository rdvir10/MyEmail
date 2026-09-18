import 'dart:convert';

import 'package:crypto/crypto.dart' as legacy_crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/pkce.dart';

/// Authorization code flow with PKCE, which is how the app signs in to
/// Microsoft.
///
/// It replaced the device code flow because security defaults block that one
/// outright — AADSTS530035 — and from 1 July 2026 every new tenant has them
/// on.
void main() {
  MicrosoftOAuth oauthWith([
    Future<http.Response> Function(http.Request request)? handler,
  ]) =>
      MicrosoftOAuth(
        clientId: 'test-client-id',
        authority: 'https://login.example/common/oauth2/v2.0',
        clock: () => DateTime.utc(2026, 9, 18, 12),
        httpClient: http_testing.MockClient(
          handler ?? (_) async => http.Response('{}', 200),
        ),
      );

  group('the verifier and challenge', () {
    test('the challenge is the SHA-256 of the verifier, base64url, unpadded',
        () async {
      // Checked against a second implementation rather than against itself:
      // a bug that hashed the wrong bytes would otherwise round-trip happily
      // and only fail against Microsoft.
      final pkce = await PkcePair.generate();

      final expected = base64UrlEncode(
        legacy_crypto.sha256.convert(ascii.encode(pkce.verifier)).bytes,
      ).replaceAll('=', '');

      expect(pkce.challenge, expected);
    });

    test('the verifier is within the length the spec allows', () async {
      final pkce = await PkcePair.generate();

      expect(pkce.verifier.length, greaterThanOrEqualTo(43));
      expect(pkce.verifier.length, lessThanOrEqualTo(128));
    });

    test('nothing in it needs escaping in a URL', () async {
      final pkce = await PkcePair.generate();

      expect(pkce.verifier, matches(RegExp(r'^[A-Za-z0-9\-._~]+$')));
      expect(pkce.challenge, matches(RegExp(r'^[A-Za-z0-9\-_]+$')));
    });

    test('two pairs are not the same', () async {
      final a = await PkcePair.generate();
      final b = await PkcePair.generate();

      expect(a.verifier, isNot(b.verifier));
    });

    test('the verifier never appears in toString', () async {
      // This type reaches logs.
      final pkce = await PkcePair.generate();

      expect(pkce.toString(), isNot(contains(pkce.verifier)));
    });
  });

  group('the authorization request', () {
    test('carries the challenge and never the verifier', () async {
      // The verifier is the whole point: it stays on the device and is only
      // sent when the code is redeemed. In the URL it would be worthless.
      final pkce = await PkcePair.generate();

      final url = oauthWith().authorizationUrl(pkce: pkce, state: 'st-1');

      expect(url.queryParameters['code_challenge'], pkce.challenge);
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.toString(), isNot(contains(pkce.verifier)));
    });

    test('asks for a code, the right scopes and the documented redirect',
        () async {
      final url = await PkcePair.generate().then(
        (pkce) => oauthWith().authorizationUrl(pkce: pkce, state: 'st-1'),
      );

      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['client_id'], 'test-client-id');
      expect(
        url.queryParameters['redirect_uri'],
        'https://login.microsoftonline.com/common/oauth2/nativeclient',
      );
      expect(
        url.queryParameters['scope'],
        'https://outlook.office.com/IMAP.AccessAsUser.All '
        'https://outlook.office.com/SMTP.Send offline_access',
      );
    });

    test('always asks which account, so a second mailbox is not assumed',
        () async {
      // Without this the browser reuses whatever session it has and adds the
      // first account again, with nothing on screen to say so.
      final url = await PkcePair.generate().then(
        (pkce) => oauthWith().authorizationUrl(pkce: pkce, state: 'st-1'),
      );

      expect(url.queryParameters['prompt'], 'select_account');
    });

    test('passes on the address already typed', () async {
      final url = await PkcePair.generate().then(
        (pkce) => oauthWith().authorizationUrl(
          pkce: pkce,
          state: 'st-1',
          loginHint: 'me@example.com',
        ),
      );

      expect(url.queryParameters['login_hint'], 'me@example.com');
    });
  });

  group('reading the redirect', () {
    const redirect =
        'https://login.microsoftonline.com/common/oauth2/nativeclient';

    test('an ordinary page during sign-in is not the redirect', () {
      // Every navigation goes through this. Mistaking one for the redirect
      // would abort the sign-in halfway.
      final oauth = oauthWith();

      expect(
        oauth.codeFromRedirect(
          Uri.parse('https://login.microsoftonline.com/common/login'),
          expectedState: 'st-1',
        ),
        isNull,
      );
    });

    test('the code comes out of the redirect', () {
      final oauth = oauthWith();

      expect(
        oauth.codeFromRedirect(
          Uri.parse('$redirect?code=the-code&state=st-1'),
          expectedState: 'st-1',
        ),
        'the-code',
      );
    });

    test('a redirect from someone else is refused', () {
      // The state ties the response to the request this app made. Redeeming a
      // code that arrived out of nowhere is how an attacker gets their account
      // attached to someone else's app.
      final oauth = oauthWith();

      expect(
        () => oauth.codeFromRedirect(
          Uri.parse('$redirect?code=the-code&state=someone-elses'),
          expectedState: 'st-1',
        ),
        throwsA(isA<SignInFailed>()),
      );
    });

    test('pressing no on the consent screen reads as declined', () {
      final oauth = oauthWith();

      expect(
        () => oauth.codeFromRedirect(
          Uri.parse('$redirect?error=access_denied&state=st-1'),
          expectedState: 'st-1',
        ),
        throwsA(isA<SignInDeclined>()),
      );
    });

    test('a blocked sign-in says which switch is wrong', () {
      final oauth = oauthWith();

      expect(
        () => oauth.codeFromRedirect(
          Uri.parse(
            '$redirect?error=invalid_client&error_description='
            '${Uri.encodeComponent('AADSTS7000218: The request body must '
                'contain the following parameter: client_assertion or '
                'client_secret.')}',
          ),
          expectedState: 'st-1',
        ),
        throwsA(isA<SignInFailed>().having(
          (e) => e.message,
          'message',
          contains('Allow public client flows'),
        )),
      );
    });

    test('a redirect with neither a code nor an error is an error', () {
      final oauth = oauthWith();

      expect(
        () => oauth.codeFromRedirect(
          Uri.parse('$redirect?state=st-1'),
          expectedState: 'st-1',
        ),
        throwsA(isA<SignInFailed>()),
      );
    });
  });

  group('redeeming the code', () {
    test('sends the verifier and gets a token pair back', () async {
      late String body;
      final oauth = oauthWith((request) async {
        body = request.body;
        return http.Response(
          jsonEncode({
            'access_token': 'access-1',
            'refresh_token': 'refresh-1',
            'expires_in': 3599,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final pkce = await PkcePair.generate();

      final token = await oauth.exchangeCode(code: 'the-code', pkce: pkce);

      final form = Uri.splitQueryString(body);
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'the-code');
      expect(form['code_verifier'], pkce.verifier);
      expect(form['redirect_uri'], MicrosoftOAuth.redirectUri);
      expect(token.accessToken, 'access-1');
      expect(token.refreshToken, 'refresh-1');
    });

    test('a refusal at redemption is reported, not swallowed', () async {
      final oauth = oauthWith(
        (_) async => http.Response(
          jsonEncode({
            'error': 'invalid_grant',
            'error_description': 'AADSTS70008: The code has expired.',
          }),
          400,
          headers: const {'content-type': 'application/json'},
        ),
      );

      await expectLater(
        oauth.exchangeCode(code: 'stale', pkce: await PkcePair.generate()),
        throwsA(isA<SignInFailed>()),
      );
    });
  });
}
