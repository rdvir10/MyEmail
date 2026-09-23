import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_credentials.dart';

import 'fakes/fake_imap_transport.dart';

/// Answering an invitation on an account with no calendar of its own
/// (Gmail): the answer goes to the organiser as mail. The route every Gmail
/// Accept, Tentative and Decline takes, run through the real engine.
void main() {
  late FakeImapTransport server;
  late List<em.MimeMessage> sent;
  late CachedImapEngine engine;

  setUp(() {
    server = FakeImapTransport()
      ..folder('INBOX', role: FolderRole.inbox).deliver(subject: 'Lunch')
      ..folder('[Gmail]/Sent Mail', role: FolderRole.sent);
    sent = [];
    engine = CachedImapEngine(
      accountStore: MemoryAccountStore(),
      credentialStore: MemoryCredentialStore(),
      cache: MemoryCacheStore(),
      transportFactory: (_, _) => server,
      senderFactory: (_, _) => _Recording(sent),
    );
  });

  CalendarInvite invite({String organiser = 'ORGANIZER:mailto:dana@example.com\n'}) =>
      CalendarInvite.parse(
        'BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:abc\n'
        'SUMMARY:Lunch\nDTSTART:20260921T120000Z\n$organiser'
        'END:VEVENT\nEND:VCALENDAR',
      )!;

  Future<Account> personal() async {
    // Named "Personal" in the folder list, sending as Ron Dvir.
    final added = await engine.addAccount(
      displayName: 'Personal',
      emailAddress: 'ron@example.com',
      provider: MailProvider.gmail,
      secret: 'abcdabcdabcdabcd',
    );
    return engine.updateAccount(accountId: added.id, senderName: 'Ron Dvir');
  }

  test('goes to the organiser, as a calendar reply, in your name', () async {
    final account = await personal();

    await engine.respondToInvite(
      '${account.id}:INBOX#1',
      invite(),
      InviteResponse.accepted,
    );

    final message = sent.single;
    expect(message.to!.single.email, 'dana@example.com');
    final rendered = message.renderMessage();
    expect(rendered.toLowerCase(), contains('text/calendar'));
    expect(rendered.toLowerCase(), contains('method=reply'));
    expect(rendered, contains('PARTSTAT=ACCEPTED'));
    // The folder-list label is not a name to sign an answer with.
    expect(message.decodeTextHtmlPart(), contains('Ron Dvir has accepted'));
    expect(message.decodeTextHtmlPart(), isNot(contains('Personal')));
  });

  test('one occurrence of a series is not looked up by the series UID',
      () async {
    // On Microsoft the UID finds the calendar's event for the whole series,
    // and answering that declined every occurrence.
    final account = await personal();
    final occurrence = CalendarInvite.parse(
      'BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:series\n'
      'RECURRENCE-ID:20260929T170000Z\nSUMMARY:Weekly\n'
      'DTSTART:20260929T170000Z\nORGANIZER:mailto:dana@example.com\n'
      'END:VEVENT\nEND:VCALENDAR',
    )!;

    await engine.respondToInvite(
        '${account.id}:INBOX#1', occurrence, InviteResponse.declined);
    await engine.respondToInvite(
        '${account.id}:INBOX#1', invite(), InviteResponse.declined);

    final asked = server.calls.where((c) => c.startsWith('RESPOND')).toList();
    expect(asked.first, isNot(contains('uid=')));
    expect(asked.last, contains('uid=abc'), reason: 'a single event still is');
    expect(sent.first.renderMessage(),
        contains('RECURRENCE-ID:20260929T170000Z'));
  });

  test('an invitation that names no organiser says so and sends nothing',
      () async {
    final account = await personal();

    await expectLater(
      engine.respondToInvite(
        '${account.id}:INBOX#1',
        invite(organiser: ''),
        InviteResponse.declined,
      ),
      throwsA(isA<SendFailed>()),
    );
    expect(sent, isEmpty);
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
