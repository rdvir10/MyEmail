import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'account.dart';

/// Everything about how this app is set up, in one file.
///
/// What is deliberately **not** in here: app passwords and OAuth tokens.
///
/// That is the whole security design of this feature and it is worth being
/// explicit about. A Gmail app password reads a mailbox until it is revoked;
/// a Microsoft refresh token does the same and renews itself indefinitely.
/// Either one, written into a file that then lives in a cloud folder, an email
/// attachment or a downloads directory, is a durable key to the entire
/// mailbox sitting somewhere nobody is guarding. Encrypting it would move the
/// problem to a passphrase people reuse, and a backup that cannot be restored
/// because the passphrase is gone is its own failure.
///
/// So the accounts come back with their addresses, names, colours and every
/// preference attached to them, and each one needs signing in again. That is
/// one field, or one button for a Microsoft account, against a file that
/// cannot hurt anyone if it leaks.
///
/// Account ids are preserved on purpose. Folder ids are `<accountId>:<path>`,
/// and those ids are the keys for favourites, hidden folders, expanded state,
/// folder order, Quick Steps and signatures. Issuing fresh account ids on
/// import would leave every one of those pointing at nothing, and the restore
/// would look like it had worked while quietly losing most of what it
/// restored.
@immutable
class SettingsBackup {
  const SettingsBackup({
    required this.accounts,
    required this.entries,
    this.exportedAt,
    this.appVersion,
  });

  /// Accounts as configured, without their secrets.
  final List<Account> accounts;

  /// The preference records, by storage key. Values are whatever that key
  /// holds: a list of ids, a map of orders, or an encoded string.
  final Map<String, Object?> entries;

  final DateTime? exportedAt;
  final String? appVersion;

  /// Bumped only when an older build could not read a newer file correctly.
  /// Adding a key does not count: an older build ignores keys it does not
  /// know, which is exactly the right behaviour.
  static const formatVersion = 1;

  static const _magic = 'myemail.settings';

  String toJsonString() => const JsonEncoder.withIndent('  ').convert({
        'format': _magic,
        'formatVersion': formatVersion,
        if (exportedAt != null) 'exportedAt': exportedAt!.toUtc().toIso8601String(),
        if (appVersion != null) 'appVersion': appVersion,
        'accounts': [for (final a in accounts) accountToBackupJson(a)],
        'settings': entries,
      });

  /// Parse a file someone chose from disk.
  ///
  /// Throws [BackupFormatException] with something a person can act on. Every
  /// failure here is a file the user picked themselves, so "that is not a
  /// MyEmail settings file" is far more use than a JSON parser's complaint
  /// about a character at offset 0.
  factory SettingsBackup.parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const BackupFormatException(
        'That file is not a MyEmail settings file.',
      );
    }
    if (decoded is! Map || decoded['format'] != _magic) {
      throw const BackupFormatException(
        'That file is not a MyEmail settings file.',
      );
    }

    final version = decoded['formatVersion'];
    if (version is! int || version > formatVersion) {
      throw const BackupFormatException(
        'That file was written by a newer version of MyEmail. Update the app '
        'and try again.',
      );
    }

    final accounts = <Account>[];
    final rawAccounts = decoded['accounts'];
    if (rawAccounts is List) {
      for (final entry in rawAccounts) {
        if (entry is! Map) continue;
        final account = accountFromBackupJson(entry.cast<String, Object?>());
        // One unreadable account should not cost the other four, or the
        // settings, so it is skipped rather than thrown over.
        if (account != null) accounts.add(account);
      }
    }

    final settings = decoded['settings'];
    return SettingsBackup(
      accounts: accounts,
      entries: settings is Map
          ? settings.cast<String, Object?>()
          : const <String, Object?>{},
      exportedAt: DateTime.tryParse('${decoded['exportedAt']}'),
      appVersion:
          decoded['appVersion'] is String ? decoded['appVersion'] as String : null,
    );
  }

  /// What a person is about to overwrite, for the confirmation step.
  String get summary {
    final parts = <String>[
      '${accounts.length} ${accounts.length == 1 ? 'account' : 'accounts'}',
      '${entries.length} ${entries.length == 1 ? 'setting' : 'settings'}',
    ];
    return parts.join(', ');
  }
}

Map<String, Object?> accountToBackupJson(Account a) => {
      'id': a.id,
      'displayName': a.displayName,
      'emailAddress': a.emailAddress,
      'provider': a.provider.name,
      'authMethod': a.authMethod.name,
      'colorValue': a.colorValue,
    };

/// Null for anything unreadable rather than throwing. See [SettingsBackup].
Account? accountFromBackupJson(Map<String, Object?> j) {
  final id = j['id'];
  final email = j['emailAddress'];
  if (id is! String || id.isEmpty || email is! String || email.isEmpty) {
    return null;
  }
  return Account(
    id: id,
    displayName: j['displayName'] is String && (j['displayName'] as String).isNotEmpty
        ? j['displayName'] as String
        : email.split('@').first,
    emailAddress: email,
    provider: _byName(MailProvider.values, j['provider'], MailProvider.gmail),
    authMethod:
        _byName(AuthMethod.values, j['authMethod'], AuthMethod.appPassword),
    colorValue: j['colorValue'] is int ? j['colorValue'] as int : 0xFF0F6CBD,
  );
}

T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

@immutable
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}
