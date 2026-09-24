import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/auth/oauth_token_repository.dart';
import 'package:myemail/data/credential_store.dart';

/// Keeping an OAuth account in usable access tokens.
///
/// The cases worth the most here are the concurrent ones: two callers
/// wanting a token at once, which should cost one refresh, and an account
/// removed while its refresh is out, which must not get its sign-in written
/// back to the device.
void main() {
  late DateTime now;
  late MemoryCredentialStore secrets;
  late int refreshCalls;

  setUp(() {
    now = DateTime.utc(2026, 1, 1, 12);
    secrets = MemoryCredentialStore();
    refreshCalls = 0;
  });

  /// A token endpoint that issues a numbered pair per call, so a test can see
  /// how many refreshes actually happened and which one won.
  OAuthTokenRepository repositoryWith({
    Future<http.Response> Function(http.Request request)? handler,
  }) =>
      OAuthTokenRepository(
        credentialStore: secrets,
        clock: () => now,
        oauthClient: () => MicrosoftOAuth(
          clientId: 'test-client-id',
          clock: () => now,
          authority: 'https://login.example/consumers/oauth2/v2.0',
          httpClient: http_testing.MockClient(
            handler ??
                (_) async {
                  refreshCalls++;
                  return http.Response(
                    jsonEncode({
                      'access_token': 'access-$refreshCalls',
                      'refresh_token': 'refresh-$refreshCalls',
                      'expires_in': 3599,
                    }),
                    200,
                    headers: const {'content-type': 'application/json'},
                  );
                },
          ),
        ),
      );

  Future<void> storeToken({
    required String access,
    required Duration expiresIn,
  }) =>
      secrets.writeSecret(
        'acct-1',
        OAuthToken(
          accessToken: access,
          refreshToken: 'refresh-0',
          expiresAt: now.add(expiresIn),
        ).toStoredJson(),
      );

  test('a token with plenty of life left is used as it is', () async {
    await storeToken(access: 'access-0', expiresIn: const Duration(hours: 1));

    expect(await repositoryWith().accessToken('acct-1'), 'access-0');
    expect(refreshCalls, 0, reason: 'no network call was needed');
  });

  test('a token about to expire is refreshed before it is handed out',
      () async {
    // Four minutes is inside the five-minute margin. Handing this one out
    // would open an IMAP connection with a token that dies mid-sync.
    await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));

    expect(await repositoryWith().accessToken('acct-1'), 'access-1');
    expect(refreshCalls, 1);
  });

  test('the refreshed token is written back, not just returned', () async {
    await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));
    final repository = repositoryWith();

    await repository.accessToken('acct-1');

    final stored = OAuthToken.fromStoredJson(
      await secrets.readSecret('acct-1'),
    );
    expect(stored!.accessToken, 'access-1');
    expect(stored.refreshToken, 'refresh-1',
        reason: 'the newest refresh token must replace the spent one, which '
            'keeps only its own, earlier expiry');
  });

  test('force refreshes even a token that still looks fresh', () async {
    // What the transport does after the server rejects a token the clock said
    // was fine, which is what a drifted device clock looks like from here.
    await storeToken(access: 'access-0', expiresIn: const Duration(hours: 1));

    expect(
      await repositoryWith().accessToken('acct-1', force: true),
      'access-1',
    );
  });

  test('two callers at once cause one refresh, not two', () async {
    await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));

    // Hold the response open until both callers are definitely waiting, so
    // the race this guards against is the one actually being run.
    final gate = Completer<void>();
    final repository = repositoryWith(handler: (_) async {
      refreshCalls++;
      await gate.future;
      return http.Response(
        jsonEncode({
          'access_token': 'access-$refreshCalls',
          'refresh_token': 'refresh-$refreshCalls',
          'expires_in': 3599,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });

    final first = repository.accessToken('acct-1');
    final second = repository.accessToken('acct-1');
    await pumpEventQueue();
    gate.complete();

    expect(await first, 'access-1');
    expect(await second, 'access-1');
    expect(refreshCalls, 1,
        reason: 'the second caller must wait for the first refresh rather '
            'than starting its own and spending the same refresh token twice');
  });

  test('a failed refresh does not wedge the account', () async {
    // whenComplete rather than then on the in-flight slot. If a failure left
    // the slot occupied, every later attempt would await a dead future and
    // the account would stay broken until the app restarted.
    await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));

    var attempt = 0;
    final repository = repositoryWith(handler: (_) async {
      attempt++;
      if (attempt == 1) {
        return http.Response(
          jsonEncode({'error': 'temporarily_unavailable'}),
          503,
          headers: const {'content-type': 'application/json'},
        );
      }
      refreshCalls++;
      return http.Response(
        jsonEncode({
          'access_token': 'access-$refreshCalls',
          'refresh_token': 'refresh-$refreshCalls',
          'expires_in': 3599,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });

    await expectLater(
      repository.accessToken('acct-1'),
      throwsA(isA<SignInFailed>()),
    );
    expect(await repository.accessToken('acct-1'), 'access-1');
  });

  test('a failed refresh leaves the stored token alone', () async {
    // The stored token is the only way back. Clearing it because Microsoft
    // was unreachable would turn a blip into a re-sign-in.
    await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));
    final before = await secrets.readSecret('acct-1');

    final repository = repositoryWith(
      handler: (_) async => http.Response('nope', 503),
    );
    await expectLater(
      repository.accessToken('acct-1'),
      throwsA(isA<SignInFailed>()),
    );

    expect(await secrets.readSecret('acct-1'), before);
  });

  test('the background worker winning the same refresh is not a sign-out',
      () async {
    // Two isolates, two repositories, one Keystore: the UI and the background
    // worker can both spend the same refresh token, and the loser is told
    // invalid_grant even though the account is fine. The winner's token is
    // already in the store, so re-reading finds it.
    await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));

    final repository = repositoryWith(handler: (_) async {
      // Stand in for the other isolate having got there first and written its
      // result before our request came back refused.
      await secrets.writeSecret(
        'acct-1',
        OAuthToken(
          accessToken: 'access-from-the-other-isolate',
          refreshToken: 'refresh-rotated',
          expiresAt: now.add(const Duration(hours: 1)),
        ).toStoredJson(),
      );
      return http.Response(
        jsonEncode({
          'error': 'invalid_grant',
          'error_description': 'AADSTS50173: The provided grant has expired.',
        }),
        400,
        headers: const {'content-type': 'application/json'},
      );
    });

    expect(
      await repository.accessToken('acct-1'),
      'access-from-the-other-isolate',
    );
  });

  test('a genuinely revoked sign-in is still a sign-out', () async {
    // The counterpart to the test above: nothing else wrote, so invalid_grant
    // means what it says and must not be swallowed.
    await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));

    final repository = repositoryWith(
      handler: (_) async => http.Response(
        jsonEncode({
          'error': 'invalid_grant',
          'error_description': 'AADSTS50173: The provided grant has expired.',
        }),
        400,
        headers: const {'content-type': 'application/json'},
      ),
    );

    await expectLater(
      repository.accessToken('acct-1'),
      throwsA(isA<SignInExpired>()),
    );
  });

  test('an account with nothing stored asks to be set up again', () async {
    await expectLater(
      repositoryWith().accessToken('acct-unknown'),
      throwsA(isA<SignInExpired>()),
    );
  });

  test('a secret that is not a token reads as not signed in', () async {
    // What a Gmail account's app password looks like in this slot. It must
    // not be handed to an OAuth transport as if it were a token.
    await secrets.writeSecret('acct-1', 'abcdabcdabcdabcd');

    await expectLater(
      repositoryWith().accessToken('acct-1'),
      throwsA(isA<SignInExpired>()),
    );
  });

  group('the Keystore', () {
    test('is read once, not once per request', () async {
      // Every Graph request asks for a token, and opening a folder is a
      // dozen requests. Each read is a decrypt over a platform channel.
      await storeToken(access: 'access-0', expiresIn: const Duration(hours: 1));
      final counted = _CountingStore(secrets);
      final repository = OAuthTokenRepository(
        credentialStore: counted,
        clock: () => now,
        oauthClient: () => throw StateError('no refresh was needed'),
      );

      for (var i = 0; i < 12; i++) {
        expect(await repository.accessToken('acct-1'), 'access-0');
      }

      expect(counted.reads, 1);
    });

    test('is read again when the token in hand was refused', () async {
      await storeToken(access: 'access-0', expiresIn: const Duration(hours: 1));
      final counted = _CountingStore(secrets);
      final repository = OAuthTokenRepository(
        credentialStore: counted,
        clock: () => now,
        oauthClient: () => MicrosoftOAuth(
          clientId: 'test-client-id',
          clock: () => now,
          authority: 'https://login.example/consumers/oauth2/v2.0',
          httpClient: http_testing.MockClient((_) async => http.Response(
                jsonEncode({
                  'access_token': 'access-fresh',
                  'refresh_token': 'refresh-fresh',
                  'expires_in': 3599,
                }),
                200,
                headers: const {'content-type': 'application/json'},
              )),
        ),
      );

      await repository.accessToken('acct-1');
      final again = await repository.accessToken('acct-1', force: true);

      expect(again, 'access-fresh');
      // Three: the first call, the forced one, and the refresh checking the
      // account still has a secret before writing its answer over it.
      expect(counted.reads, 3, reason: 'force looks at what is stored');
      expect(await repository.accessToken('acct-1'), 'access-fresh',
          reason: 'and what it found replaces what was held');
      expect(counted.reads, 3, reason: 'and nothing more after that');
    });

    test('a forgotten account leaves nothing behind', () async {
      await storeToken(access: 'access-0', expiresIn: const Duration(hours: 1));
      final repository = repositoryWith();
      await repository.accessToken('acct-1');

      repository.forget('acct-1');
      await secrets.deleteSecret('acct-1');

      await expectLater(
        repository.accessToken('acct-1'),
        throwsA(isA<SignInExpired>()),
      );
    });

    test('a refresh that finishes after the account was removed writes '
        'nothing back', () async {
      // The account is removed while Microsoft is still answering. Writing
      // the answer would leave a working refresh token on the device for an
      // account that looks gone, with nothing ever to clean it up.
      await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));
      final gate = Completer<void>();
      final repository = repositoryWith(handler: (_) async {
        await gate.future;
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

      final pending = repository.accessToken('acct-1');
      await pumpEventQueue();
      // What removeAccount does: forget, then delete the secret.
      repository.forget('acct-1');
      await secrets.deleteSecret('acct-1');
      gate.complete();
      await pending;

      expect(await secrets.readSecret('acct-1'), isNull);
    });

    test('nor when the account was removed from the other isolate', () async {
      // The live worker refreshes with its own repository, which nobody
      // tells about a removal in the app. The secret being gone is the sign.
      await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));
      final gate = Completer<void>();
      final worker = repositoryWith(handler: (_) async {
        await gate.future;
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

      final pending = worker.accessToken('acct-1');
      await pumpEventQueue();
      await secrets.deleteSecret('acct-1');
      gate.complete();
      await pending;

      expect(await secrets.readSecret('acct-1'), isNull);
    });

    test('a forget with the secret still there stops the write too', () async {
      // "Sign in again" writes the new sign-in and then forgets what was
      // held. A refresh of the old one that lands afterwards must not write
      // over the new sign-in.
      await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));
      final gate = Completer<void>();
      final repository = repositoryWith(handler: (_) async {
        await gate.future;
        return http.Response(
          jsonEncode({
            'access_token': 'access-old-sign-in',
            'refresh_token': 'refresh-old-sign-in',
            'expires_in': 3599,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final pending = repository.accessToken('acct-1');
      await pumpEventQueue();
      final newSignIn = OAuthToken(
        accessToken: 'access-new',
        refreshToken: 'refresh-new',
        expiresAt: now.add(const Duration(hours: 1)),
      ).toStoredJson();
      await secrets.writeSecret('acct-1', newSignIn);
      repository.forget('acct-1');
      gate.complete();
      await pending;

      expect(await secrets.readSecret('acct-1'), newSignIn);
    });

    test('a sign-in redone elsewhere is found when the old one is refused',
        () async {
      // The live worker holds its own copy for an hour. After "Sign in
      // again" in the app, refreshing the old copy is still refused for
      // consent, and only an expiry used to send it back to the store.
      await storeToken(access: 'access-0', expiresIn: const Duration(minutes: 4));
      var consentRefused = true;
      final worker = repositoryWith(handler: (request) async {
        final spent = Uri.splitQueryString(request.body)['refresh_token'];
        if (spent == 'refresh-0' && consentRefused) {
          return http.Response(
            jsonEncode({
              'error': 'invalid_grant',
              'error_description': 'AADSTS70000: The user needs to consent.',
            }),
            400,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'access_token': 'access-after-$spent',
            'refresh_token': 'refresh-after-$spent',
            'expires_in': 3599,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      // The worker has read, and holds, the old sign-in.
      await expectLater(
        worker.accessToken('acct-1'),
        throwsA(isA<SignInNeedsConsent>()),
      );

      // The person signs in again in the app: a new token in the store,
      // already a few minutes old.
      await secrets.writeSecret(
        'acct-1',
        OAuthToken(
          accessToken: 'access-new',
          refreshToken: 'refresh-new',
          expiresAt: now.add(const Duration(minutes: 2)),
        ).toStoredJson(),
      );

      expect(await worker.accessToken('acct-1'), 'access-after-refresh-new',
          reason: 'the new sign-in is found and refreshed, not refused again');
    });
  });
}

/// A credential store that counts how often it is asked.
class _CountingStore implements CredentialStore {
  _CountingStore(this._inner);

  final CredentialStore _inner;
  int reads = 0;

  @override
  Future<String?> readSecret(String accountId) {
    reads++;
    return _inner.readSecret(accountId);
  }

  @override
  Future<void> writeSecret(String accountId, String secret) =>
      _inner.writeSecret(accountId, secret);

  @override
  Future<void> deleteSecret(String accountId) =>
      _inner.deleteSecret(accountId);
}
