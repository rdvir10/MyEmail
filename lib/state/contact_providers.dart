import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/contacts/device_contacts.dart';
import '../domain/address_suggestions.dart';
import 'providers.dart';

/// The address book. main() overrides this with the Android one; tests and
/// the browser preview answer from a list.
final deviceContactsProvider =
    Provider<DeviceContacts>((ref) => FakeDeviceContacts());

/// Whether the address book may be read, and whether we have asked.
///
/// Asked once, the first time a recipient field is used, and not again on
/// our own account: a dialog that comes back every time someone writes a
/// message is a nag, and Android stops showing it anyway after the second
/// refusal. Settings has a switch that asks again for anyone who changes
/// their mind.
class ContactsAccess extends AsyncNotifier<bool> {
  static const _askedKey = 'contacts.asked.v1';

  @override
  Future<bool> build() => ref.watch(deviceContactsProvider).hasPermission();

  bool get hasAsked =>
      ref.read(uiStateStoreProvider).readString(_askedKey) == 'yes';

  /// Ask, if we never have. Returns whether the address book may be read
  /// afterwards.
  Future<bool> askOnce() async {
    if (state.value ?? false) return true;
    if (hasAsked) return false;
    return ask();
  }

  /// Ask regardless, from the Settings switch.
  Future<bool> ask() async {
    ref.read(uiStateStoreProvider).writeString(_askedKey, 'yes');
    final granted = await ref.read(deviceContactsProvider).requestPermission();
    state = AsyncData(granted);
    return granted;
  }
}

final contactsAccessProvider =
    AsyncNotifierProvider<ContactsAccess, bool>(ContactsAccess.new);

/// Everyone the cached mail has been to or from, ranked by how often.
///
/// Read once and kept: the cache changes every sync, but a suggestion list
/// that is a sync behind is still right about everyone who matters, and
/// re-reading a few thousand rows on every keystroke is not.
final addressHistoryProvider = FutureProvider<List<AddressSuggestion>>((ref) {
  return ref.watch(mailEngineProvider).recentAddresses();
});

/// The function a recipient field calls as each letter is typed.
final recipientSuggesterProvider =
    Provider<Future<List<AddressSuggestion>> Function(String)>(
  (ref) => (query) => suggestRecipients(ref, query),
);

/// Who could be meant by [query]: the address book's matches, if it may be
/// read, and everyone in the mail history who matches, merged and ranked.
Future<List<AddressSuggestion>> suggestRecipients(
  Ref ref,
  String query,
) async {
  if (query.trim().isEmpty) return const [];
  final history = await ref.read(addressHistoryProvider.future);
  final allowed = ref.read(contactsAccessProvider).value ?? false;
  final contacts = allowed
      ? await ref.read(deviceContactsProvider).search(query)
      : const <AddressSuggestion>[];
  return rankSuggestions(query, contacts: contacts, history: history);
}
