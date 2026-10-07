import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/contacts/device_contacts.dart';
import '../data/mail_engine.dart' show PeopleSearchAccess;
import '../domain/address_suggestions.dart';
import '../domain/mail_message.dart';
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

/// Everyone the cached mail has been to or from, counted.
///
/// Read when first needed and kept, then read again in the background when
/// a recipient field is used and the copy here is older than [staleAfter].
/// The cache changes every sync, but a list a few minutes behind is right
/// about everyone who matters, and reading the whole cache on every
/// keystroke is not. The old list serves while the new one is read.
class AddressHistory extends AsyncNotifier<List<AddressSuggestion>> {
  static const staleAfter = Duration(minutes: 5);

  DateTime? _readAt;

  @override
  Future<List<AddressSuggestion>> build() async {
    final people = await ref.watch(mailEngineProvider).recentAddresses();
    _readAt = DateTime.now();
    return people;
  }

  /// Read the cache again, if what is here is older than [staleAfter].
  Future<void> refreshIfStale() async {
    final readAt = _readAt;
    if (readAt == null || DateTime.now().difference(readAt) < staleAfter) {
      return;
    }
    _readAt = DateTime.now();
    try {
      final people = await ref.read(mailEngineProvider).recentAddresses();
      if (ref.mounted) state = AsyncData(people);
    } catch (e) {
      debugPrint('[myemail] could not read who has been mailed: $e');
    }
  }
}

final addressHistoryProvider =
    AsyncNotifierProvider<AddressHistory, List<AddressSuggestion>>(
      AddressHistory.new,
    );

/// The people written to since the app started.
///
/// Someone just written to is someone likely to be written to next, and
/// the cache does not know it until the Sent folder next syncs. Kept apart
/// from [AddressHistory], which a reading of the cache replaces, so a
/// re-read before that sync does not forget them.
class SentThisSession {
  final Map<String, ({MailAddress address, DateTime at})> _people = {};

  void note(Iterable<MailAddress> recipients, DateTime at) {
    for (final a in recipients) {
      final key = a.email.trim().toLowerCase();
      if (key.contains('@')) _people[key] = (address: a, at: at);
    }
  }

  /// [history] with everyone noted counted as written to at the time they
  /// were. At least that: once the Sent folder has synced, the history
  /// counts the same message itself, and adding the two would count it
  /// twice.
  List<AddressSuggestion> over(List<AddressSuggestion> history, DateTime now) {
    if (_people.isEmpty) return history;
    final left = Map.of(_people);
    return [
      for (final h in history)
        if (left.remove(h.email.toLowerCase()) case final noted?)
          AddressSuggestion(
            email: h.email,
            name: h.name ?? noted.address.name,
            fromContacts: h.fromContacts,
            timesSeen: max(h.timesSeen, 1),
            timesSent: max(h.timesSent, 1),
            weight: max(h.weight, recencyWeight(noted.at, now)),
          )
        else
          h,
      for (final noted in left.values)
        AddressSuggestion(
          email: noted.address.email.trim(),
          name: noted.address.name,
          timesSeen: 1,
          timesSent: 1,
          weight: recencyWeight(noted.at, now),
        ),
    ];
  }
}

final sentThisSessionProvider = Provider<SentThisSession>(
  (ref) => SentThisSession(),
);

/// What a recipient field asks as each letter is typed.
final recipientSuggesterProvider = Provider<RecipientSuggester>(
  (ref) => RecipientSuggester(ref),
);

class RecipientSuggester {
  RecipientSuggester(this._ref);

  final Ref _ref;

  /// How long typing has to pause before the accounts' address books are
  /// asked online: a request per letter, most of them overtaken by the
  /// next letter, is the server's time and the phone's data for nothing.
  static const onlineDelay = Duration(milliseconds: 300);

  /// A recipient field has been tapped into: bring the mail history up to
  /// date and ready the online address books, neither waited for.
  void fieldUsed() {
    unawaited(_ref.read(addressHistoryProvider.notifier).refreshIfStale());
    unawaited(_ref.read(mailEngineProvider).warmPeopleSearch());
  }

  /// Who could be meant by [query], best first, as it becomes known.
  ///
  /// The phone's address book, if it may be read, and everyone in the mail
  /// history who matches, at once; then, after [onlineDelay] and once the
  /// accounts' address books online have answered, the same with theirs
  /// added, if they found anyone. Cancelling stops it, the online search
  /// included if it has not started: a field cancels when the next letter
  /// is typed.
  ///
  /// [exclude] is who is in the field already.
  Stream<List<AddressSuggestion>> suggest(
    String query, {
    Set<String> exclude = const {},
  }) {
    var cancelled = false;
    Timer? pause;
    final out = StreamController<List<AddressSuggestion>>(
      onCancel: () {
        cancelled = true;
        pause?.cancel();
      },
    );

    Future<void> run() async {
      // Nothing typed is nobody: the list waits for a letter.
      if (query.trim().isEmpty) return;
      final history = _ref
          .read(sentThisSessionProvider)
          .over(await _ref.read(addressHistoryProvider.future), DateTime.now());
      if (cancelled) return;

      final allowed = _ref.read(contactsAccessProvider).value ?? false;
      final contacts = allowed
          ? await _ref.read(deviceContactsProvider).search(query)
          : const <AddressSuggestion>[];
      if (cancelled) return;
      out.add(
        rankSuggestions(
          query,
          contacts: contacts,
          history: history,
          exclude: exclude,
        ),
      );

      // A Timer, not a delayed future, so cancelling ends the wait too: a
      // field closed mid-pause leaves nothing behind it.
      final waited = Completer<void>();
      pause = Timer(onlineDelay, waited.complete);
      await waited.future;
      if (cancelled) return;
      final online = await _ref.read(mailEngineProvider).searchPeople(query);
      if (cancelled || online.isEmpty) return;
      out.add(
        rankSuggestions(
          query,
          contacts: [...contacts, ...online],
          history: history,
          exclude: exclude,
        ),
      );
    }

    run()
        .catchError((Object e) {
          debugPrint('[myemail] could not suggest recipients: $e');
        })
        .whenComplete(() {
          if (!cancelled) out.close();
        });
    return out.stream;
  }
}

/// Whether an account's address book can be searched online, asked when
/// Settings shows it. Invalidated after a sign-in that may have allowed it.
final peopleSearchAccessProvider = FutureProvider.autoDispose
    .family<PeopleSearchAccess, String>((ref, accountId) {
      return ref.watch(mailEngineProvider).peopleSearchAccess(accountId);
    });
