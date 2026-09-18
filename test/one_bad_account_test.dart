import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/providers.dart';

import 'fakes/fake_imap_transport.dart';

/// One account in trouble must not take the others down with it.
///
/// The folders for every account were loaded with a single Future.wait, which
/// rejects the moment any one of them does. An account whose sign-in had gone
/// stale therefore blanked the whole folder tree: every other account's
/// folders disappeared and the pane showed that one account's error. Someone
/// with a working Gmail account and a Microsoft account that needed signing in
/// again lost both, and the message on screen named the wrong problem.
void main() {
  late FakeImapTransport working;
  late FakeImapTransport broken;
  late MemoryAccountStore accounts;
  late CachedImapEngine engine;

  const gmail = Account(
    id: 'acct-gmail',
    displayName: 'Personal',
    emailAddress: 'me@example.com',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.appPassword,
    colorValue: 0xFF0F6CBD,
  );
  const outlook = Account(
    id: 'acct-outlook',
    displayName: 'Work',
    emailAddress: 'me@work.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0xFF107C41,
  );

  setUp(() {
    working = FakeImapTransport();
    working.folder('INBOX', role: FolderRole.inbox);
    working.folder('Receipts');
    broken = FakeImapTransport();

    accounts = MemoryAccountStore([gmail, outlook]);
    final secrets = MemoryCredentialStore()
      ..writeSecret('acct-gmail', 'abcdabcdabcdabcd');

    engine = CachedImapEngine(
      accountStore: accounts,
      credentialStore: secrets,
      cache: MemoryCacheStore(),
      transportFactory: (account, _) =>
          account.id == 'acct-gmail' ? working : broken,
    );
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        mailEngineProvider.overrideWithValue(engine),
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('the working account still gets its folders', () async {
    // The whole point. Before this, both accounts showed nothing.
    broken.failWith = const AuthenticationFailed('Sign in again.');
    final c = container();

    final folders = await c.read(foldersProvider.future);

    expect(folders['acct-gmail'], hasLength(2));
  });

  test('the failing account is reported against itself', () async {
    broken.failWith = const AuthenticationFailed('Sign in again, please.');
    final c = container();

    await c.read(foldersProvider.future);

    expect(c.read(folderLoadErrorsProvider)['acct-outlook'],
        'Sign in again, please.');
    expect(c.read(folderLoadErrorsProvider).containsKey('acct-gmail'), isFalse);
  });

  test('the tree as a whole is not an error', () async {
    // An AsyncValue has room for one error, so putting an account's failure
    // there made every account look broken.
    broken.failWith = const AuthenticationFailed('Sign in again.');
    final c = container();

    await c.read(foldersProvider.future);

    expect(c.read(foldersProvider).hasError, isFalse);
  });

  test('the error appears under the account it belongs to', () async {
    broken.failWith = const AuthenticationFailed('Sign in again, please.');
    final c = container();
    await c.read(foldersProvider.future);

    final rows = c.read(treeRowsProvider);
    final headers = rows.whereType<SectionHeaderRow>().toList();

    final failing =
        headers.firstWhere((h) => h.accountId == 'acct-outlook');
    expect(failing.error, 'Sign in again, please.');
    final fine = headers.firstWhere((h) => h.accountId == 'acct-gmail');
    expect(fine.error, isNull);
  });

  test('the failing account keeps a heading, so there is something to tap',
      () async {
    // An account with no folders is normally left out of the tree entirely.
    // Doing that here would hide the problem and the account with it.
    broken.failWith = const AuthenticationFailed('Sign in again.');
    final c = container();
    await c.read(foldersProvider.future);

    final rows = c.read(treeRowsProvider);

    expect(
      rows.whereType<SectionHeaderRow>().map((h) => h.accountId),
      contains('acct-outlook'),
    );
  });

  test('with both accounts working, nothing is reported', () async {
    broken.folder('INBOX', role: FolderRole.inbox);
    final c = container();

    await c.read(foldersProvider.future);

    expect(c.read(folderLoadErrorsProvider), isEmpty);
  });
}
