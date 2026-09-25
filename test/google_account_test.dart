import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_credentials.dart';

import 'fakes/fake_imap_transport.dart';

/// A Gmail account moving from an app password to Google sign-in, and
/// staying the account it was.
void main() {
  late FakeImapTransport server;
  late MemoryAccountStore accounts;
  late MemoryCredentialStore secrets;
  late CachedImapEngine engine;
  final credentialsSeen = <Type>[];

  final token = OAuthToken(
    accessToken: 'ya29.access',
    refreshToken: '1//refresh',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  setUp(() {
    server = FakeImapTransport()
      ..folder('INBOX', role: FolderRole.inbox)
      ..folder('[Gmail]/Sent Mail', role: FolderRole.sent);
    accounts = MemoryAccountStore();
    secrets = MemoryCredentialStore();
    credentialsSeen.clear();
    engine = CachedImapEngine(
      accountStore: accounts,
      credentialStore: secrets,
      cache: MemoryCacheStore(),
      transportFactory: (account, credentials) {
        credentialsSeen.add(credentials.runtimeType);
        return server;
      },
    );
  });

  Future<Account> withPassword() => engine.addAccount(
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );

  test('signing in with Google keeps the account and changes how it signs in',
      () async {
    final a = await withPassword();
    expect(a.authMethod, AuthMethod.appPassword);

    await engine.updateOAuthToken(
      accountId: a.id,
      token: token,
      signedInAs: 'Me@Example.com',
    );

    final now = accounts.read().single;
    expect(now.id, a.id);
    expect(now.authMethod, AuthMethod.oauth);
    expect(OAuthToken.fromStoredJson(await secrets.readSecret(a.id))?.accessToken,
        'ya29.access');
    // The next connection is made with the token, not the old password.
    await engine.loadFolders(a.id);
    expect(credentialsSeen.last, OAuthCredentials);
  });

  test('a sign-in the server refuses leaves the password in place', () async {
    final a = await withPassword();
    server.failWith = const AuthenticationFailed('no');

    await expectLater(
      engine.updateOAuthToken(accountId: a.id, token: token),
      throwsA(isA<AuthenticationFailed>()),
    );

    expect(accounts.read().single.authMethod, AuthMethod.appPassword);
    expect(await secrets.readSecret(a.id), 'abcdabcdabcdabcd');
  });

  test('a sign-in as somebody else is refused before anything is tried',
      () async {
    final a = await withPassword();
    credentialsSeen.clear();

    await expectLater(
      engine.updateOAuthToken(
        accountId: a.id,
        token: token,
        signedInAs: 'somebody.else@example.com',
      ),
      throwsA(isA<AuthenticationFailed>().having(
          (e) => e.message, 'message', contains('somebody.else@example.com'))),
    );

    expect(credentialsSeen, isEmpty, reason: 'no probe was made');
    expect(accounts.read().single.authMethod, AuthMethod.appPassword);
    expect(await secrets.readSecret(a.id), 'abcdabcdabcdabcd');
  });

  test('adding an account as one address with a sign-in for another is refused',
      () async {
    await expectLater(
      engine.addOAuthAccount(
        displayName: 'Work',
        emailAddress: 'typed@example.com',
        provider: MailProvider.gmail,
        token: token,
        signedInAs: 'signed.in@example.com',
      ),
      throwsA(isA<AuthenticationFailed>()),
    );
    expect(accounts.read(), isEmpty);
    expect(await secrets.readSecret('acct-1'), isNull);
  });

  test('a Google account is added with the address the sign-in named',
      () async {
    final a = await engine.addOAuthAccount(
      displayName: 'Work',
      emailAddress: 'signed.in@example.com',
      provider: MailProvider.gmail,
      token: token,
      signedInAs: 'Signed.In@example.com',
    );
    expect(a.authMethod, AuthMethod.oauth);
    expect(a.provider, MailProvider.gmail);
    expect(credentialsSeen, [OAuthCredentials]);
  });
}
