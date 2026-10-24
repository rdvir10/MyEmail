import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'trusted_senders.dart' show describeTrustEntry, trustAddress, trustDomain;

/// Outlook's Block Sender, Never Block Sender and Never Block Sender's
/// Domain, kept by the app: new mail from a blocked sender goes from the
/// Inbox to Junk as it arrives, unless the sender is also never to be
/// blocked, which is what Not Junk makes them.
///
/// Entries are written as the trusted senders' are: an address as it is,
/// a whole domain with a leading `@`.
@immutable
class SenderBlocks {
  const SenderBlocks({this.blocked = const {}, this.safe = const {}});

  final Set<String> blocked;

  /// Never blocked, by address or domain: a match here wins over a block.
  final Set<String> safe;

  bool get isEmpty => blocked.isEmpty;

  /// Whether mail from [email] goes to Junk as it arrives.
  bool blocks(String? email) {
    if (email == null || email.trim().isEmpty || blocked.isEmpty) return false;
    return _covers(blocked, email) && !_covers(safe, email);
  }

  /// Whether [email] is on the never-blocked list, by name or by domain.
  bool neverBlocks(String? email) =>
      email != null && email.trim().isNotEmpty && _covers(safe, email);

  static bool _covers(Set<String> entries, String email) {
    if (entries.contains(trustAddress(email))) return true;
    final domain = trustDomain(email);
    return domain != null && entries.contains(domain);
  }

  /// Blocked from now on, and no longer on the never-blocked list.
  SenderBlocks block(String entry) {
    final e = _clean(entry);
    if (e == null) return this;
    return SenderBlocks(
      blocked: {...blocked, e},
      safe: {for (final s in safe) if (s != e) s},
    );
  }

  /// Never blocked from now on, and no longer blocked by that entry.
  SenderBlocks neverBlock(String entry) {
    final e = _clean(entry);
    if (e == null) return this;
    return SenderBlocks(
      blocked: {for (final b in blocked) if (b != e) b},
      safe: {...safe, e},
    );
  }

  /// Off both lists.
  SenderBlocks forget(String entry) {
    final e = _clean(entry);
    return SenderBlocks(
      blocked: {for (final b in blocked) if (b != e) b},
      safe: {for (final s in safe) if (s != e) s},
    );
  }

  /// An address or `@domain` as an entry, or null for one that is neither.
  static String? _clean(String entry) {
    final e = entry.trim().toLowerCase();
    if (e.isEmpty || e == '@') return null;
    if (e.startsWith('@')) return e.contains('.') ? e : null;
    return e.contains('@') ? e : null;
  }

  /// [text] as an entry, for a field where one is typed: `dana@example.com`
  /// as it is, and `example.com` or `@example.com` as the domain. Null for
  /// anything else.
  static String? entryFrom(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    return _clean(t.contains('@') ? t : '@$t');
  }

  Map<String, Object?> toJson() => {
        'blocked': blocked.toList()..sort(),
        'safe': safe.toList()..sort(),
      };

  factory SenderBlocks.fromJson(Map<String, Object?> json) {
    Set<String> setOf(Object? v) => {
          for (final e in v is List ? v : const [])
            if (e is String && e.isNotEmpty) e,
        };
    return SenderBlocks(blocked: setOf(json['blocked']), safe: setOf(json['safe']));
  }

  /// As kept in the settings store; empty for nothing kept, or anything
  /// that does not read.
  static SenderBlocks fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return const SenderBlocks();
    try {
      final json = jsonDecode(raw);
      return json is Map
          ? SenderBlocks.fromJson(json.cast<String, Object?>())
          : const SenderBlocks();
    } on FormatException {
      return const SenderBlocks();
    }
  }

  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is SenderBlocks &&
      setEquals(other.blocked, blocked) &&
      setEquals(other.safe, safe);

  @override
  int get hashCode => Object.hash(
        Object.hashAllUnordered(blocked),
        Object.hashAllUnordered(safe),
      );
}

/// How an entry reads in a list: a domain says so, an address is itself.
String describeSenderEntry(String entry) => describeTrustEntry(entry);
