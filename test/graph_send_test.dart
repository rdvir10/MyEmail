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
import 'dart:typed_data';

import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart' show MailAddress;

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

    test('a token turned away once is refreshed, and the send goes out',
        () async {
      final presented = <String?>[];
      final sender = senderWith(
        (request) async {
          presented.add(request.headers['Authorization']);
          return request.headers['Authorization'] == 'Bearer fresh'
              ? http.Response('', 202)
              : http.Response('{}', 401);
        },
        token: ({bool force = false}) async => force ? 'fresh' : 'stale',
      );

      await sender.send(message());

      expect(presented, ['Bearer stale', 'Bearer fresh']);
    });

    test('a refresh that cannot reach Microsoft says there is no connection',
        () async {
      final sender = senderWith(
        (_) async => fail('nothing is sent without a token'),
        token: ({bool force = false}) async =>
            throw const SignInUnreachable('Could not reach Microsoft.'),
      );

      await expectLater(
          sender.send(message()), throwsA(isA<ConnectionFailed>()));
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

  group('a message too large to post in one request', () {
    Account account() => const Account(
          id: 'a',
          displayName: 'Hadco',
          emailAddress: 'rdvir@hadco-metal.com',
          provider: MailProvider.outlook,
          authMethod: AuthMethod.oauth,
          colorValue: 0xFF0F6CBD,
        );

    Draft draftWith(List<DraftAttachment> attachments) => Draft(
          accountId: 'a',
          kind: ComposeKind.newMessage,
          to: const [MailAddress(email: 'someone@example.com')],
          subject: 'Drawings',
          htmlBody: '<p>Attached.</p>',
          attachments: attachments,
        );

    DraftAttachment file(String name, int size) => DraftAttachment(
          fileName: name,
          mimeType: 'application/pdf',
          bytes: Uint8List(size),
        );

    /// A Microsoft that answers the whole route: create the draft, take the
    /// attachments, send it.
    ({
      List<String> calls,
      List<String> ranges,
      GraphSender sender,
    }) fakeGraph({int maxMimeBytes = 4000}) {
      final calls = <String>[];
      final ranges = <String>[];
      final sender = GraphSender(
        accessToken: ({bool force = false}) async => 'graph-token',
        maxMimeBytes: maxMimeBytes,
        httpClient: http_testing.MockClient((request) async {
          final path = request.url.path;
          if (request.url.host == 'upload.example') {
            ranges.add(request.headers['Content-Range'] ?? '');
            final range = request.headers['Content-Range'] ?? '';
            final done = range.split('/').last;
            final end = range.split('-').last.split('/').first;
            final last = (int.parse(end) + 1) == int.parse(done);
            return http.Response('', last ? 201 : 202);
          }
          if (path.endsWith('/createUploadSession')) {
            calls.add('session');
            return http.Response(
              jsonEncode({'uploadUrl': 'https://upload.example/put'}),
              200,
            );
          }
          if (path.endsWith('/attachments')) {
            calls.add('attach');
            return http.Response(jsonEncode({'id': 'att-1'}), 201);
          }
          if (path.endsWith('/send')) {
            calls.add('send');
            return http.Response('', 202);
          }
          if (path.endsWith('/me/messages')) {
            calls.add('draft');
            return http.Response(jsonEncode({'id': 'draft-1'}), 201);
          }
          calls.add('sendMail');
          return http.Response('', 202);
        }),
      );
      return (calls: calls, ranges: ranges, sender: sender);
    }

    test('goes up as a draft, its files, and then a send', () async {
      final graph = fakeGraph();

      await graph.sender.sendDraft(
        draft: draftWith([file('drawing.pdf', 3000)]),
        account: account(),
      );

      expect(graph.calls, ['draft', 'attach', 'send']);
    });

    test('a small message still goes in one request', () async {
      // The common case must not get slower to make the rare one work.
      final graph = fakeGraph(maxMimeBytes: 1 << 20);

      await graph.sender.sendDraft(
        draft: draftWith(const []),
        account: account(),
      );

      expect(graph.calls, ['sendMail']);
    });

    test('a file too big to post goes up in chunks', () async {
      final graph = fakeGraph();
      final big = GraphSender.uploadChunkBytes + 10;

      await graph.sender.sendDraft(
        draft: draftWith([file('huge.pdf', big)]),
        account: account(),
      );

      expect(graph.calls, ['draft', 'session', 'send']);
      expect(graph.ranges, hasLength(2), reason: 'two chunks for one file');
      expect(graph.ranges.first,
          'bytes 0-${GraphSender.uploadChunkBytes - 1}/$big');
      expect(graph.ranges.last, 'bytes ${GraphSender.uploadChunkBytes}-'
          '${big - 1}/$big');
    });

    test('the chunks carry no bearer token, as Microsoft asks', () async {
      // The upload URL is already authorised, and sending a token with the
      // chunks is refused — a confusing way to fail on the last leg.
      String? auth;
      final sender = GraphSender(
        accessToken: ({bool force = false}) async => 'graph-token',
        maxMimeBytes: 4000,
        httpClient: http_testing.MockClient((request) async {
          if (request.url.host == 'upload.example') {
            auth = request.headers['Authorization'];
            return http.Response('', 201);
          }
          if (request.url.path.endsWith('/createUploadSession')) {
            return http.Response(
              jsonEncode({'uploadUrl': 'https://upload.example/put'}),
              200,
            );
          }
          if (request.url.path.endsWith('/me/messages')) {
            return http.Response(jsonEncode({'id': 'draft-1'}), 201);
          }
          return http.Response('', 202);
        }),
      );

      await sender.sendDraft(
        draft: draftWith([file('huge.pdf', GraphSender.uploadChunkBytes + 1)]),
        account: account(),
      );

      expect(auth, isNull);
    });

    test('a body too large on its own says so, and blames no attachment',
        () async {
      // A screenshot pasted into the message cannot be split off the way a
      // file can, so the advice has to be different.
      final graph = fakeGraph();

      await expectLater(
        graph.sender.sendDraft(
          draft: Draft(
            accountId: 'a',
            kind: ComposeKind.newMessage,
            to: const [MailAddress(email: 'someone@example.com')],
            subject: 'Look',
            htmlBody: '<p>${'x' * 5000}</p>',
          ),
          account: account(),
        ),
        throwsA(isA<SendFailed>().having(
          (e) => e.message,
          'message',
          allOf(contains('before any attachments'), contains('Pictures')),
        )),
      );
      expect(graph.calls, isEmpty, reason: 'nothing was uploaded');
    });

    test('more than Microsoft will ever take is refused before uploading',
        () async {
      final graph = fakeGraph();

      await expectLater(
        graph.sender.sendDraft(
          draft: draftWith([file('enormous.bin', GraphSender.maxTotalBytes + 1)]),
          account: account(),
        ),
        throwsA(isA<SendFailed>().having(
          (e) => e.message,
          'message',
          contains('nothing was sent'),
        )),
      );
      expect(graph.calls, isEmpty);
    });

    test('a failure part way leaves the message in Drafts and says so',
        () async {
      final sender = GraphSender(
        accessToken: ({bool force = false}) async => 'graph-token',
        maxMimeBytes: 4000,
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path.endsWith('/me/messages')) {
            return http.Response(jsonEncode({'id': 'draft-1'}), 201);
          }
          if (request.url.path.endsWith('/createUploadSession')) {
            return http.Response(
              jsonEncode({
                'error': {'code': 'ErrorAccessDenied'},
              }),
              403,
            );
          }
          return http.Response('', 202);
        }),
      );

      await expectLater(
        sender.sendDraft(
          draft: draftWith([file('huge.pdf', GraphSender.uploadChunkBytes + 1)]),
          account: account(),
        ),
        throwsA(isA<AuthenticationFailed>()),
      );
    });
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
        scopes: MicrosoftOAuth.scopes,
      );

      expect(token, 'graph-access');
      expect(
        Uri.splitQueryString(body)['scope'],
        'https://graph.microsoft.com/Mail.ReadWrite '
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
        scopes: MicrosoftOAuth.scopes,
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
          scopes: MicrosoftOAuth.scopes);
      await repository.accessToken('acct-1',
          scopes: MicrosoftOAuth.scopes);

      expect(calls, 1);
    });

    test('a scope never consented to says to sign in again, in words',
        () async {
      // What an account added before the app asked for mailbox reading meets.
      // Microsoft reports it as a paragraph with two trace IDs in it; showing
      // that to someone tells them nothing they can act on, and the remedy is
      // not the remove-and-re-add that a dead sign-in would need.
      await storeToken();
      final repository = repositoryWith(
        (_) async => http.Response(
          jsonEncode({
            'error': 'invalid_grant',
            'error_description':
                'AADSTS70000: The request was denied because one or more '
                    'scopes requested are unauthorized or expired. Trace ID: '
                    'abc63852-5724-4fe4-b9d3-e772f6310200',
          }),
          400,
          headers: const {'content-type': 'application/json'},
        ),
      );

      await expectLater(
        repository.accessToken('acct-1', scopes: MicrosoftOAuth.scopes),
        throwsA(isA<SignInNeedsConsent>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Sign in again'),
            isNot(contains('Trace ID')),
            isNot(contains('AADSTS')),
          ),
        )),
      );
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
        repository.accessToken('acct-1', scopes: MicrosoftOAuth.scopes),
        throwsA(isA<SignInNeedsConsent>()),
      );
    });
  });
}

class SocketLike implements Exception {
  const SocketLike();
}
