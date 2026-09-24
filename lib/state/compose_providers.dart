import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/compose/mime_parts.dart';
import '../data/compose/quote_builder.dart' show sanitiseForEditing;
import '../data/compose/reply_draft.dart';
import '../data/ui_state_store.dart';
import '../domain/address_suggestions.dart'
    show formatRecipient, splitRecipients;
import '../domain/draft.dart';
import '../domain/error_report.dart' show ReadableError;
import '../domain/mail_message.dart';
import '../domain/signature.dart';
import 'message_providers.dart';
import 'providers.dart';

/// Per-account signatures, persisted with the rest of the UI state.
class Signatures extends Notifier<Map<String, Signature>> {
  @override
  Map<String, Signature> build() {
    final store = ref.watch(uiStateStoreProvider);
    listenSelf((_, next) => store.writeString(
          UiStateKeys.signatures,
          jsonEncode([for (final s in next.values) s.toJson()]),
        ));
    final raw = store.readString(UiStateKeys.signatures);
    if (raw == null || raw.isEmpty) return const {};
    return Signature.mapFromJson(raw) ?? const {};
  }

  void set(Signature signature) =>
      state = {...state, signature.accountId: signature};

  void remove(String accountId) => state = {
        for (final e in state.entries)
          if (e.key != accountId) e.key: e.value,
      };

  Signature forAccount(String accountId) =>
      state[accountId] ?? Signature(accountId: accountId, html: '');
}

final signaturesProvider =
    NotifierProvider<Signatures, Map<String, Signature>>(Signatures.new);

/// Build the draft a compose screen opens with.
///
/// Reply and forward need the original's body, which may not be cached, so
/// this is async and the screen shows a spinner until it resolves.
Future<Draft> buildDraft({
  required WidgetRef ref,
  required ComposeKind kind,
  required String accountId,
  MailMessage? original,
}) async {
  final signature = ref.read(signaturesProvider.notifier).forAccount(accountId);

  MailBody? body;
  if (original != null) {
    try {
      body = await ref.read(mailEngineProvider).loadMessageBody(original.id);
    } catch (_) {
      // Offline or gone: quote what the list already knows.
      body = MailBody(text: original.preview);
    }
  }

  final accounts = ref.read(accountsProvider).value ?? const [];

  final draft = draftFor(
    kind: kind,
    accountId: accountId,
    original: original,
    body: body,
    signature: signature,
    selfEmail: accounts
        .where((a) => a.id == accountId)
        .map((a) => a.emailAddress)
        .firstOrNull ??
        '',
    // A message that reached more than one of your accounts: Reply all
    // copied the others back in, so the answer landed in your own inbox and
    // told everyone on the thread about your other address.
    otherAccountEmails: [for (final a in accounts) a.emailAddress],
  );

  // A forward carries the files, and the pictures the quote shows through
  // cid: links. It used to arrive with the text alone and nothing on the
  // screen saying the files were gone.
  final carriesFiles = original != null &&
      (original.hasAttachments || (body?.html?.contains('cid:') ?? false));
  if (kind != ComposeKind.forward || !carriesFiles) return draft;
  try {
    final raw = await ref.read(mailEngineProvider).rawMessage(original.id);
    return draft.copyWith(attachments: attachmentsInMime(raw));
  } catch (_) {
    // Offline, or the message has gone: say so rather than send without.
    return draft.copyWith(
      lostAttachmentNames: const ["the forwarded message's attachments"],
    );
  }
}

/// Save a draft to the Drafts folder and refresh the tree so it shows there.
///
/// Returns the draft as it now stands, carrying where it was saved, so a
/// second save replaces this copy instead of leaving two.
Future<Draft> saveDraft(WidgetRef ref, Draft draft) async {
  final savedAs = await ref.read(mailEngineProvider).saveDraft(draft);
  await _refreshAfter(ref, draft.accountId, 'save');
  if (savedAs != null) {
    final folderId = savedAs.substring(0, savedAs.lastIndexOf('#'));
    ref.invalidate(messagesProvider(folderId));
    // The copy it replaced was in the same folder, so one invalidation covers
    // both the arrival and the removal.
  }
  return draft.copyWith(savedAs: savedAs);
}

/// The folder tree brought up to date after a send or a save that has
/// already happened.
///
/// A failure here is not the send's or the save's. Reported as theirs, it
/// turned Send back on for a message that had gone, and a second tap sent it
/// twice; a second Save left two copies in Drafts. The next refresh puts the
/// counts right, so it is only logged.
Future<void> _refreshAfter(WidgetRef ref, String accountId, String what) async {
  try {
    await ref.read(foldersProvider.notifier).refreshAccount(accountId);
  } catch (e) {
    debugPrint('[myemail] folder refresh after a $what failed: $e');
  }
}

/// Reopen a message from the Drafts folder as something editable.
///
/// To and Cc come from the message list. Bcc, the thread it answers and the
/// attachments are only in the saved message itself, so that is fetched
/// once as it is stored. Without it a reopened draft went out without its
/// Cc and Bcc, started a new thread, and dropped its files; saving it again
/// replaced the server copy with the same losses. If the stored message
/// cannot be fetched, the draft still opens, and says which files it could
/// not bring back.
Future<Draft> draftFromMessage({
  required WidgetRef ref,
  required MailMessage message,
}) async {
  final engine = ref.read(mailEngineProvider);
  final MailBody body;
  try {
    body = await engine.loadMessageBody(message.id);
  } catch (e) {
    // Not opened with the preview standing in for it. That looked like the
    // draft, and saving it replaced the whole of the real one in Drafts
    // with its first line.
    throw DraftNotLoaded(e);
  }
  final draft = Draft(
    accountId: message.accountId,
    kind: ComposeKind.newMessage,
    to: message.to,
    cc: message.cc,
    subject: message.subject == '(No subject)' ? '' : message.subject,
    // Cleaned like a quote: a Drafts folder can hold messages written by
    // other clients, and the editor runs JavaScript.
    htmlBody: body.html == null
        ? _asHtml(body.text)
        : sanitiseForEditing(body.html!, ownDraft: true),
    inReplyTo: message.inReplyTo,
    savedAs: message.id,
  );

  try {
    final raw = await engine.rawMessage(message.id);
    final headers = savedDraftHeaders(raw);
    return draft.copyWith(
      bcc: headers.bcc,
      inReplyTo: headers.inReplyTo,
      references: headers.references,
      attachments: attachmentsInMime(raw),
    );
  } catch (_) {
    return draft.copyWith(
      lostAttachmentNames:
          message.hasAttachments ? const ['the original attachment'] : const [],
    );
  }
}

/// A saved draft that could not be read, so it was not opened.
class DraftNotLoaded implements Exception, ReadableError {
  const DraftNotLoaded(this.cause);

  final Object cause;

  @override
  String get message => cause is ReadableError
      ? 'This draft could not be opened: ${(cause as ReadableError).message}'
      : 'This draft could not be opened. Try again once connected.';

  @override
  String toString() => message;
}

String _asHtml(String text) => text.isEmpty
    ? '<p><br></p>'
    : text
        .split('\n')
        .map((line) => '<p>${line.isEmpty ? '<br>' : _escape(line)}</p>')
        .join();

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Send a draft and, on success, refresh what the result touched.
Future<void> sendDraft(WidgetRef ref, Draft draft) async {
  await ref.read(mailEngineProvider).sendDraft(draft);
  await _refreshAfter(ref, draft.accountId, 'send');
  // The Sent folder has a new message, and the answered flag may have moved.
  final original = draft.originalMessageId;
  if (original != null) {
    final folderId = original.substring(0, original.lastIndexOf('#'));
    ref.invalidate(messagesProvider(folderId));
  }
}

/// Parse a recipients field: commas or semicolons, optional display names,
/// which may be quoted and may then hold commas of their own.
List<MailAddress> parseAddresses(String raw) {
  final result = <MailAddress>[];
  for (final part in splitRecipients(raw)) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final angled = RegExp(r'^(.*)<([^<>]+)>$').firstMatch(trimmed);
    if (angled != null) {
      var name = angled.group(1)!.trim();
      if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
        name = name
            .substring(1, name.length - 1)
            .replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
      }
      result.add(MailAddress(
        email: angled.group(2)!.trim(),
        name: name.isEmpty ? null : name,
      ));
    } else {
      result.add(MailAddress(email: trimmed));
    }
  }
  return result;
}

/// What a recipients field shows for a parsed list.
String formatAddresses(List<MailAddress> addresses) => addresses
    .map((a) => formatRecipient(a.name, a.email))
    .join(', ');

/// Whether every address looks like an address. Deliberately loose: the
/// server is the real authority, and a strict regex rejects valid addresses.
bool addressesLookValid(List<MailAddress> addresses) =>
    addresses.every((a) =>
        a.email.contains('@') &&
        !a.email.startsWith('@') &&
        !a.email.endsWith('@') &&
        !a.email.contains(' '));
