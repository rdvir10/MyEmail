import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/mail_engine.dart';

/// What a Microsoft account does when its token is turned away, or cannot
/// be refreshed for want of a connection.
void main() {
  /// A token that looks fine here and that Microsoft no longer takes, and
  /// the one a forced refresh brings.
  Future<String> staleThenFresh({bool force = false}) async =>
      force ? 'fresh' : 'stale';

  /// Answers only the fresh token, and remembers what was presented.
  http_testing.MockClient graph(
    List<String> presented,
    http.Response Function() ok,
  ) =>
      http_testing.MockClient((request) async {
        final token = request.headers['Authorization']!;
        presented.add(token);
        if (token != 'Bearer fresh') {
          return http.Response(
            jsonEncode({
              'error': {'code': 'InvalidAuthenticationToken'},
            }),
            401,
          );
        }
        return ok();
      });

  test('a turned-away token is refreshed once, and the request goes through',
      () async {
    // It went straight to "sign in again", for up to an hour, on a tablet
    // whose clock ran a few minutes slow.
    final presented = <String>[];
    final api = GraphMailApi(
      accessToken: staleThenFresh,
      httpClient: graph(presented, () => http.Response('{"value": []}', 200)),
    );

    expect(await api.messages('inbox'), isEmpty);
    expect(presented, ['Bearer stale', 'Bearer fresh']);
  });

  test('and so is one fetching a file', () async {
    final presented = <String>[];
    final api = GraphMailApi(
      accessToken: staleThenFresh,
      httpClient: graph(presented, () => http.Response.bytes([1, 2, 3], 200)),
    );

    expect(await api.mimeBytes('m1'), [1, 2, 3]);
    expect(presented, ['Bearer stale', 'Bearer fresh']);
  });

  test('a second refusal is a real one', () async {
    final presented = <String>[];
    final api = GraphMailApi(
      accessToken: ({bool force = false}) async => 'stale',
      httpClient: graph(presented, () => http.Response('{}', 200)),
    );

    await expectLater(
      api.messages('inbox'),
      throwsA(isA<AuthenticationFailed>()),
    );
    expect(presented, hasLength(2), reason: 'once, not in a loop');
  });

  test('a refresh that cannot reach Microsoft is being offline', () async {
    // As a sign-in failure it went past every place that shows the cache
    // when there is no connection.
    final api = GraphMailApi(
      accessToken: ({bool force = false}) async =>
          throw const SignInUnreachable('Could not reach Microsoft to sign in.'),
      httpClient: http_testing.MockClient(
        (_) async => fail('nothing is sent without a token'),
      ),
    );

    await expectLater(api.messages('inbox'), throwsA(isA<ConnectionFailed>()));
    await expectLater(api.mimeBytes('m1'), throwsA(isA<ConnectionFailed>()));
  });

  test('a refresh Microsoft refused is still a sign-in problem', () async {
    final api = GraphMailApi(
      accessToken: ({bool force = false}) async =>
          throw const SignInExpired('Sign in again.'),
      httpClient: http_testing.MockClient((_) async => http.Response('{}', 200)),
    );

    await expectLater(api.messages('inbox'), throwsA(isA<SignInExpired>()));
  });
}
