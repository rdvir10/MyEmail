import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/auth/google_oauth.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/auth/oauth_refresher.dart';
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
        oauthClient: (_) => MicrosoftOAuth(
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
        oauthClient: (_) => throw StateError('no refresh was needed'),
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
        oauthClient: (_) => MicrosoftOAuth(
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

  // The race contact sync's Allow sets up. The person signs in again in
  // the app, for a permission the old sign-in lacked, while the live
  // worker in the other isolate holds the old sign-in for an hour. Google
  // hands the same refresh token back on every refresh, so a refresh of
  // what the worker holds would write the old sign-in back over the new
  // one; and a scoped ask that is refused must look for the new sign-in
  // and refresh that for its own scopes. Run against both providers,
  // because they differ in exactly the respect that matters: Microsoft
  // turns the refresh token over on every refresh, Google never does.
  for (final provider in _Provider.values) {
    group('a newer sign-in with ${provider.name}', () {
      /// The refresh tokens whose sign-in allowed contacts.
      late Set<String> allowsContacts;

      /// The refresh tokens the provider no longer takes.
      late Set<String> revoked;

      /// Every request to the token endpoint, as its form.
      late List<Map<String, String>> asked;

      setUp(() {
        allowsContacts = {'refresh-new'};
        revoked = {};
        asked = [];
      });

      Future<http.Response> endpoint(http.Request request) async {
        final form = Uri.splitQueryString(request.body);
        asked.add(form);
        final spent = form['refresh_token']!;
        if (revoked.contains(spent)) {
          return _json({
            'error': 'invalid_grant',
            'error_description': provider == _Provider.microsoft
                ? 'AADSTS50173: The provided grant has expired.'
                : 'Bad Request',
          }, status: 400);
        }
        switch (provider) {
          case _Provider.microsoft:
            final asks = '${form['scope']}';
            if (asks.contains('Contacts.ReadWrite') &&
                !allowsContacts.contains(spent)) {
              return _json({
                'error': 'invalid_grant',
                'error_description': 'AADSTS65001: The user or administrator '
                    'has not consented to use the application.',
              }, status: 400);
            }
            return _json({
              'access_token': 'access-after-$spent',
              'refresh_token': 'turned-$spent',
              'expires_in': 3599,
            });
          case _Provider.google:
            return _json({
              'access_token': 'access-after-$spent',
              'expires_in': 3599,
              'scope': [
                'https://mail.google.com/',
                'https://www.googleapis.com/auth/calendar.events',
                if (allowsContacts.contains(spent)) ...provider.contacts,
                'openid',
                'email',
              ].join(' '),
            });
        }
      }

      OAuthTokenRepository repository() => OAuthTokenRepository(
            credentialStore: secrets,
            clock: () => now,
            oauthClient: (_) => provider.refresher(
              () => now,
              http_testing.MockClient(endpoint),
            ),
          );

      Future<void> signIn(String refresh, {required Duration good}) =>
          secrets.writeSecret(
            'acct-1',
            OAuthToken(
              accessToken: 'access-of-$refresh',
              refreshToken: refresh,
              expiresAt: now.add(good),
            ).toStoredJson(),
          );

      Future<OAuthToken> storedNow() async =>
          OAuthToken.fromStoredJson(await secrets.readSecret('acct-1'))!;

      test('a refresh of the old one writes nothing over it', () async {
        await signIn('refresh-old', good: const Duration(hours: 1));
        final worker = repository();
        expect(await worker.accessToken('acct-1'), 'access-of-refresh-old',
            reason: 'the worker reads the old sign-in and holds it');

        await signIn('refresh-new', good: const Duration(hours: 3));
        now = now.add(const Duration(minutes: 58));
        final token = await worker.accessToken('acct-1');

        expect(asked.single['refresh_token'], 'refresh-old',
            reason: 'what the worker held was what it refreshed');
        expect((await storedNow()).refreshToken, 'refresh-new',
            reason: 'the new sign-in is kept, not the one from before it');
        expect(token, 'access-of-refresh-new',
            reason: 'and its access token, still good, is used');

        now = now.add(const Duration(hours: 3));
        await worker.accessToken('acct-1');
        expect(asked.last['refresh_token'], 'refresh-new',
            reason: 'from then on the worker holds the new sign-in');
      });

      test('nor does a refresh for another resource', () async {
        await signIn('refresh-old', good: const Duration(hours: 1));
        final worker = repository();
        await worker.accessToken('acct-1');

        await signIn('refresh-new', good: const Duration(hours: 3));
        final token =
            await worker.accessToken('acct-1', scopes: provider.calendar);

        expect(token, 'access-after-refresh-old');
        expect((await storedNow()).refreshToken, 'refresh-new');
        expect((await storedNow()).accessToken, 'access-of-refresh-new');
      });

      test('a refresh of the sign-in still stored is written back', () async {
        // The counterpart: with nothing newer in the store, the newest
        // refresh token and access token go there as before.
        await signIn('refresh-old', good: const Duration(minutes: 4));
        final repo = repository();

        await repo.accessToken('acct-1', scopes: provider.calendar);
        await repo.accessToken('acct-1');

        final stored = await storedNow();
        expect(stored.refreshToken,
            provider.afterRefresh(provider.afterRefresh('refresh-old')));
        expect(stored.accessToken, startsWith('access-after-'));
      });

      test('a scoped ask refused for consent takes up the newer sign-in, '
          'refreshed for its own scopes', () async {
        await signIn('refresh-old', good: const Duration(hours: 1));
        final worker = repository();
        await worker.accessToken('acct-1');
        await expectLater(
          worker.accessToken('acct-1', scopes: provider.contacts),
          throwsA(isA<SignInNeedsConsent>()),
        );

        // Allow: a sign-in that grants contacts, its access token for the
        // default scopes still good.
        await signIn('refresh-new', good: const Duration(hours: 1));
        asked.clear();
        final token =
            await worker.accessToken('acct-1', scopes: provider.contacts);

        expect(token, 'access-after-refresh-new',
            reason: 'refreshed for contacts, not handed the stored access '
                'token, which is for the default scopes');
        expect(asked.map((f) => f['refresh_token']),
            ['refresh-old', 'refresh-new']);
        if (provider == _Provider.microsoft) {
          expect(asked.last['scope'], provider.contacts.join(' '));
        }
        expect((await storedNow()).refreshToken,
            provider.afterRefresh('refresh-new'));
        expect(await worker.accessToken('acct-1'), 'access-of-refresh-new',
            reason: 'the default path holds the new sign-in too');
      });

      test('a newer sign-in that still lacks the scopes is still refused',
          () async {
        // Google's granular consent starts the new box unticked: a sign-in
        // that left it so must not pass for one that allowed it.
        allowsContacts = {};
        await signIn('refresh-old', good: const Duration(hours: 1));
        final worker = repository();
        await worker.accessToken('acct-1');
        await signIn('refresh-new', good: const Duration(hours: 1));

        await expectLater(
          worker.accessToken('acct-1', scopes: provider.contacts),
          throwsA(isA<SignInNeedsConsent>()),
        );
      });

      test('a scoped ask refused as expired takes up the newer sign-in',
          () async {
        await signIn('refresh-old', good: const Duration(hours: 1));
        final worker = repository();
        await worker.accessToken('acct-1');
        revoked = {'refresh-old'};
        await signIn('refresh-new', good: const Duration(hours: 1));

        expect(
          await worker.accessToken('acct-1', scopes: provider.calendar),
          'access-after-refresh-new',
        );
      });

      test('a scoped ask refused as expired with nothing newer is a sign-out',
          () async {
        await signIn('refresh-old', good: const Duration(hours: 1));
        final worker = repository();
        revoked = {'refresh-old'};

        await expectLater(
          worker.accessToken('acct-1', scopes: provider.calendar),
          throwsA(isA<SignInExpired>()),
        );
        expect(asked, hasLength(1), reason: 'nothing newer to refresh');
      });
    });
  }
}

http.Response _json(Map<String, Object?> body, {int status = 200}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: const {'content-type': 'application/json'},
    );

/// The two sign-in providers, as the repository meets them.
enum _Provider {
  microsoft,
  google;

  OAuthRefresher refresher(DateTime Function() clock, http.Client client) =>
      switch (this) {
        _Provider.microsoft => MicrosoftOAuth(
            clientId: 'test-client-id',
            clock: clock,
            authority: 'https://login.example/consumers/oauth2/v2.0',
            httpClient: client,
          ),
        _Provider.google => GoogleOAuth(
            clientId: 'test-client-id.apps.googleusercontent.com',
            clock: clock,
            httpClient: client,
          ),
      };

  /// What contact sync asks for.
  List<String> get contacts => switch (this) {
        _Provider.microsoft => MicrosoftOAuth.contactSyncScopes,
        _Provider.google => GoogleOAuth.contactSyncScopes,
      };

  /// A resource every sign-in here allows.
  List<String> get calendar => switch (this) {
        _Provider.microsoft => MicrosoftOAuth.calendarScopes,
        _Provider.google => const [
            'https://www.googleapis.com/auth/calendar.events',
          ],
      };

  /// The refresh token kept after spending [spent]: Microsoft's new one,
  /// or Google's same one.
  String afterRefresh(String spent) => switch (this) {
        _Provider.microsoft => 'turned-$spent',
        _Provider.google => spent,
      };
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
