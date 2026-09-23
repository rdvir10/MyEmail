import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/auth/token_identity.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';

import 'fakes/fake_imap_transport.dart';

/// Which mailbox a Microsoft sign-in is for. Graph asks for /me, which is
/// whoever signed in, so picking the wrong account on the sign-in page made
/// an account that showed one mailbox under another's address.
void main() {
  /// A work account's access token: a JWT naming its user.
  String workToken({
    String tid = 'tenant-1',
    required String oid,
    required String upn,
  }) {
    String part(Object json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    return '${part({'alg': 'none'})}.'
        '${part({'tid': tid, 'oid': oid, 'upn': upn})}.signature';
  }

  OAuthToken token(String access) => OAuthToken(
        accessToken: access,
        refreshToken: 'refresh',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

  group('reading the token', () {
    test('a work account names its user and address', () {
      final identity =
          TokenIdentity.of(workToken(oid: 'o-1', upn: 'ron@work.example'))!;
      expect(identity.user, 'tenant-1/o-1');
      expect(identity.address, 'ron@work.example');
    });

    test("a personal account's token says nothing", () {
      expect(TokenIdentity.of('EwBoA8l6BAAU...opaque'), isNull);
    });
  });

  group('the engine', () {
    late MemoryAccountStore accounts;
    late MemoryCredentialStore secrets;
    late CachedImapEngine engine;

    setUp(() {
      final server = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox);
      accounts = MemoryAccountStore();
      secrets = MemoryCredentialStore();
      engine = CachedImapEngine(
        accountStore: accounts,
        credentialStore: secrets,
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
      );
    });

    Future<Account> add(String typed, String access) => engine.addOAuthAccount(
          displayName: 'Work',
          emailAddress: typed,
          provider: MailProvider.outlook,
          token: token(access),
        );

    test('refuses a sign-in for another address than the one typed',
        () async {
      await expectLater(
        add('ron@work.example',
            workToken(oid: 'o-2', upn: 'dana@work.example')),
        throwsA(isA<AuthenticationFailed>().having(
            (e) => e.message, 'message', contains('dana@work.example'))),
      );
      expect(accounts.read(), isEmpty, reason: 'nothing kept');
    });

    test('takes one that matches, whatever the case', () async {
      final account = await add('Ron@Work.example',
          workToken(oid: 'o-1', upn: 'ron@work.example'));
      expect(account.emailAddress, 'Ron@Work.example');
    });

    test('and an opaque one as before, having nothing to go on', () async {
      await add('ron@outlook.example', 'opaque-personal-token');
      expect(accounts.read(), hasLength(1));
    });

    group('signing in again', () {
      test('as someone else is refused, and the sign-in kept', () async {
        final account = await add('ron@work.example',
            workToken(oid: 'o-1', upn: 'ron@work.example'));
        final before = await secrets.readSecret(account.id);

        await expectLater(
          engine.updateOAuthToken(
            accountId: account.id,
            token: token(workToken(oid: 'o-2', upn: 'dana@work.example')),
          ),
          throwsA(isA<AuthenticationFailed>()),
        );
        expect(await secrets.readSecret(account.id), before);
      });

      test('as a personal account in place of a work one is refused',
          () async {
        final account = await add('ron@work.example',
            workToken(oid: 'o-1', upn: 'ron@work.example'));

        await expectLater(
          engine.updateOAuthToken(
            accountId: account.id,
            token: token('opaque-personal-token'),
          ),
          throwsA(isA<AuthenticationFailed>()),
        );
      });

      test('as the same person is taken', () async {
        final account = await add('ron@work.example',
            workToken(oid: 'o-1', upn: 'ron@work.example'));
        final fresh = workToken(oid: 'o-1', upn: 'ron@work.example');

        await engine.updateOAuthToken(accountId: account.id, token: token(fresh));

        expect(
          OAuthToken.fromStoredJson(await secrets.readSecret(account.id))!
              .accessToken,
          fresh,
        );
      });
    });
  });
}
