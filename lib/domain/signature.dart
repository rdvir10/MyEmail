import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'draft.dart' show ComposeKind;

/// One signature, with the name it is chosen by.
@immutable
class NamedSignature {
  const NamedSignature({
    required this.id,
    required this.name,
    required this.html,
  });

  final String id;
  final String name;

  /// Stored as HTML because that is what the editor and the sent message
  /// use.
  final String html;

  bool get isEmpty => html.trim().isEmpty;

  NamedSignature copyWith({String? name, String? html}) => NamedSignature(
        id: id,
        name: name ?? this.name,
        html: html ?? this.html,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'html': html};

  static NamedSignature? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], html = j['html'];
    if (id is! String || name is! String || html is! String) return null;
    return NamedSignature(id: id, name: name, html: html);
  }

  @override
  bool operator ==(Object other) =>
      other is NamedSignature &&
      other.id == id &&
      other.name == name &&
      other.html == html;

  @override
  int get hashCode => Object.hash(id, name, html);
}

/// An account's signatures, as Outlook keeps them: any number, each with a
/// name, and which of them goes on a new message and which on a reply or a
/// forward, either of which may be none.
@immutable
class Signature {
  const Signature({
    required this.accountId,
    this.named = const [],
    this.forNew,
    this.forReplies,
  });

  /// The one signature an account had before there could be several: used
  /// on new messages, and on replies and forwards where [onReply].
  factory Signature.single({
    required String accountId,
    required String html,
    bool onReply = true,
  }) {
    if (html.trim().isEmpty) return Signature(accountId: accountId);
    return Signature(
      accountId: accountId,
      named: [NamedSignature(id: mainId, name: 'Signature', html: html)],
      forNew: mainId,
      forReplies: onReply ? mainId : null,
    );
  }

  /// The id the one signature of the old shape is kept under.
  static const mainId = 'main';

  final String accountId;
  final List<NamedSignature> named;

  /// The ids of the signatures for new messages, and for replies and
  /// forwards. Null for none.
  final String? forNew;
  final String? forReplies;

  NamedSignature? byId(String? id) =>
      id == null ? null : named.where((s) => s.id == id).firstOrNull;

  /// What a message of [kind] starts with: '' for none.
  String htmlFor(ComposeKind kind) =>
      byId(kind == ComposeKind.newMessage ? forNew : forReplies)?.html ?? '';

  bool get isEmpty => named.every((s) => s.isEmpty);

  /// The new-message signature, or the first there is: what a list of
  /// accounts shows for one.
  String get html => (byId(forNew) ?? named.firstOrNull)?.html ?? '';

  /// Whether replies and forwards are signed at all.
  bool get onReply => byId(forReplies) != null;

  /// [signature] in place of the one with its id, or added at the end. The
  /// first signature an account has is its default for new messages and
  /// for replies, as the old single signature was.
  Signature withSignature(NamedSignature signature) {
    final at = named.indexWhere((s) => s.id == signature.id);
    final next = at < 0
        ? [...named, signature]
        : [for (final (i, s) in named.indexed) i == at ? signature : s];
    final first = named.isEmpty;
    return Signature(
      accountId: accountId,
      named: next,
      forNew: first ? signature.id : forNew,
      forReplies: first ? signature.id : forReplies,
    );
  }

  /// Without the signature [id], and no longer the default for anything.
  Signature without(String id) => Signature(
        accountId: accountId,
        named: [
          for (final s in named)
            if (s.id != id) s,
        ],
        forNew: forNew == id ? null : forNew,
        forReplies: forReplies == id ? null : forReplies,
      );

  /// With the defaults set: [forNew] and [forReplies] as given, either
  /// null for none.
  Signature withDefaults({
    required String? forNew,
    required String? forReplies,
  }) =>
      Signature(
        accountId: accountId,
        named: named,
        forNew: byId(forNew)?.id,
        forReplies: byId(forReplies)?.id,
      );

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'named': [for (final s in named) s.toJson()],
        'forNew': ?forNew,
        'forReplies': ?forReplies,
      };

  /// Either shape: the named signatures, or the one signature of before
  /// ({accountId, html, onReply}), which becomes [Signature.single].
  static Signature fromJson(Map<String, dynamic> j) {
    final accountId = j['accountId'] as String;
    final named = j['named'];
    if (named is List) {
      return Signature(
        accountId: accountId,
        named: [for (final s in named) ?NamedSignature.fromJson(s)],
        forNew: j['forNew'] as String?,
        forReplies: j['forReplies'] as String?,
      );
    }
    return Signature.single(
      accountId: accountId,
      html: j['html'] as String,
      onReply: j['onReply'] as bool? ?? true,
    );
  }

  /// Every signature in [raw] that can be read, by account, or null when
  /// [raw] is not a list of signatures at all.
  ///
  /// One at a time, so one damaged entry costs that account's signature and
  /// not everyone's. A stored value of the wrong shape used to throw out of
  /// the signatures provider, and compose failed on every account until the
  /// app's data was cleared.
  static Map<String, Signature>? mapFromJson(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (json is! List) return null;
    return {
      for (final s in [for (final j in json) ?_tryFromJson(j)]) s.accountId: s,
    };
  }

  static Signature? _tryFromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    try {
      return fromJson(j);
    } on TypeError {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Signature &&
      other.accountId == accountId &&
      listEquals(other.named, named) &&
      other.forNew == forNew &&
      other.forReplies == forReplies;

  @override
  int get hashCode =>
      Object.hash(accountId, Object.hashAll(named), forNew, forReplies);
}
