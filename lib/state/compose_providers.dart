import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/compose/reply_draft.dart';
import '../data/ui_state_store.dart';
import '../domain/draft.dart';
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
    try {
      final list = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      return {
        for (final j in list)
          if (Signature.fromJson(j) case final s) s.accountId: s,
      };
    } on FormatException {
      return const {};
    }
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

  return draftFor(
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
  );
}

/// Save a draft to the Drafts folder and refresh the tree so it shows there.
///
/// Returns the draft as it now stands, carrying where it was saved, so a
/// second save replaces this copy instead of leaving two.
Future<Draft> saveDraft(WidgetRef ref, Draft draft) async {
  final savedAs = await ref.read(mailEngineProvider).saveDraft(draft);
  await ref.read(foldersProvider.notifier).refreshAccount(draft.accountId);
  if (savedAs != null) {
    final folderId = savedAs.substring(0, savedAs.lastIndexOf('#'));
    ref.invalidate(messagesProvider(folderId));
    // The copy it replaced was in the same folder, so one invalidation covers
    // both the arrival and the removal.
  }
  return draft.copyWith(savedAs: savedAs);
}

/// Reopen a message from the Drafts folder as something editable.
///
/// Attachments do not come back: the cache holds the body, not the parts, and
/// re-fetching them to rebuild bytes for something that may be discarded is
/// not worth a round trip per attachment. The names are carried instead so
/// the screen can say what is missing rather than losing it quietly.
Future<Draft> draftFromMessage({
  required WidgetRef ref,
  required MailMessage message,
}) async {
  MailBody? body;
  try {
    body = await ref.read(mailEngineProvider).loadMessageBody(message.id);
  } catch (_) {
    body = MailBody(text: message.preview);
  }
  return Draft(
    accountId: message.accountId,
    kind: ComposeKind.newMessage,
    to: message.to,
    subject: message.subject == '(No subject)' ? '' : message.subject,
    htmlBody: body.html ?? _asHtml(body.text),
    savedAs: message.id,
    lostAttachmentNames:
        message.hasAttachments ? const ['the original attachment'] : const [],
  );
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
  await ref.read(foldersProvider.notifier).refreshAccount(draft.accountId);
  // The Sent folder has a new message, and the answered flag may have moved.
  final original = draft.originalMessageId;
  if (original != null) {
    final folderId = original.substring(0, original.lastIndexOf('#'));
    ref.invalidate(messagesProvider(folderId));
  }
}

/// Parse a recipients field: commas or semicolons, optional display names.
List<MailAddress> parseAddresses(String raw) {
  final parts = raw.split(RegExp(r'[,;]'));
  final result = <MailAddress>[];
  for (final part in parts) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final angled = RegExp(r'^(.*?)<([^>]+)>$').firstMatch(trimmed);
    if (angled != null) {
      final name = angled.group(1)!.trim().replaceAll(RegExp(r'^"|"$'), '');
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
String formatAddresses(List<MailAddress> addresses) =>
    addresses.map((a) => a.name == null ? a.email : '${a.name} <${a.email}>')
        .join(', ');

/// Whether every address looks like an address. Deliberately loose: the
/// server is the real authority, and a strict regex rejects valid addresses.
bool addressesLookValid(List<MailAddress> addresses) =>
    addresses.every((a) =>
        a.email.contains('@') &&
        !a.email.startsWith('@') &&
        !a.email.endsWith('@') &&
        !a.email.contains(' '));
