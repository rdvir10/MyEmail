/// Where secrets live: one app password per account in round one, OAuth
/// tokens later behind the same interface.
///
/// The Android implementation sits on flutter_secure_storage (Keystore-backed)
/// and is added alongside the IMAP engine. Nothing here ever logs a value.
abstract class CredentialStore {
  Future<String?> readSecret(String accountId);
  Future<void> writeSecret(String accountId, String secret);
  Future<void> deleteSecret(String accountId);
}

/// For tests and the browser preview, which has no Keystore.
class MemoryCredentialStore implements CredentialStore {
  final Map<String, String> _secrets = {};

  @override
  Future<String?> readSecret(String accountId) async => _secrets[accountId];

  @override
  Future<void> writeSecret(String accountId, String secret) async =>
      _secrets[accountId] = secret;

  @override
  Future<void> deleteSecret(String accountId) async =>
      _secrets.remove(accountId);
}
