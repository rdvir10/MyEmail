import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:flutter/services.dart';

import '../../domain/address_suggestions.dart';

/// The device's address book, as far as recipients need it.
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
}

DeviceContacts platformDeviceContacts() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? const AndroidDeviceContacts()
        : FakeDeviceContacts();
