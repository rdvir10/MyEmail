import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/auth/oauth_token_repository.dart';
import 'package:myemail/data/compose/graph_sender.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/draft.dart';

/// Sending through Microsoft Graph.
///
/// SMTP is not an option for a Microsoft account: Microsoft disables it for
/// every tenant by default, recommends against enabling it, and blocks it
/// outright wherever security defaults are on.
void main() {
  em.MimeMessage message({String body = 'Hello'}) {
    final builder = em.MessageBuilder()
      ..from = [em.MailAddress('Ron', 'me@example.com')]
      ..to = [em.MailAddress(null, 'someone@example.com')]
      ..subject = 'A subject';
    builder.addText(body);
    return builder.buildMimeMessage();
  }

  GraphSender senderWith(
    Future<http.Response> Function(http.Request request) handler, {
    Future<String> Function({bool force})? token,
    int? maxMimeBytes,
  }) =>
      GraphSender(
        accessToken: token ?? ({bool force = false}) async => 'graph-token',
        httpClient: http_testing.MockClient(handler),
        maxMimeBytes: maxMimeBytes ?? GraphSender.defaultMaxMimeBytes,
      );

  group('a successful send', () {
    test('posts base64 MIME to sendMail and accepts 202', () async {
      late http.Request seen;
      final sender = senderWith((request) async {
        seen = request;
        return http.Response('', 202);
      });

      await sender.send(message(body: 'The body text'));

      expect(seen.url.toString(),
          'https://graph.microsoft.com/v1.0/me/sendMail');
      expect(seen.method, 'POST');
      // text/plain is what tells Graph the body is MIME. application/json is
      // rejected as malformed JSON, which reads as a bug in the message.
      expect(seen.headers['Content-Type'], startsWith('text/plain'));
      expect(seen.headers['Authorization'], 'Bearer graph-token');

      final mime = utf8.decode(base64Decode(seen.body));
      expect(mime, contains('The body text'));
      expect(mime, contains('someone@example.com'));
    });

    test('asks for a Graph token, not the mailbox one', () async {
      // An access token is issued for one resource. An IMAP token here is
      // refused, and the refusal reads as a broken sign-in rather than as the
      // wrong token having been fetched.
      var asked = 0;
      final sender = senderWith(
        (_) async => http.Response('', 202),
        token: ({bool force = false}) async {
          asked++;
          return 'graph-token';
        },
      );

      await sender.send(message());

      expect(asked, 1);
    });
  });

  group('when Graph refuses', () {
    Future<void> expectMessage(
      int status,
      String code,
      Matcher matcher, {
      Matcher? type,
    }) async {
      final sender = senderWith(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': code, 'message': 'internal detail'},
          }),
          status,
          headers: const {'content-type': 'application/json'},
        ),
      );

      await expectLater(
        sender.send(message()),
        throwsA(
          type ??
              isA<SendFailed>()
                  .having((e) => e.message, 'message', matcher),
        ),
      );
    }

    test('a refused send names the administrator for a work account',
        () async {
      await expectMessage(
        403,
        'ErrorAccessDenied',
        contains('administrator'),
        type: isA<AuthenticationFailed>().having(
          (e) => e.message,
          'message',
          contains('administrator'),
        ),
      );
    });

    test('a dead token says to sign in again, not that sending failed',
        () async {
      await expectMessage(
        401,
        'InvalidAuthenticationToken',
        contains('sign in again'),
        type: isA<AuthenticationFailed>().having(
          (e) => e.message,
          'message',
          contains('sign in again'),
        ),
      );
    });

    test('throttling says to wait rather than looking permanent', () async {
      await expectMessage(429, 'TooManyRequests', contains('Wait a minute'));
    });

    test('malformed MIME is owned by the app, not blamed on the user',
        () async {
      await expectMessage(
        400,
        'ErrorMimeContentInvalidBase64String',
        contains('The app built a message'),
      );
    });

    test('an unrecognised refusal still says what Graph called it', () async {
      await expectMessage(
        400,
        'SomethingNew',
        contains('SomethingNew'),
      );
    });

    test('no network is a connection failure, not a rejected message',
        () async {
      final sender = senderWith((_) async => throw const SocketLike());

      await expectLater(
        sender.send(message()),
        throwsA(isA<ConnectionFailed>()),
      );
    });
  });

  test('an oversized message is refused before it is uploaded', () async {
    // Graph caps the request body at 4 MB and base64 inflates by a third.
    // Past that it wants an upload session, which this does not do; failing
    // here names the reason instead of returning a bare 413.
    var posted = false;
    final sender = senderWith(
      (_) async {
        posted = true;
        return http.Response('', 202);
      },
      // A small limit rather than a large message: the check is what is under
      // test, and encoding three real megabytes takes minutes.
      maxMimeBytes: 200,
    );

    await expectLater(
      sender.send(message(body: 'x' * 500)),
      throwsA(isA<SendFailed>()
          .having((e) => e.message, 'message', contains('too large'))),
    );
    expect(posted, isFalse);
  });

  group('tokens for two resources', () {
    late MemoryCredentialStore secrets;
    late DateTime now;

    setUp(() {
      secrets = MemoryCredentialStore();
      now = DateTime.utc(2026, 9, 18, 12);
    });

    OAuthTokenRepository repositoryWith(
      Future<http.Response> Function(http.Request request) handler,
    ) =>
        OAuthTokenRepository(
          credentialStore: secrets,
          clock: () => now,
          oauthClient: () => MicrosoftOAuth(
            clientId: 'test-client-id',
            clock: () => now,
            authority: 'https://login.example/common/oauth2/v2.0',
            httpClient: http_testing.MockClient(handler),
          ),
        );

    Future<void> storeToken() => secrets.writeSecret(
          'acct-1',
          OAuthToken(
            accessToken: 'imap-access',
            refreshToken: 'refresh-1',
            expiresAt: now.add(const Duration(hours: 1)),
          ).toStoredJson(),
        );

    test('a Graph token is fetched with the Graph scopes', () async {
      await storeToken();
      late String body;
      final repository = repositoryWith((request) async {
        body = request.body;
        return http.Response(
          jsonEncode({
            'access_token': 'graph-access',
            'refresh_token': 'refresh-2',
            'expires_in': 3599,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final token = await repository.accessToken(
        'acct-1',
        scopes: MicrosoftOAuth.graphScopes,
      );

      expect(token, 'graph-access');
      expect(
        Uri.splitQueryString(body)['scope'],
        'https://graph.microsoft.com/Mail.Send offline_access',
      );
    });

    test('the rotated refresh token is stored even though the access token '
        'was for something else', () async {
      // The trap. Microsoft rotates the refresh token on every exchange and
      // retires the one just spent, whatever resource was asked for. Keeping
      // the old one would sign the account out at its next ordinary refresh,
      // with nothing to connect that to a send an hour earlier.
      await storeToken();
      final repository = repositoryWith(
        (_) async => http.Response(
          jsonEncode({
            'access_token': 'graph-access',
            'refresh_token': 'refresh-2',
            'expires_in': 3599,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );

      await repository.accessToken(
        'acct-1',
        scopes: MicrosoftOAuth.graphScopes,
      );

      final stored = OAuthToken.fromStoredJson(
        await secrets.readSecret('acct-1'),
      );
      expect(stored!.refreshToken, 'refresh-2');
      expect(stored.accessToken, 'imap-access',
          reason: 'the stored access token is the one IMAP connects with, and '
              'must not be replaced by a Graph one');
    });

    test('a Graph token is reused rather than refetched', () async {
      await storeToken();
      var calls = 0;
      final repository = repositoryWith((_) async {
        calls++;
        return http.Response(
          jsonEncode({
            'access_token': 'graph-access',
            'refresh_token': 'refresh-$calls',
            'expires_in': 3599,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      await repository.accessToken('acct-1',
          scopes: MicrosoftOAuth.graphScopes);
      await repository.accessToken('acct-1',
          scopes: MicrosoftOAuth.graphScopes);

      expect(calls, 1);
    });

    test('missing consent is not reported as a dead sign-in', () async {
      // Different remedy: the account is fine and needs permission granted
      // once, which in a locked-down tenant only an administrator can do.
      // Telling someone to sign in again would send them round in a circle.
      await storeToken();
      final repository = repositoryWith(
        (_) async => http.Response(
          jsonEncode({
            'error': 'invalid_grant',
            'error_description':
                'AADSTS65001: The user or administrator has not consented to '
                    'use the application.',
          }),
          400,
          headers: const {'content-type': 'application/json'},
        ),
      );

      await expectLater(
        repository.accessToken('acct-1', scopes: MicrosoftOAuth.graphScopes),
        throwsA(isA<SignInNeedsConsent>()),
      );
    });
  });
}

class SocketLike implements Exception {
  const SocketLike();
}
