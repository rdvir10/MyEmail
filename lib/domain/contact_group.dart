import 'package:flutter/foundation.dart';

import 'address_suggestions.dart' show formatRecipient;
import 'mail_message.dart';

/// Several people under one name, typed into To like one person: Outlook's
/// contact groups. Kept in the app and in its settings backup, not in an
/// account's address book, which the contact sync plan leaves alone.
@immutable
class ContactGroup {
  const ContactGroup({
    required this.id,
    required this.name,
    required this.members,
  });

  final String id;
  final String name;
  final List<MailAddress> members;

  /// What goes into a recipients field when the group is chosen: everyone
  /// in it, as the field writes one person, with commas between.
  String get formatted => [
        for (final m in members) formatRecipient(m.name, m.email),
      ].join(', ');

  ContactGroup copyWith({String? name, List<MailAddress>? members}) =>
      ContactGroup(
        id: id,
        name: name ?? this.name,
        members: members ?? this.members,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'members': [
          for (final m in members)
            {'email': m.email, if (m.name != null) 'name': m.name},
        ],
      };

  /// Null for anything that is not a group as [toJson] writes one.
  static ContactGroup? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final members = json['members'];
    if (id is! String || name is! String || members is! List) return null;
    return ContactGroup(
      id: id,
      name: name,
      members: [
        for (final m in members)
          if (m is Map && m['email'] is String)
            MailAddress(
              email: m['email'] as String,
              name: m['name'] is String ? m['name'] as String : null,
            ),
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContactGroup &&
      other.id == id &&
      other.name == name &&
      listEquals(other.members, members);

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(members));
}
