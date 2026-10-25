import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Settings, Claude (Duet): which accounts' Inboxes go to Ron's connector for
/// Claude (C:/dev/myemail-duet, on Vercel), where Duet reads them. The upload
/// key is not here: it is kept with the account secrets.
@immutable
class DuetSettings {
  const DuetSettings({
    this.enabled = false,
    this.server = defaultServer,
    this.accounts = const {},
    this.readOnce = const {},
  });

  static const defaultServer = 'https://myemail-duet.vercel.app';

  final bool enabled;

  /// The connector's address, without a path.
  final String server;

  /// The accounts whose Inboxes are sent, by id.
  final Set<String> accounts;

  /// Of those, the ones whose messages the connector deletes once Duet has
  /// read them, or after a day: Hadco's. Only the last day's mail is sent.
  final Set<String> readOnce;

  /// Whether [address] is one whose mail is sent read-once at first: Hadco's.
  static bool readOnceByDefault(String address) =>
      address.toLowerCase().trim().endsWith('@hadco-metal.com');

  DuetSettings copyWith({
    bool? enabled,
    String? server,
    Set<String>? accounts,
    Set<String>? readOnce,
  }) =>
      DuetSettings(
        enabled: enabled ?? this.enabled,
        server: server ?? this.server,
        accounts: accounts ?? this.accounts,
        readOnce: readOnce ?? this.readOnce,
      );

  String toJson() => jsonEncode({
        'enabled': enabled,
        'server': server,
        'accounts': accounts.toList()..sort(),
        'readOnce': readOnce.toList()..sort(),
      });

  /// Read back, or the defaults for nothing kept or something unreadable.
  static DuetSettings fromJson(String? text) {
    if (text == null || text.isEmpty) return const DuetSettings();
    try {
      final j = jsonDecode(text);
      if (j is! Map) return const DuetSettings();
      Set<String> ids(Object? v) => {
            for (final s in v is List ? v : const [])
              if (s is String && s.isNotEmpty) s,
          };
      final server = j['server'];
      return DuetSettings(
        enabled: j['enabled'] == true,
        server: server is String && server.trim().isNotEmpty
            ? server.trim()
            : defaultServer,
        accounts: ids(j['accounts']),
        readOnce: ids(j['readOnce']),
      );
    } on FormatException {
      return const DuetSettings();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DuetSettings &&
      other.enabled == enabled &&
      other.server == server &&
      setEquals(other.accounts, accounts) &&
      setEquals(other.readOnce, readOnce);

  @override
  int get hashCode => Object.hash(
        enabled,
        server,
        Object.hashAllUnordered(accounts),
        Object.hashAllUnordered(readOnce),
      );
}
