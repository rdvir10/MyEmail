import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, immutable, kIsWeb, TargetPlatform, debugPrint;
import 'package:flutter/services.dart';

import '../../domain/address_suggestions.dart';

/// The device's address book, as far as the app needs it: recipients
/// suggested as they are typed, and someone on a message added to it or
/// opened in it.
///
/// A port, so the compose screen can be tested without a phone and so the
/// browser preview, which has no address book, behaves like a phone that
/// has not granted the permission: [AndroidDeviceContacts] asks the
/// platform, [FakeDeviceContacts] answers from a list.
abstract class DeviceContacts {
  Future<bool> hasPermission();

  /// Show Android's own dialog. True if granted, now or already.
  Future<bool> requestPermission();

  /// Contacts whose name or address starts with [query]. Empty without the
  /// permission — never an error, because suggestions are a convenience
  /// and a field that cannot be typed in is not.
  Future<List<AddressSuggestion>> search(String query, {int limit = 12});

  /// The contact that holds [email], or null: none does, or the address
  /// book may not be read. Never an error: not knowing only means Add is
  /// offered where Open could have been.
  Future<DeviceContact?> find(String email);

  /// The contacts app's new-contact screen, [name] and [email] filled in,
  /// where the person picks the account that keeps it and saves it. No
  /// permission is involved. False where no app takes it.
  Future<bool> add({String? name, required String email});

  /// [contact] in the contacts app. False where no app takes it.
  Future<bool> open(DeviceContact contact);
}

/// A contact in the address book, as far as opening it needs.
@immutable
class DeviceContact {
  const DeviceContact({required this.uri, this.name});

  /// The address book's link to it, which still finds it after the address
  /// book merges or re-syncs it.
  final String uri;

  /// The name it is filed under, which may not be the one on the mail.
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is DeviceContact && other.uri == uri && other.name == name;

  @override
  int get hashCode => Object.hash(uri, name);
}

class AndroidDeviceContacts implements DeviceContacts {
  const AndroidDeviceContacts();

  static const _channel = MethodChannel('mailtree/contacts');

  @override
  Future<bool> hasPermission() async =>
      await _channel.invokeMethod<bool>('hasPermission') ?? false;

  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;

  @override
  Future<List<AddressSuggestion>> search(String query, {int limit = 12}) async {
    if (query.trim().isEmpty) return const [];
    try {
      final rows = await _channel.invokeListMethod<Object?>(
        'search',
        {'query': query, 'limit': limit},
      );
      return [
        for (final row in rows ?? const [])
          if (row is Map && row['email'] is String)
            AddressSuggestion(
              email: row['email'] as String,
              name: row['name'] as String?,
              fromContacts: true,
            ),
      ];
    } catch (e) {
      debugPrint('[myemail] could not search contacts: $e');
      return const [];
    }
  }

  @override
  Future<DeviceContact?> find(String email) async {
    if (email.trim().isEmpty) return null;
    try {
      final row = await _channel.invokeMapMethod<String, Object?>(
        'find',
        {'email': email},
      );
      final uri = row?['uri'];
      if (uri is! String || uri.isEmpty) return null;
      final name = row?['name'];
      return DeviceContact(uri: uri, name: name is String ? name : null);
    } catch (e) {
      debugPrint('[myemail] could not look in contacts: $e');
      return null;
    }
  }

  @override
  Future<bool> add({String? name, required String email}) =>
      _start('insert', {'name': name, 'email': email});

  @override
  Future<bool> open(DeviceContact contact) =>
      _start('open', {'uri': contact.uri});

  /// One of the contacts app's screens; a failure reads as there being no
  /// app to take it, which is what the person can do something about.
  Future<bool> _start(String method, Map<String, Object?> arguments) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } catch (e) {
      debugPrint('[myemail] could not open the contacts app ($method): $e');
      return false;
    }
  }
}

/// A list stands in for the address book. Tests, and the browser preview.
class FakeDeviceContacts implements DeviceContacts {
  FakeDeviceContacts({this.granted = false, List<AddressSuggestion>? people})
      : people = people ?? const [];

  bool granted;

  /// What the next request will answer. Tests set it to say no.
  bool grantWhenAsked = true;
  int asked = 0;
  final List<AddressSuggestion> people;

  /// Whether a contacts app takes what [add] and [open] hand it. Tests set
  /// it to say there is none.
  bool hasApp = true;

  /// Everyone handed to the new-contact screen, and every contact opened,
  /// for tests to look at.
  final List<({String? name, String email})> added = [];
  final List<DeviceContact> opened = [];

  @override
  Future<bool> hasPermission() async => granted;

  @override
  Future<bool> requestPermission() async {
    asked++;
    if (grantWhenAsked) granted = true;
    return granted;
  }

  @override
  Future<List<AddressSuggestion>> search(String query, {int limit = 12}) async {
    if (!granted) return const [];
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return [
      for (final p in people)
        if (suggestionMatches(p, needle))
          AddressSuggestion(email: p.email, name: p.name, fromContacts: true),
    ].take(limit).toList();
  }

  @override
  Future<DeviceContact?> find(String email) async {
    if (!granted) return null;
    final wanted = email.trim().toLowerCase();
    for (final p in people) {
      if (p.email.trim().toLowerCase() != wanted) continue;
      return DeviceContact(
        uri: 'content://com.android.contacts/contacts/lookup/${p.email}',
        name: p.name,
      );
    }
    return null;
  }

  @override
  Future<bool> add({String? name, required String email}) async {
    if (!hasApp) return false;
    added.add((name: name, email: email));
    return true;
  }

  @override
  Future<bool> open(DeviceContact contact) async {
    if (!hasApp) return false;
    opened.add(contact);
    return true;
  }
}

DeviceContacts platformDeviceContacts() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const AndroidDeviceContacts()
        : FakeDeviceContacts();
