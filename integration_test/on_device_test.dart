// Runs on a real device or emulator: verifies the platform-backed pieces that
// a host `flutter test` cannot reach, because they need Android itself.
//
//   flutter test integration_test/on_device_test.dart
//
// Covers SQLite through Drift (the native library has to load on Android),
// Keystore-backed credential storage, and shared_preferences.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mailtree/data/cache/cache_store.dart';
import 'package:mailtree/data/cache/mail_database.dart';
import 'package:mailtree/data/secure_credential_store.dart';
import 'package:mailtree/data/ui_state_store.dart';
import 'package:mailtree/domain/mail_message.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Drift on Android', () {
    test('the real database file opens, writes and reads back', () async {
      // MailDatabase.open() uses the app documents directory, which only
      // exists on a device.
      final db = MailDatabase.open();
      final store = DriftCacheStore(db);
      addTearDown(db.close);

      const account = 'acct-integration';
      await store.deleteAccount(account);

      await store.upsertMessages(account, 'INBOX', [
        CachedMessage(
          uid: 1,
          subject: 'On-device row',
          from: const MailAddress(email: 'a@example.com', name: 'A'),
          to: const [MailAddress(email: 'me@example.com')],
          date: DateTime(2026, 9, 14, 12),
          isRead: false,
          isFlagged: true,
          hasAttachments: false,
        ),
      ]);
      await store.writeFolderState(
        account,
        'INBOX',
        FolderSyncState(uidValidity: 42, lastSync: DateTime(2026, 9, 14)),
      );

      final rows = await store.readMessages(account, 'INBOX');
      expect(rows.single.subject, 'On-device row');
      expect(rows.single.isFlagged, isTrue);
      expect(rows.single.from.name, 'A');
      expect((await store.readFolderState(account, 'INBOX'))!.uidValidity, 42);

      await store.deleteAccount(account);
      expect(await store.countMessages(account, 'INBOX'), 0);
    });

    test('an in-memory database also works, proving the native library',
        () async {
      final db = MailDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = DriftCacheStore(db);
      await store.writeFolderState(
        'a',
        'INBOX',
        FolderSyncState(uidValidity: 1, lastSync: DateTime(2026)),
      );
      expect(await store.readFolderState('a', 'INBOX'), isNotNull);
    });
  });

  group('Keystore credential storage', () {
    test('a secret round-trips and can be deleted', () async {
      final store = SecureCredentialStore();
      const id = 'acct-integration';
      await store.deleteSecret(id);
      expect(await store.readSecret(id), isNull);

      await store.writeSecret(id, 'abcd efgh ijkl mnop');
      expect(await store.readSecret(id), 'abcd efgh ijkl mnop');

      await store.deleteSecret(id);
      expect(await store.readSecret(id), isNull);
    });
  });

  group('shared_preferences', () {
    test('UI state persists through the real store', () async {
      final store = await PrefsUiStateStore.open();
      await store.writeIds(UiStateKeys.expanded, {'a:Finance'});
      expect(store.readIds(UiStateKeys.expanded), {'a:Finance'});
      await store.writeOrder(UiStateKeys.order, {'a:Travel': 0});
      expect(store.readOrder(UiStateKeys.order), {'a:Travel': 0});
      await store.writeIds(UiStateKeys.expanded, {});
    });
  });
}
