import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/compose/quote_builder.dart';
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

  final html = buildComposeHtml(
    kind: kind,
    original: original,
    originalHtml: body?.html,
    originalText: body?.text,
    signatureHtml: signature.html,
    signatureOnReply: signature.onReply,
  );

  return Draft(
    accountId: accountId,
    kind: kind,
    to: _initialTo(kind, original),
    cc: kind == ComposeKind.replyAll ? _initialCc(original, accountId, ref) : const [],
    subject: _initialSubject(kind, original),
    htmlBody: html,
    inReplyTo: original == null ? null : '<${original.uid}@mailtree.local>',
    originalMessageId: original?.id,
  );
}

List<MailAddress> _initialTo(ComposeKind kind, MailMessage? original) {
  if (original == null || kind == ComposeKind.forward) return const [];
  return [original.from];
}

/// Reply-all keeps the other recipients but never the account itself, or the
/// sender ends up on their own reply.
List<MailAddress> _initialCc(
  MailMessage? original,
  String accountId,
  WidgetRef ref,
) {
  if (original == null) return const [];
  final accounts = ref.read(accountsProvider).value ?? const [];
  final self = accounts
      .where((a) => a.id == accountId)
      .map((a) => a.emailAddress.toLowerCase())
      .toSet();
  return [
    for (final a in original.to)
      if (!self.contains(a.email.toLowerCase())) a,
  ];
}

String _initialSubject(ComposeKind kind, MailMessage? original) {
  if (original == null) return '';
  final subject = original.subject;
  return switch (kind) {
    ComposeKind.reply || ComposeKind.replyAll =>
      _hasPrefix(subject, 'Re:') ? subject : 'Re: $subject',
    ComposeKind.forward =>
      _hasPrefix(subject, 'Fwd:') ? subject : 'Fwd: $subject',
    ComposeKind.newMessage => '',
  };
}

bool _hasPrefix(String subject, String prefix) =>
    subject.toLowerCase().startsWith(prefix.toLowerCase());

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
