import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_credentials.dart';
import 'package:myemail/domain/mail_message.dart';

import 'fakes/fake_imap_transport.dart';

/// What sending does to the message it answers: marks it replied to or
/// forwarded on the server, where every mail app reads it, and in the cache,
/// so the list shows it without waiting for a sync. Through the real engine,
/// over the fake IMAP server; Exchange's side is in graph_transport_test.
void main() {
  late FakeImapTransport server;
  late List<em.MimeMessage> sent;
  late CachedImapEngine engine;

  setUp(() {
    server = FakeImapTransport()
      ..folder('INBOX', role: FolderRole.inbox)
      ..folder('[Gmail]/Sent Mail', role: FolderRole.sent);
    sent = [];
    engine = CachedImapEngine(
      accountStore: MemoryAccountStore(),
      credentialStore: MemoryCredentialStore(),
      cache: MemoryCacheStore(),
      transportFactory: (_, _) => server,
      // Without this the send path opens a real socket with a made-up
      // password. A unit test must not touch the network.
      senderFactory: (_, _) => _Recording(sent),
    );
  });

  /// A Gmail account with three messages in its Inbox, synced, oldest
  /// first: UIDs 1, 2 and 3.
  Future<(Account, List<MailMessage>)> inbox() async {
    for (final subject in ['Numbers', 'Plans', 'Tickets']) {
      server.folder('INBOX').deliver(subject: subject);
    }
    final account = await engine.addAccount(
      displayName: 'Personal',
      emailAddress: 'ron@example.com',
      provider: MailProvider.gmail,
      secret: 'abcdabcdabcdabcd',
    );
    final listed = await engine.loadMessages('${account.id}:INBOX');
    return (account, listed.reversed.toList());
  }

  Draft draft(
    Account account,
    ComposeKind kind, {
    String? original,
    List<DraftAttachment> attachments = const [],
  }) =>
      Draft(
        accountId: account.id,
        kind: kind,
        to: const [MailAddress(email: 'dana@example.com')],
        subject: 'About that',
        htmlBody: '<p>Yes.</p>',
        originalMessageId: original,
        attachments: attachments,
      );

  FakeMessage onServer(int uid) => server.folder('INBOX').messages[uid]!;

  Future<MailMessage> listed(MailMessage m) async =>
      (await engine.cachedMessage(m.id))!;

  test('a reply marks the original answered, on the server and here',
      () async {
    final (account, messages) = await inbox();

    await engine.sendDraft(
        draft(account, ComposeKind.reply, original: messages[0].id));

    expect(sent, hasLength(1));
    expect(server.calls, contains('UID STORE INBOX 1 +MessageFlag.answered'));
    expect(onServer(1).isAnswered, isTrue);
    expect((await listed(messages[0])).isAnswered, isTrue,
        reason: 'in the list before the next sync');
    expect((await listed(messages[1])).isAnswered, isFalse);
  });

  test('a reply to all is a reply', () async {
    final (account, messages) = await inbox();

    await engine.sendDraft(
        draft(account, ComposeKind.replyAll, original: messages[0].id));

    expect(onServer(1).isAnswered, isTrue);
    expect((await listed(messages[0])).isAnswered, isTrue);
  });

  test('a forward marks it forwarded, and a reply before it stays',
      () async {
    // IMAP keeps the two apart, so a message can show both.
    final (account, messages) = await inbox();

    await engine.sendDraft(
        draft(account, ComposeKind.reply, original: messages[0].id));
    await engine.sendDraft(
        draft(account, ComposeKind.forward, original: messages[0].id));

    expect(server.calls, contains('UID STORE INBOX 1 +MessageFlag.forwarded'));
    expect(onServer(1).isForwarded, isTrue);
    final shown = await listed(messages[0]);
    expect(shown.isForwarded, isTrue);
    expect(shown.isAnswered, isTrue);
  });

  test('each message forwarded as an attachment is marked forwarded',
      () async {
    // Forward as attachment starts a new message: nothing in it answers
    // anything, and what went is in its files.
    final (account, messages) = await inbox();
    DraftAttachment eml(MailMessage m) => DraftAttachment(
          fileName: '${m.subject}.eml',
          mimeType: 'message/rfc822',
          bytes: Uint8List.fromList(
            utf8.encode('Subject: ${m.subject}\r\n\r\nHello.'),
          ),
          forwardedMessageId: m.id,
        );

    await engine.sendDraft(draft(
      account,
      ComposeKind.newMessage,
      attachments: [eml(messages[0]), eml(messages[2])],
    ));

    expect([for (final uid in [1, 2, 3]) onServer(uid).isForwarded],
        [true, false, true]);
    expect([for (final m in messages) (await listed(m)).isForwarded],
        [true, false, true]);
    expect(onServer(1).isAnswered, isFalse);
  });

  test('marking it read afterwards keeps the mark', () async {
    // What a reply from a notification does next: answered mail is read
    // mail. Written from a row read before the reply, the mark went.
    final (account, messages) = await inbox();
    await engine.sendDraft(
        draft(account, ComposeKind.reply, original: messages[0].id));

    await engine.setRead(messages[0].id, true);
    await engine.setFlagged(messages[0].id, true);

    final shown = await listed(messages[0]);
    expect(shown.isRead && shown.isFlagged, isTrue);
    expect(shown.isAnswered, isTrue);
  });

  test('a search hit not cached yet says whether it was replied to',
      () async {
    // Search reaches mail the list has never loaded, read straight from
    // the server.
    server.folder('INBOX').deliver(subject: 'Invoice 1').isAnswered = true;
    server.folder('INBOX').deliver(subject: 'Invoice 2').isForwarded = true;
    final account = await engine.addAccount(
      displayName: 'Personal',
      emailAddress: 'ron@example.com',
      provider: MailProvider.gmail,
      secret: 'abcdabcdabcdabcd',
    );

    final hits = await engine.searchMessages(
        'invoice', SearchScope.folder('${account.id}:INBOX'));

    final marks = {
      for (final m in hits) m.subject: (m.isAnswered, m.isForwarded),
    };
    expect(marks, {'Invoice 1': (true, false), 'Invoice 2': (false, true)});
  });

  test('a mark that fails leaves the message sent, and says why in the log',
      () async {
    // The original went from the server between opening it and sending, or
    // the connection dropped straight after the send. Either way the reply
    // is away, and reported as failed it would be sent again.
    final (account, _) = await inbox();
    final logged = <String>[];
    final wasPrinting = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => logged.add('$message');
    addTearDown(() => debugPrint = wasPrinting);
    final gone = '${account.id}:Gone#4';

    await engine.sendDraft(draft(account, ComposeKind.reply, original: gone));

    expect(sent, hasLength(1));
    expect(logged,
        contains(startsWith('[myemail] could not mark $gone answered')));
  });
}

/// Keeps every message handed to it, and sends nothing.
class _Recording extends SmtpSender {
  _Recording(this.sent)
      : super(
          host: 'smtp.example',
          user: '',
          credentials: const PasswordCredentials(''),
        );

  final List<em.MimeMessage> sent;

  @override
  Future<void> send(em.MimeMessage message) async => sent.add(message);
}
