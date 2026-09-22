import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/account.dart';

/// Where the configured accounts live. Only the non-secret half: address,
/// display name, provider, auth method. Passwords go to [CredentialStore].
abstract class AccountStore {
  List<Account> read();
  Future<void> write(List<Account> accounts);
}

class PrefsAccountStore implements AccountStore {
  PrefsAccountStore(this._prefs);

  static const _key = 'accounts.v1';

  final SharedPreferencesWithCache _prefs;

  @override
  List<Account> read() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in list) accountFromJson(e as Map<String, dynamic>),
      ];
    } on FormatException {
      return const [];
    }
  }

  @override
  Future<void> write(List<Account> accounts) =>
      _prefs.setString(_key, jsonEncode([for (final a in accounts) accountToJson(a)]));
}

class MemoryAccountStore implements AccountStore {
  MemoryAccountStore([List<Account> initial = const []])
      : _accounts = List.of(initial);

  List<Account> _accounts;

  @override
  List<Account> read() => List.unmodifiable(_accounts);

  @override
  Future<void> write(List<Account> accounts) async =>
      _accounts = List.of(accounts);
}

Map<String, dynamic> accountToJson(Account a) => {
      'id': a.id,
      'displayName': a.displayName,
      // Only when one was chosen. Absent means "use the label",
      // which is what every account did before this existed.
      if (a.hasOwnSenderName) 'senderName': a.senderName,
      'emailAddress': a.emailAddress,
      'provider': a.provider.name,
      'authMethod': a.authMethod.name,
      'colorValue': a.colorValue,
    };

Account accountFromJson(Map<String, dynamic> j) => Account(
      id: j['id'] as String,
      displayName: j['displayName'] as String,
      chosenSenderName:
          j['senderName'] is String ? j['senderName'] as String : null,
      emailAddress: j['emailAddress'] as String,
      provider: MailProvider.values.byName(j['provider'] as String),
      authMethod: AuthMethod.values.byName(j['authMethod'] as String),
      colorValue: j['colorValue'] as int,
    );
