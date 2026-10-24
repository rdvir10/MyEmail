import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import '../domain/contact_group.dart';
import '../domain/mail_message.dart';
import 'providers.dart';

/// Settings, View, Contact groups: kept across restarts and in the
/// settings backup.
class ContactGroups extends Notifier<List<ContactGroup>> {
  @override
  List<ContactGroup> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(
          UiStateKeys.contactGroups,
          jsonEncode([for (final g in next) g.toJson()]),
        ));
    final raw = store.readString(UiStateKeys.contactGroups);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [for (final entry in decoded) ?ContactGroup.fromJson(entry)];
    } on FormatException {
      return const [];
    }
  }

  /// [group] in place of the one with its id, or added in name order.
  void save(ContactGroup group) {
    final others = [
      for (final g in state)
        if (g.id != group.id) g,
    ];
    state = [...others, group]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  void remove(String id) => state = [
        for (final g in state)
          if (g.id != id) g,
      ];
}

final contactGroupsProvider =
    NotifierProvider<ContactGroups, List<ContactGroup>>(ContactGroups.new);

/// Addresses taken out of the suggestions from mail history, lower-cased:
/// Outlook's X beside an Auto-Complete name, for a typo once written to.
/// An address book keeps its own; and writing to one again brings it back,
/// as Outlook does.
class ForgottenAddresses extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf(
      (_, next) => store.writeIds(UiStateKeys.forgottenAddresses, next),
    );
    return store.readIds(UiStateKeys.forgottenAddresses);
  }

  void forget(String email) =>
      state = {...state, email.trim().toLowerCase()};

  /// Written to again: suggested again.
  void remember(Iterable<MailAddress> people) {
    final back = {for (final p in people) p.email.trim().toLowerCase()};
    if (!state.any(back.contains)) return;
    state = {
      for (final e in state)
        if (!back.contains(e)) e,
    };
  }
}

final forgottenAddressesProvider =
    NotifierProvider<ForgottenAddresses, Set<String>>(ForgottenAddresses.new);
