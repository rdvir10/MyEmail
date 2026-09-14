import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_store.dart';

/// App passwords in the Android Keystore via flutter_secure_storage.
///
/// One entry per account. Nothing is cached in memory beyond what the
/// platform channel returns for the call in hand.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String _key(String accountId) => 'account.$accountId.secret';

  @override
  Future<String?> readSecret(String accountId) =>
      _storage.read(key: _key(accountId));

  @override
  Future<void> writeSecret(String accountId, String secret) =>
      _storage.write(key: _key(accountId), value: secret);

  @override
  Future<void> deleteSecret(String accountId) =>
      _storage.delete(key: _key(accountId));
}
