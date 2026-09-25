import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/account.dart';

import 'fakes/fake_imap_transport.dart';

/// The order of the accounts is the person's to arrange, and the engine
/// keeps it.
void main() {
  Account account(String id) => Account(
        id: id,
        displayName: id,
        emailAddress: '$id@example.com',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.appPassword,
        colorValue: 0xFF0F6CBD,
      );

  group('accountsInOrder', () {
    final accounts = [account('a'), account('b'), account('c')];

    test('follows the ids', () {
      expect(
        accountsInOrder(accounts, ['c', 'a', 'b']).map((a) => a.id),
        ['c', 'a', 'b'],
      );
    });

    test('passes over ids that name nobody, and keeps the unnamed after the '
        'named in their order', () {
      expect(
        accountsInOrder(accounts, ['x', 'c']).map((a) => a.id),
        ['c', 'a', 'b'],
      );
      expect(accountsInOrder(accounts, []).map((a) => a.id), ['a', 'b', 'c']);
    });

    test('an id twice counts once', () {
      expect(
        accountsInOrder(accounts, ['b', 'b', 'a']).map((a) => a.id),
        ['b', 'a', 'c'],
      );
    });
  });

  group('CachedImapEngine.reorderAccounts', () {
    test('writes the order to the store, where a restart reads it', () async {
      final store = MemoryAccountStore();
      final engine = CachedImapEngine(
        accountStore: store,
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => FakeImapTransport(),
      );
      final first = await engine.addAccount(
        displayName: 'First',
        emailAddress: 'first@gmail.com',
        provider: MailProvider.gmail,
        secret: 'app-password',
      );
      final second = await engine.addAccount(
        displayName: 'Second',
        emailAddress: 'second@gmail.com',
        provider: MailProvider.gmail,
        secret: 'app-password',
      );

      await engine.reorderAccounts([second.id, first.id]);

      expect(store.read().map((a) => a.id), [second.id, first.id]);
      expect(
        (await engine.loadAccounts()).map((a) => a.id),
        [second.id, first.id],
      );
    });
  });

  group('SampleMailEngine.reorderAccounts', () {
    test('answers loadAccounts in the new order from then on', () async {
      final engine = SampleMailEngine();
      final before = (await engine.loadAccounts()).map((a) => a.id).toList();
      expect(before, ['acct-personal', 'acct-side']);

      await engine.reorderAccounts(['acct-side', 'acct-personal']);

      expect(
        (await engine.loadAccounts()).map((a) => a.id),
        ['acct-side', 'acct-personal'],
      );
    });
  });
}
