import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';

import 'fakes/fake_imap_transport.dart';

/// Replacing an account's credential without losing what is cached under it.
///
/// The whole reason this exists rather than "remove it and add it again": an
/// app password that has been revoked should cost one field, not a re-download
/// of the entire mailbox.
void main() {
  late FakeImapTransport server;
  late MemoryAccountStore accounts;
  late MemoryCredentialStore secrets;
  late MemoryCacheStore cache;
  late CachedImapEngine engine;

  setUp(() {
    server = FakeImapTransport();
    accounts = MemoryAccountStore();
    secrets = MemoryCredentialStore();
    cache = MemoryCacheStore();
    engine = CachedImapEngine(
      accountStore: accounts,
      credentialStore: secrets,
      cache: cache,
      transportFactory: (_, _) => server,
    );
    server.folder('INBOX', role: FolderRole.inbox).deliver(subject: 'Hello');
  });

  Future<Account> addGmail() => engine.addAccount(
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        secret: 'oldoldoldoldold1',
      );

  Future<Account> addOutlook() => engine.addOAuthAccount(
        displayName: 'Work',
        emailAddress: 'me@example.com',
        provider: MailProvider.outlook,
        token: OAuthToken(
          accessToken: 'access-old',
          refreshToken: 'refresh-old',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );

  group('an app password', () {
    test('replaces the stored secret', () async {
      final account = await addGmail();

      await engine.updateAppPassword(
        accountId: account.id,
        secret: 'newnewnewnewnew1',
      );

      expect(await secrets.readSecret(account.id), 'newnewnewnewnew1');
    });

    test('keeps the account id, which is what keeps the cache', () async {
      // Every cached folder and message is filed under this id. A new id is
      // indistinguishable from having removed and re-added the account.
      final account = await addGmail();
      await engine.loadMessages(MailFolderIds.inboxOf(account.id));
      final cachedBefore =
          (await cache.readMessages(account.id, 'INBOX')).length;
      expect(cachedBefore, greaterThan(0));

      await engine.updateAppPassword(
        accountId: account.id,
        secret: 'newnewnewnewnew1',
      );

      expect(accounts.read().single.id, account.id);
      expect(
        (await cache.readMessages(account.id, 'INBOX')).length,
        cachedBefore,
        reason: 'the cached mail is the entire point of this over re-adding',
      );
    });

    test('a password the server refuses is not stored', () async {
      // Replacing a broken sign-in with a differently broken one, and losing
      // the last known-good secret on the way, would be worse than failing.
      final account = await addGmail();
      server.offline = true;

      await expectLater(
        engine.updateAppPassword(
          accountId: account.id,
          secret: 'newnewnewnewnew1',
        ),
        throwsA(isA<ConnectionFailed>()),
      );

      expect(await secrets.readSecret(account.id), 'oldoldoldoldold1');
    });

    test('an unknown account is an error', () async {
      await expectLater(
        engine.updateAppPassword(accountId: 'nope', secret: 'x'),
        throwsA(isA<StateError>()),
      );
    });

    test('the next connection uses the new password', () async {
      // A cached transport closes over the secret it was built with, so
      // leaving it in place would mean the account carried on failing with
      // the old password until the app restarted — which looks exactly like
      // the fix not having worked.
      final account = await addGmail();
      final built = <String>[];
      final tracking = CachedImapEngine(
        accountStore: accounts,
        credentialStore: secrets,
        cache: cache,
        transportFactory: (_, credentials) {
          built.add('${credentials.runtimeType}');
          return server;
        },
      );
      await tracking.loadFolders(account.id);
      built.clear();

      await tracking.updateAppPassword(
        accountId: account.id,
        secret: 'newnewnewnewnew1',
      );
      await tracking.loadFolders(account.id);

      expect(built, isNotEmpty,
          reason: 'the cached transport must have been discarded, forcing a '
              'rebuild with the credential that now works');
    });
  });

  group('an OAuth account', () {
    test('replaces the stored token, refresh token and all', () async {
      final account = await addOutlook();

      await engine.updateOAuthToken(
        accountId: account.id,
        token: OAuthToken(
          accessToken: 'access-new',
          refreshToken: 'refresh-new',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );

      final stored = OAuthToken.fromStoredJson(
        await secrets.readSecret(account.id),
      );
      expect(stored!.accessToken, 'access-new');
      expect(stored.refreshToken, 'refresh-new');
    });

    test('a token the server refuses leaves the old one alone', () async {
      final account = await addOutlook();
      final before = await secrets.readSecret(account.id);
      server.offline = true;

      await expectLater(
        engine.updateOAuthToken(
          accountId: account.id,
          token: OAuthToken(
            accessToken: 'access-new',
            refreshToken: 'refresh-new',
            expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        ),
        throwsA(isA<ConnectionFailed>()),
      );

      expect(await secrets.readSecret(account.id), before);
    });
  });
}

/// Folder ids the engine builds, spelled out so the tests do not depend on
/// the exact separator.
abstract final class MailFolderIds {
  static String inboxOf(String accountId) => '$accountId:INBOX';
}
