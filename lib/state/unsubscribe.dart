import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:http/http.dart' as http;

import '../data/compose/reply_draft.dart' show escapeHtml;
import '../data/files/file_bridge.dart' show MailtoLink;
import '../domain/draft.dart';
import '../domain/folder_role.dart';
import '../domain/mail_message.dart';
import '../domain/unsubscribe.dart';
import 'providers.dart';

/// How the open message's mailing list says to leave it, asked of the
/// server when the message is opened: see [UnsubscribeOptions]. Null where
/// it says nothing, and where it could not be asked: the button is all a
/// failure costs, so it is never an error.
final unsubscribeOptionsProvider = FutureProvider.autoDispose
    .family<UnsubscribeOptions?, String>((ref, messageId) async {
  try {
    return await ref.watch(mailEngineProvider).unsubscribeOptions(messageId);
  } catch (e) {
    debugPrint('[myemail] unsubscribe headers not read: $e');
    return null;
  }
});

/// Whether a message is one to offer Unsubscribe on at all. Not in Junk,
/// where Outlook does not offer it either: unsubscribing from spam tells
/// whoever sent it that the address is read. Not in Sent or Drafts, and
/// not on mail from one of the accounts, which is your own.
bool offersUnsubscribe(
  MailMessage message, {
  required FolderRole? role,
  required Set<String> ownAddresses,
}) =>
    role != FolderRole.junk &&
    role != FolderRole.sent &&
    role != FolderRole.drafts &&
    !ownAddresses.contains(message.from.email.trim().toLowerCase());

/// The lists left this session, by [unsubscribeKey], so every message from
/// one says so rather than offering to leave again.
class Unsubscribed extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(UnsubscribeOptions options) =>
      state = {...state, unsubscribeKey(options)};
}

final unsubscribedProvider =
    NotifierProvider<Unsubscribed, Set<String>>(Unsubscribed.new);

/// One list's identity: the way out it gives, which every message from it
/// carries alike.
String unsubscribeKey(UnsubscribeOptions options) =>
    '${options.oneClick ?? options.mailto ?? options.web}';

/// RFC 8058's one-click request: a POST of the one line it asks for, sent
/// with nothing of the person's (no cookies, no sign-in). Answers with the
/// HTTP status. A provider so a test can answer it.
final oneClickUnsubscribeProvider = Provider<Future<int> Function(Uri)>(
  (ref) => (uri) async {
    final client = http.Client();
    try {
      final response = await client
          .post(
            uri,
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'List-Unsubscribe=One-Click',
          )
          .timeout(const Duration(seconds: 20));
      return response.statusCode;
    } finally {
      client.close();
    }
  },
);

/// What came of an Unsubscribe.
enum UnsubscribeOutcome {
  /// The list took the one-click request.
  done,

  /// The email it asked for went, from the account the message came to.
  sent,

  /// Its page is open in the browser, to finish there.
  opened,

  /// Nothing worked.
  failed,
}

/// Leave the list [message] came from, the best way [options] gives: one
/// click, else the email, else its page. A way that fails falls to the
/// next, so a one-click address that is down still leaves by email.
///
/// [read] is a ref's read, a widget's or a container's.
Future<UnsubscribeOutcome> unsubscribe(
  T Function<T>(ProviderListenable<T> provider) read,
  MailMessage message,
  UnsubscribeOptions options,
) async {
  if (options.oneClick case final uri?) {
    try {
      final status = await read(oneClickUnsubscribeProvider)(uri);
      // A redirect to a page saying so is the request taken, as much as
      // a 200 is: the request is the unsubscribe, the page only says it.
      if (status >= 200 && status < 400) {
        read(unsubscribedProvider.notifier).add(options);
        return UnsubscribeOutcome.done;
      }
      debugPrint('[myemail] one-click unsubscribe answered $status');
    } catch (e) {
      debugPrint('[myemail] one-click unsubscribe failed: $e');
    }
  }
  if (options.mailto case final uri?) {
    final link = MailtoLink.parse('$uri');
    final to = link?.to.where((a) => a.contains('@')).toList() ?? const [];
    if (to.isNotEmpty) {
      try {
        final words = link?.body?.trim();
        await read(mailEngineProvider).sendDraft(
              Draft(
                accountId: message.accountId,
                kind: ComposeKind.newMessage,
                to: [for (final a in to) MailAddress(email: a)],
                subject: (link?.subject?.trim().isNotEmpty ?? false)
                    ? link!.subject!.trim()
                    : 'Unsubscribe',
                htmlBody: '<p>${escapeHtml(
                  words == null || words.isEmpty ? 'Unsubscribe' : words,
                )}</p>',
              ),
            );
        read(unsubscribedProvider.notifier).add(options);
        return UnsubscribeOutcome.sent;
      } catch (e) {
        debugPrint('[myemail] unsubscribe email not sent: $e');
      }
    }
  }
  if (options.web case final uri?) {
    if (await read(openInBrowserProvider)(uri)) {
      return UnsubscribeOutcome.opened;
    }
  }
  return UnsubscribeOutcome.failed;
}
