import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_state_store.dart';
import '../domain/folder_role.dart';
import '../domain/mail_message.dart';
import 'providers.dart';

/// Read-receipt requests answered on this device, sent or declined, so a
/// message opened again does not ask again. By the message's Message-ID,
/// which follows it between folders, or its id where it has none; the
/// newest [limit] are kept.
///
/// Not in the backup, like the pins. The server is told as well where it
/// keeps such a mark (IMAP's `$MDNSent`), for other mail apps.
class AnsweredReceipts extends Notifier<Set<String>> {
  static const limit = 500;

  @override
  Set<String> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeIds(UiStateKeys.answeredReceipts, next));
    return store.readIds(UiStateKeys.answeredReceipts);
  }

  void add(MailMessage message) {
    final key = receiptKey(message);
    if (state.contains(key)) return;
    final next = [...state, key];
    state = next.skip(next.length > limit ? next.length - limit : 0).toSet();
  }
}

final answeredReceiptsProvider =
    NotifierProvider<AnsweredReceipts, Set<String>>(AnsweredReceipts.new);

/// What a message's answered request is known by: see [AnsweredReceipts].
String receiptKey(MailMessage message) => message.messageId ?? message.id;

/// Whether a request on [message] is one to answer at all: not on mail in
/// Junk (a receipt tells whoever sent it that the address is read), Sent
/// or Drafts, nor on mail from one of the accounts.
bool answersReceiptOn(
  MailMessage message, {
  required FolderRole? role,
  required Set<String> ownAddresses,
}) =>
    role != FolderRole.junk &&
    role != FolderRole.sent &&
    role != FolderRole.drafts &&
    !ownAddresses.contains(message.from.email.trim().toLowerCase());
