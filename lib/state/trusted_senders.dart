import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import '../domain/trusted_senders.dart';
import 'providers.dart';

/// The senders whose pictures load without asking, kept across restarts.
///
/// One flat set of entries: addresses as they are, domains with a leading
/// `@`. See `domain/trusted_senders.dart` for why both.
class TrustedSenders extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeIds(UiStateKeys.trustedSenders, next));
    return store.readIds(UiStateKeys.trustedSenders);
  }

  void trust(String entry) {
    final clean = entry.trim().toLowerCase();
    if (clean.isEmpty || clean == '@') return;
    state = {...state, clean};
  }

  void forget(String entry) =>
      state = {for (final e in state) if (e != entry) e};

  bool trusts(String? email) => isSenderTrusted(state, email);
}

final trustedSendersProvider =
    NotifierProvider<TrustedSenders, Set<String>>(TrustedSenders.new);
