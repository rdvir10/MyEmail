import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../data/ui_state_store.dart';
import '../domain/folder_role.dart';
import '../domain/mail_message.dart';
import '../domain/trusted_senders.dart';
import 'display_providers.dart';
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

/// [picturesLoadUnasked] for [message]: the one rule for the reading pane,
/// full screen and printing. [read] is a ref's watch or read.
///
/// A folder the folder list does not have yet may be Junk, so its mail
/// waits too: a message's own window can have the message before the
/// list, and pictures once loaded are not taken back.
bool picturesShownFor(
  T Function<T>(ProviderListenable<T> provider) read,
  MailMessage message,
) {
  final role = read(
    folderIndexProvider.select((index) => index[message.folderId]?.role),
  );
  return picturesLoadUnasked(
    always: read(displayProvider.select((d) => d.alwaysShowImages)),
    trusted: read(trustedSendersProvider),
    email: message.from.email,
    mayBeJunk: role == null || role == FolderRole.junk,
  );
}
