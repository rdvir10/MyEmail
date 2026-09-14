import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/data/account_store.dart';
import 'package:mailtree/data/credential_store.dart';
import 'package:mailtree/domain/account.dart';

const _acct = Account(
  id: 'acct-1',
  displayName: 'Personal',
  emailAddress: 'someone@example.com',
  provider: MailProvider.gmail,
  authMethod: AuthMethod.appPassword,
  colorValue: 0xFF0F6CBD,
);

void main() {
  group('account JSON', () {
    test('round-trips every field', () {
      final back = accountFromJson(accountToJson(_acct));
      expect(back.id, _acct.id);
      expect(back.displayName, _acct.displayName);
      expect(back.emailAddress, _acct.emailAddress);
      expect(back.provider, MailProvider.gmail);
      expect(back.authMethod, AuthMethod.appPassword);
      expect(back.colorValue, _acct.colorValue);
    });

    test('never carries a secret', () {
      final json = accountToJson(_acct);
      expect(json.keys, isNot(contains('password')));
      expect(json.values.join(' '), isNot(contains('secret')));
    });
  });

  group('MemoryAccountStore', () {
    test('write then read', () async {
      final store = MemoryAccountStore();
      expect(store.read(), isEmpty);
      await store.write([_acct]);
      expect(store.read().single.emailAddress, 'someone@example.com');
    });

    test('read returns a copy the caller cannot mutate into the store',
        () async {
      final store = MemoryAccountStore([_acct]);
      expect(() => store.read().clear(), throwsUnsupportedError);
    });
  });

  group('MemoryCredentialStore', () {
    test('secrets are keyed by account and can be removed', () async {
      final store = MemoryCredentialStore();
      expect(await store.readSecret('acct-1'), isNull);
      await store.writeSecret('acct-1', 'abcd efgh ijkl mnop');
      expect(await store.readSecret('acct-1'), 'abcd efgh ijkl mnop');
      await store.deleteSecret('acct-1');
      expect(await store.readSecret('acct-1'), isNull);
    });
  });
}
