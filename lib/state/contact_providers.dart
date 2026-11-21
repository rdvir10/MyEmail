import 'contact_groups.dart';
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/contacts/device_contacts.dart';
import '../data/mail_engine.dart'
    show
        ContactSide,
        ContactSyncAccess,
        ContactSyncPreview,
        ContactSyncStatus,
        PeopleSearchAccess;
import '../data/ui_state_store.dart';
import '../domain/address_suggestions.dart';
import '../domain/mail_message.dart';
import 'providers.dart';

/// The address book. main() overrides this with the Android one; tests and
/// the browser preview answer from a list.
final deviceContactsProvider =
    Provider<DeviceContacts>((ref) => FakeDeviceContacts());

/// The contact that holds an address, by the address, or null: what the
/// card for someone on a message says, In your contacts with Open contact,
/// or Add to contacts.
///
/// Asked again each time a card opens, since a contact added from one is
/// saved in another app. Never asks for the permission: the recipient
/// fields do that, once; without it the card offers Add.
final deviceContactProvider =
    FutureProvider.autoDispose.family<DeviceContact?, String>(
  (ref, email) => ref.watch(deviceContactsProvider).find(email),
  retry: (_, _) => null,
);

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
      // An address taken out of the suggestions stays out of them; an
      // address book's entry for it is the book's own.
      final forgotten = _ref.read(forgottenAddressesProvider);
      final history = [
        for (final h in _ref.read(sentThisSessionProvider).over(
              await _ref.read(addressHistoryProvider.future),
              DateTime.now(),
            ))
          if (!forgotten.contains(h.email.trim().toLowerCase())) h,
      ];
      if (cancelled) return;
      // Contact groups whose name has what was typed, first.
      final needle = query.trim().toLowerCase();
      final groups = [
        for (final g in _ref.read(contactGroupsProvider))
          if (g.members.isNotEmpty && g.name.toLowerCase().contains(needle))
            AddressSuggestion.group(g),
      ];

      final allowed = _ref.read(contactsAccessProvider).value ?? false;
      final contacts = allowed
          ? await _ref.read(deviceContactsProvider).search(query)
          : const <AddressSuggestion>[];
      if (cancelled) return;
      out.add([
        ...groups,
        ...rankSuggestions(
          query,
          contacts: contacts,
          history: history,
          exclude: exclude,
        ),
      ]);

      // A Timer, not a delayed future, so cancelling ends the wait too: a
      // field closed mid-pause leaves nothing behind it.
      final waited = Completer<void>();
      pause = Timer(onlineDelay, waited.complete);
      await waited.future;
      if (cancelled) return;
      final online = await _ref.read(mailEngineProvider).searchPeople(query);
      if (cancelled || online.isEmpty) return;
      out.add([
        ...groups,
        ...rankSuggestions(
          query,
          contacts: [...contacts, ...online],
          history: history,
          exclude: exclude,
        ),
      ]);
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

/// Whether contact sync is switched on for this device.
///
/// Kept on the device and never in a backup (see
/// [UiStateKeys.contactSyncDevice]): each device keeps its own record of
/// what it paired and deleted, so only one may sync. The engine's runner
/// has no switch of its own; the shell starts no run while this is off.
class ContactSyncSwitch extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(uiStateStoreProvider).readString(
            UiStateKeys.contactSyncDevice,
          ) ==
      'on';

  /// Off stops the run going, which finishes the write in hand, and
  /// deletes nothing: on again carries on where it stopped.
  Future<void> set(bool on) async {
    final store = ref.read(uiStateStoreProvider);
    final sync = ref.read(mailEngineProvider).contactSync;
    state = on;
    await store.writeString(UiStateKeys.contactSyncDevice, on ? 'on' : null);
    if (!on) await sync.stop();
  }
}

final contactSyncOnProvider =
    NotifierProvider<ContactSyncSwitch, bool>(ContactSyncSwitch.new);

/// Where contact sync stands, read again whenever the engine says it may
/// have changed: a run starting, moving on or ending, an answer queued.
///
/// A run says so at every write, and each saying is a read of the store,
/// so reads are not stacked: one asked for while another is going is
/// made once that one is done, however many were asked for meanwhile.
final contactSyncStatusProvider =
    StreamProvider.autoDispose<ContactSyncStatus>((ref) {
  final sync = ref.watch(mailEngineProvider).contactSync;
  final out = StreamController<ContactSyncStatus>();
  var reading = false;
  var again = false;
  Future<void> read() async {
    if (reading) {
      again = true;
      return;
    }
    reading = true;
    try {
      do {
        again = false;
        try {
          final status = await sync.status();
          if (!out.isClosed) out.add(status);
        } catch (e, s) {
          if (!out.isClosed) out.addError(e, s);
        }
      } while (again && !out.isClosed);
    } finally {
      reading = false;
    }
  }

  final changes = sync.changed.listen((_) => read());
  unawaited(read());
  ref.onDispose(() {
    changes.cancel();
    out.close();
  });
  return out.stream;
});

/// Whether an account allows contact sync, asked when the Contact sync
/// screen shows it (a token for the contacts permission). Invalidated
/// after a sign-in that may have allowed it. Never fails: what went wrong
/// is a state, so there is nothing to retry.
final contactSyncAccessProvider =
    FutureProvider.autoDispose.family<ContactSyncAccess, String>(
  (ref, accountId) =>
      ref.watch(mailEngineProvider).contactSync.access(accountId),
  retry: (_, _) => null,
);

/// Before the first sync: the preview seen and the backup files saved, for
/// the pair of accounts they were of.
///
/// Kept while the app runs rather than on the screen, so that leaving the
/// screen to look at the saved files does not grey Start out again. Not
/// kept beyond that: the preview and the backup are of the address books
/// as they were, and a day later they are not.
@immutable
class ContactSyncFirstSteps {
  const ContactSyncFirstSteps({
    this.pair,
    this.preview,
    this.saved = const {},
  });

  /// The accounts, as [pairKey] gives them.
  final String? pair;
  final ContactSyncPreview? preview;

  /// Whose backup file has been saved.
  final Set<ContactSide> saved;

  bool get backupSaved => saved.containsAll(ContactSide.values);

  static String pairKey(String googleAccountId, String graphAccountId) =>
      '$googleAccountId|$graphAccountId';
}

class ContactSyncFirstStepsNotifier extends Notifier<ContactSyncFirstSteps> {
  @override
  ContactSyncFirstSteps build() => const ContactSyncFirstSteps();

  /// The steps taken for [pair], or none for another pair.
  ContactSyncFirstSteps of(String pair) =>
      state.pair == pair ? state : const ContactSyncFirstSteps();

  void previewed(String pair, ContactSyncPreview preview) =>
      state = ContactSyncFirstSteps(
        pair: pair,
        preview: preview,
        saved: of(pair).saved,
      );

  void backupSaved(String pair, ContactSide side) =>
      state = ContactSyncFirstSteps(
        pair: pair,
        preview: of(pair).preview,
        saved: {...of(pair).saved, side},
      );
}

final contactSyncFirstStepsProvider =
    NotifierProvider<ContactSyncFirstStepsNotifier, ContactSyncFirstSteps>(
  ContactSyncFirstStepsNotifier.new,
);
