import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_token.dart';

/// The device code flow, against a fake token endpoint.
///
/// Everything here is about the polling loop and the failure paths, because
/// those are what a person meets when something goes wrong and they are the
/// parts that cannot be checked by signing in once and seeing it work.
void main() {
  /// A clock that only moves when a test moves it, and a sleep that moves it.
  /// Real waits would make this suite take minutes; worse, a poll loop with a
  /// real sleep and a real clock cannot be made to hit its expiry
  /// deterministically.
  late DateTime now;
  late List<Duration> slept;

  setUp(() {
    now = DateTime.utc(2026, 1, 1, 12);
    slept = [];
  });

  Future<void> sleep(Duration d) async {
    slept.add(d);
    now = now.add(d);
  }

  MicrosoftOAuth oauthWith(
    Future<http.Response> Function(http.Request request) handler,
  ) =>
      MicrosoftOAuth(
        clientId: 'test-client-id',
        httpClient: http_testing.MockClient(handler),
        clock: () => now,
        sleep: sleep,
        authority: 'https://login.example/consumers/oauth2/v2.0',
      );

  http.Response json(Map<String, Object?> body, {int status = 200}) =>
      http.Response(jsonEncode(body), status,
          headers: const {'content-type': 'application/json'});

  http.Response pending() => json(
        {
          'error': 'authorization_pending',
          'error_description': 'AADSTS70016: Pending end-user authorization.',
        },
        status: 400,
      );

  http.Response tokens() => json({
        'access_token': 'access-1',
        'refresh_token': 'refresh-1',
        'expires_in': 3599,
        'token_type': 'Bearer',
      });

  group('requesting a code to show the user', () {
    test('asks for the mailbox, send and offline scopes', () async {
      late String body;
      final oauth = oauthWith((request) async {
        body = request.body;
        return json({
          'device_code': 'dev-code',
          'user_code': 'ABCD-EFGH',
          'verification_uri': 'https://microsoft.com/devicelogin',
          'expires_in': 900,
          'interval': 5,
        });
      });

      final prompt = await oauth.requestDeviceCode();

      final scope = Uri.splitQueryString(body)['scope'];
      expect(
        scope,
        'https://graph.microsoft.com/Mail.ReadWrite '
        'https://graph.microsoft.com/Mail.Send offline_access',
        reason: 'One resource, so one token and one consent. Mixing a Graph '
            'scope with an outlook.office.com one is refused outright.',
      );
      expect(Uri.splitQueryString(body)['client_id'], 'test-client-id');
      expect(prompt.userCode, 'ABCD-EFGH');
      expect(prompt.verificationUri.host, 'microsoft.com');
      expect(prompt.expiresAt, now.add(const Duration(seconds: 900)));
    });

    test('a response missing the codes is an error, not a blank screen',
        () async {
      final oauth = oauthWith((_) async => json({'expires_in': 900}));

      await expectLater(
        oauth.requestDeviceCode(),
        throwsA(isA<SignInFailed>()),
      );
    });
  });

  group('waiting for the person to finish signing in', () {
    test('keeps polling while Microsoft says it is pending', () async {
      var calls = 0;
      final oauth = oauthWith((_) async {
        calls++;
        return calls < 3 ? pending() : tokens();
      });

      final token = await oauth.awaitToken(_prompt(now));

      expect(calls, 3);
      expect(token.accessToken, 'access-1');
      expect(token.refreshToken, 'refresh-1');
      expect(token.expiresAt, now.add(const Duration(seconds: 3599)));
    });

    test('waits the interval the server asked for before each poll', () async {
      var calls = 0;
      final oauth = oauthWith((_) async {
        calls++;
        return calls < 3 ? pending() : tokens();
      });

      await oauth.awaitToken(
        _prompt(now, interval: const Duration(seconds: 7)),
      );

      expect(slept, everyElement(const Duration(seconds: 7)));
    });

    test('backs off by five seconds when told to slow down', () async {
      // Not in Microsoft's documented error list, but RFC 8628 defines it and
      // their servers send it. Polling straight through it gets throttled.
      var calls = 0;
      final oauth = oauthWith((_) async {
        calls++;
        if (calls == 1) {
          return json({'error': 'slow_down'}, status: 400);
        }
        return calls < 3 ? pending() : tokens();
      });

      await oauth.awaitToken(
        _prompt(now, interval: const Duration(seconds: 5)),
      );

      expect(
        slept,
        [
          const Duration(seconds: 5),
          const Duration(seconds: 10),
          const Duration(seconds: 10),
        ],
      );
    });

    test('stops when the person declines on the consent screen', () async {
      final oauth = oauthWith(
        (_) async => json({'error': 'authorization_declined'}, status: 400),
      );

      await expectLater(
        oauth.awaitToken(_prompt(now)),
        throwsA(isA<SignInDeclined>()),
      );
    });

    test('stops when the code expires server-side', () async {
      final oauth = oauthWith(
        (_) async => json({'error': 'expired_token'}, status: 400),
      );

      await expectLater(
        oauth.awaitToken(_prompt(now)),
        throwsA(isA<SignInTimedOut>()),
      );
    });

    test('gives up on its own once the code is past its expiry', () async {
      // The server may keep answering "pending" forever if nobody ever opens
      // the page. Without this check the loop polls until the app is killed.
      final oauth = oauthWith((_) async => pending());

      await expectLater(
        oauth.awaitToken(
          _prompt(now, expiresIn: const Duration(seconds: 30)),
        ),
        throwsA(isA<SignInTimedOut>()),
      );
    });

    test('stops when the screen is left, without waiting for the code',
        () async {
      // Backing out of add-account resolves the stop signal. The poll must
      // end there rather than carrying on in the background against a screen
      // that is gone.
      final oauth = oauthWith((_) async => pending());

      await expectLater(
        oauth.awaitToken(
          _prompt(now),
          stopSignal: Future<void>.value(),
        ),
        throwsA(isA<SignInCancelled>()),
      );
    });

    test('names the public-client switch when that is what is wrong',
        () async {
      // AADSTS7000218 reads as "the request body must contain
      // client_assertion or client_secret", which sends people looking for a
      // secret they should not have. It means "Allow public client flows" is
      // off.
      final oauth = oauthWith(
        (_) async => json({
          'error': 'invalid_client',
          'error_description':
              'AADSTS7000218: The request body must contain the following '
                  'parameter: client_assertion or client_secret.',
        }, status: 400),
      );

      await expectLater(
        oauth.awaitToken(_prompt(now)),
        throwsA(
          isA<SignInFailed>().having(
            (e) => e.message,
            'message',
            contains('Allow public client flows'),
          ),
        ),
      );
    });
  });

  group('refreshing', () {
    final stored = OAuthToken(
      accessToken: 'old-access',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.utc(2026, 1, 1, 11),
    );

    test('spends the refresh token for a new pair', () async {
      late String body;
      final oauth = oauthWith((request) async {
        body = request.body;
        return json({
          'access_token': 'access-2',
          'refresh_token': 'refresh-2',
          'expires_in': 3599,
        });
      });

      final token = await oauth.refresh(stored);

      final form = Uri.splitQueryString(body);
      expect(form['grant_type'], 'refresh_token');
      expect(form['refresh_token'], 'refresh-1');
      expect(token.accessToken, 'access-2');
      expect(token.refreshToken, 'refresh-2');
    });

    test('keeps the old refresh token when the response omits a new one',
        () async {
      // Microsoft usually rotates it, but is not obliged to. Treating a
      // missing one as "signed out" would sign the account out for no reason.
      final oauth = oauthWith(
        (_) async => json({'access_token': 'access-2', 'expires_in': 3599}),
      );

      final token = await oauth.refresh(stored);

      expect(token.refreshToken, 'refresh-1');
    });

    test('a rejected refresh token means signing in again', () async {
      final oauth = oauthWith(
        (_) async => json({
          'error': 'invalid_grant',
          'error_description': 'AADSTS50173: The provided grant has expired.',
        }, status: 400),
      );

      await expectLater(
        oauth.refresh(stored),
        throwsA(isA<SignInExpired>()),
      );
    });

    test('a network failure does not mean signing in again', () async {
      // The difference matters: SignInExpired makes the app throw the stored
      // token away. Doing that because of a tunnel or a captive portal would
      // sign the account out over a blip it could have waited out.
      final oauth = oauthWith((_) async => throw const SocketFailure());

      await expectLater(
        oauth.refresh(stored),
        throwsA(isA<SignInFailed>()),
      );
    });

    test('a server error does not mean signing in again', () async {
      final oauth = oauthWith(
        (_) async => http.Response('<html>502</html>', 502),
      );

      await expectLater(
        oauth.refresh(stored),
        throwsA(isA<SignInFailed>()),
      );
    });
  });
}

DeviceCodePrompt _prompt(
  DateTime now, {
  Duration interval = const Duration(seconds: 5),
  Duration expiresIn = const Duration(minutes: 15),
}) =>
    DeviceCodePrompt(
      deviceCode: 'dev-code',
      userCode: 'ABCD-EFGH',
      verificationUri: Uri.parse('https://microsoft.com/devicelogin'),
      expiresAt: now.add(expiresIn),
      interval: interval,
    );

/// Stands in for whatever dart:io throws when there is no network. The type
/// does not matter to the code under test, only that it is not an OAuth error.
class SocketFailure implements Exception {
  const SocketFailure();
}
