import '../../domain/draft.dart';
import '../../domain/mail_message.dart';
import '../../domain/signature.dart';
import 'quote_builder.dart';

/// The draft a reply or a forward starts from, built from values rather than
/// from the app.
///
/// Pulled out of the compose screen's provider because a reply is now written
/// in two places: the compose screen, and the notification shade, where there
/// is no widget tree and often no running app at all. Both have to produce
/// the same message — the same quoted original, the same attribution line,
/// the same signature rule — or a reply sent from the shade would read as a
/// different app's work.
Draft draftFor({
  required ComposeKind kind,
  required String accountId,
  MailMessage? original,
  MailBody? body,
  Signature? signature,
  String selfEmail = '',
  List<String> otherAccountEmails = const [],
  String typedText = '',
}) {
  final html = buildComposeHtml(
    kind: kind,
    original: original,
    originalHtml: body?.html,
    originalText: body?.text,
    signatureHtml: signature?.html ?? '',
    signatureOnReply: signature?.onReply ?? true,
    typedHtml: typedText.trim().isEmpty ? '' : asParagraphs(typedText),
  );

  final mine = {
    for (final e in [selfEmail, ...otherAccountEmails])
      if (e.trim().isNotEmpty) e.trim().toLowerCase(),
  };
  final to = _to(kind, original, mine);
  // The original's own Message-ID, which is what every client threads on,
  // and what it answered before it. A forward starts a conversation of its
  // own. These used to be an id made up from the UID, which matched nothing
  // anywhere, so every reply opened a new thread for the person getting it.
  final answering = original != null && kind != ComposeKind.forward;

  return Draft(
    accountId: accountId,
    kind: kind,
    to: to,
    cc: kind == ComposeKind.replyAll ? _cc(original, mine, to) : const [],
    subject: subjectFor(kind, original),
    htmlBody: html,
    inReplyTo: answering ? original.messageId : null,
    references: [
      if (answering && original.inReplyTo != null) original.inReplyTo!,
    ],
    originalMessageId: original?.id,
  );
}

/// Who a reply goes to.
///
/// Reply-To when the message has one: the ticket address behind a no-reply
/// sender, a list, a web form. The From address only otherwise; answering it
/// regardless sent replies to addresses that drop them. And a message the
/// account sent itself, answered from Sent, goes to the people it went to,
/// not back to the account.
List<MailAddress> _to(
  ComposeKind kind,
  MailMessage? original,
  Set<String> mine,
) {
  if (original == null || kind == ComposeKind.forward) return const [];
  if (mine.contains(original.from.email.toLowerCase())) {
    final others = [
      for (final a in original.to)
        if (!mine.contains(a.email.toLowerCase())) a,
    ];
    return others.isEmpty ? original.to : others;
  }
  if (original.replyTo.isNotEmpty) return original.replyTo;
  return [original.from];
}

/// Reply-all keeps everyone else who had the message, from its To and its
/// Cc, but never the account itself, or the sender ends up on their own
/// reply, never whoever the reply is already addressed to, and never the
/// original sender, who is either that or asked not to be answered. Each
/// address once.
///
/// Only To used to be read, so everyone who had been copied was left off the
/// answer without a word, from the compose screen and from the notification.
List<MailAddress> _cc(
  MailMessage? original,
  Set<String> mine,
  List<MailAddress> to,
) {
  if (original == null) return const [];
  final skip = {
    ...mine,
    original.from.email.toLowerCase(),
    for (final a in to) a.email.toLowerCase(),
  };
  return [
    for (final a in [...original.to, ...original.cc])
      if (skip.add(a.email.toLowerCase())) a,
  ];
}

String subjectFor(ComposeKind kind, MailMessage? original) {
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

/// Plain text as HTML paragraphs, for text that was typed somewhere with no
/// editor in it — the notification shade.
String asParagraphs(String text) {
  final paragraphs = text.replaceAll('\r\n', '\n').trim().split('\n\n');
  return [
    for (final p in paragraphs)
      '<p>${escapeHtml(p).replaceAll('\n', '<br>')}</p>',
  ].join();
}

String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
