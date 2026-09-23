import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/mime_parts.dart';
import 'package:myemail/data/compose/reply_draft.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/window_handoff.dart';

/// Who a reply goes to, what a forward carries, and what a reopened draft
/// brings back: the three places mail went out with less than it should.
void main() {
  const me = MailAddress(email: 'ron@example.com');
  const alias = MailAddress(email: 'ron@work.example');
  const dana = MailAddress(email: 'dana@example.com', name: 'Dana');
  const nadav = MailAddress(email: 'nadav@example.com');
  const michal = MailAddress(email: 'michal@example.com', name: 'Michal');
  const nik = MailAddress(email: 'nik@example.com');

  MailMessage original({
    List<MailAddress> to = const [me, nadav],
    List<MailAddress> cc = const [michal, nik],
  }) =>
      MailMessage(
        id: 'a:INBOX#7',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 7,
        subject: 'Budget',
        from: dana,
        to: to,
        cc: cc,
        date: DateTime(2026, 9, 20, 9),
        preview: '',
      );

  group('reply all', () {
    Draft replyAll(MailMessage m) => draftFor(
          kind: ComposeKind.replyAll,
          accountId: 'a',
          original: m,
          selfEmail: me.email,
          otherAccountEmails: [alias.email],
        );

    test('keeps everyone who was copied, not only To', () {
      final draft = replyAll(original());
      expect(draft.to.map((a) => a.email), [dana.email]);
      expect(draft.cc.map((a) => a.email),
          [nadav.email, michal.email, nik.email]);
    });

    test('never the account itself, under any of its addresses', () {
      final draft = replyAll(original(cc: const [michal, alias]));
      final emails = draft.cc.map((a) => a.email.toLowerCase());
      expect(emails, isNot(contains(me.email)));
      expect(emails, isNot(contains(alias.email)));
    });

    test('never the sender twice, and each address once', () {
      final draft = replyAll(original(
        to: const [me, dana, nadav],
        cc: const [MailAddress(email: 'NADAV@example.com'), michal],
      ));
      expect(draft.cc.map((a) => a.email.toLowerCase()),
          [nadav.email, michal.email]);
    });

    test('a plain reply still goes to the sender alone', () {
      final draft = draftFor(
        kind: ComposeKind.reply,
        accountId: 'a',
        original: original(),
        selfEmail: me.email,
      );
      expect(draft.to.map((a) => a.email), [dana.email]);
      expect(draft.cc, isEmpty);
    });
  });

  group('who a reply goes to', () {
    const noreply = MailAddress(email: 'noreply@vendor.example');
    const ticket =
        MailAddress(email: 'ticket-4411@vendor.example', name: 'Support');

    MailMessage from(MailAddress sender, {List<MailAddress> replyTo = const []}) =>
        MailMessage(
          id: 'a:INBOX#8',
          accountId: 'a',
          folderId: 'a:INBOX',
          uid: 8,
          subject: 'Your ticket',
          from: sender,
          to: const [me, nadav],
          cc: const [michal],
          replyTo: replyTo,
          date: DateTime(2026, 9, 20, 9),
          preview: '',
        );

    Draft reply(MailMessage m, {ComposeKind kind = ComposeKind.reply}) =>
        draftFor(kind: kind, accountId: 'a', original: m, selfEmail: me.email);

    test('the Reply-To address, when the message names one', () {
      // A support desk sends from noreply@ and asks for answers at the
      // ticket address. Answering From sent them where nobody reads.
      final draft = reply(from(noreply, replyTo: const [ticket]));
      expect(draft.to, [ticket]);
    });

    test('and reply all neither drops the others nor adds the no-reply', () {
      final draft =
          reply(from(noreply, replyTo: const [ticket]), kind: ComposeKind.replyAll);
      expect(draft.to, [ticket]);
      expect(draft.cc.map((a) => a.email), [nadav.email, michal.email]);
    });

    test('a message the account sent goes to the people it went to', () {
      // Answering from Sent used to address the reply to the account.
      final draft = reply(from(me));
      expect(draft.to.map((a) => a.email), [nadav.email]);
    });

    test('a Reply-To that only repeats the sender is no Reply-To', () {
      // An IMAP server's ENVELOPE fills Reply-To in with From when the
      // header is absent.
      expect(replyToBesidesSender(const [dana], dana), isEmpty);
      expect(replyToBesidesSender(const [ticket], noreply), [ticket]);
    });
  });

  group('the thread a reply joins', () {
    MailMessage threaded({String? messageId, String? inReplyTo}) => MailMessage(
          id: 'a:INBOX#7',
          accountId: 'a',
          folderId: 'a:INBOX',
          uid: 7,
          subject: 'Budget',
          from: dana,
          to: const [me],
          date: DateTime(2026, 9, 20, 9),
          preview: '',
          messageId: messageId,
          inReplyTo: inReplyTo,
        );

    String sent(Draft draft) => buildMimeMessage(
          draft: draft,
          account: const Account(
            id: 'a',
            displayName: 'Ron',
            emailAddress: 'ron@example.com',
            provider: MailProvider.gmail,
            authMethod: AuthMethod.appPassword,
            colorValue: 0xFF0F6CBD,
          ),
        ).renderMessage();

    test("answers the original's own Message-ID", () {
      // It used to be an id made up from the UID, which matched nothing, so
      // every reply opened a new conversation for the person getting it.
      final draft = draftFor(
        kind: ComposeKind.reply,
        accountId: 'a',
        original: threaded(messageId: 'real@x', inReplyTo: 'first@x'),
      );
      expect(draft.inReplyTo, 'real@x');

      final rendered = sent(draft);
      expect(rendered, contains('In-Reply-To: <real@x>'));
      expect(rendered, contains('References: <first@x> <real@x>'));
      expect(rendered, isNot(contains('mailtree.local')));
    });

    test('an id written with its brackets is not given a second pair', () {
      // Microsoft hands the id over with them; the cache strips them.
      final draft = draftFor(
        kind: ComposeKind.reply,
        accountId: 'a',
        original: threaded(messageId: '<real@x>'),
      );
      expect(sent(draft), contains('In-Reply-To: <real@x>'));
    });

    test('nothing is claimed when the original had no Message-ID', () {
      final draft = draftFor(
        kind: ComposeKind.reply,
        accountId: 'a',
        original: threaded(),
      );
      expect(draft.inReplyTo, isNull);
      expect(sent(draft), isNot(contains('In-Reply-To')));
    });

    test('a forward starts a conversation of its own', () {
      final draft = draftFor(
        kind: ComposeKind.forward,
        accountId: 'a',
        original: threaded(messageId: 'real@x'),
      );
      expect(draft.inReplyTo, isNull);
      expect(draft.references, isEmpty);
    });
  });

  group('a message changes state without losing its Cc', () {
    test('marking read keeps Cc, size and the meeting flag', () {
      final m = MailMessage(
        id: 'a:INBOX#7',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 7,
        subject: 'Budget',
        from: dana,
        to: const [me],
        cc: const [michal],
        date: DateTime(2026, 9, 20, 9),
        preview: '',
        attachmentBytes: 1234,
        isMeeting: true,
      );
      final read = m.copyWith(isRead: true);
      expect(read.cc, [michal]);
      expect(read.attachmentBytes, 1234);
      expect(read.isMeeting, isTrue);
    });

    test('and so does opening it in a window of its own', () {
      final m = original();
      final back =
          WindowRequest.decode(MessageWindow(m).encode()) as MessageWindow;
      expect(back.message.cc.map((a) => a.email),
          [michal.email, nik.email]);
    });

    test('Reply-To survives both as well', () {
      final m = MailMessage(
        id: 'a:INBOX#7',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 7,
        subject: 'Budget',
        from: dana,
        to: const [me],
        replyTo: const [nik],
        date: DateTime(2026, 9, 20, 9),
        preview: '',
      );
      expect(m.copyWith(isRead: true).replyTo, [nik]);
      final back =
          WindowRequest.decode(MessageWindow(m).encode()) as MessageWindow;
      expect(back.message.replyTo, [nik]);
    });
  });

  group('what a message carries, read from its MIME', () {
    const account = Account(
      id: 'a',
      displayName: 'Ron',
      emailAddress: 'ron@example.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF0F6CBD,
    );
    final pdf = Uint8List.fromList(List.generate(300, (i) => i % 256));
    final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2]);

    String mimeOf(Draft draft) =>
        buildMimeMessage(draft: draft, account: account).renderMessage();

    final withFiles = Draft(
      accountId: 'a',
      kind: ComposeKind.newMessage,
      to: const [dana],
      subject: 'Invoice',
      htmlBody: '<p>See attached</p><img src="cid:logo@example.com">',
      attachments: [
        DraftAttachment(
            fileName: 'invoice.pdf', mimeType: 'application/pdf', bytes: pdf),
        DraftAttachment(
          fileName: 'logo.png',
          mimeType: 'image/png',
          bytes: png,
          contentId: 'logo@example.com',
        ),
      ],
    );

    test('every file comes back, bytes and all, and the text does not', () {
      final found = attachmentsInMime(mimeOf(withFiles));
      expect(found.map((a) => a.fileName), ['invoice.pdf', 'logo.png']);
      expect(found.first.bytes, pdf);
      expect(found.last.bytes, png);
    });

    test('a picture the HTML shows keeps its Content-ID; a file does not', () {
      final found = attachmentsInMime(mimeOf(withFiles));
      expect(found.first.contentId, isNull);
      expect(found.last.contentId, 'logo@example.com');
    });

    test('and is sent inline under it, so the cid: link still works', () {
      final text = mimeOf(withFiles);
      expect(text, contains('Content-ID: <logo@example.com>'));
      expect(text.toLowerCase(), contains('content-disposition: inline'));
    });

    test('a saved draft gives back its Bcc and the thread it answers', () {
      final saved = Draft(
        accountId: 'a',
        kind: ComposeKind.reply,
        to: const [dana],
        bcc: const [nik, michal],
        subject: 'Re: Budget',
        htmlBody: '<p>Yes</p>',
        inReplyTo: '<b@example.com>',
        references: const ['<a@example.com>'],
      );
      final headers = savedDraftHeaders(mimeOf(saved));
      expect(headers.bcc.map((a) => a.email), [nik.email, michal.email]);
      expect(headers.inReplyTo, '<b@example.com>');
      // In-Reply-To is appended again on the next save, so it is not kept
      // in References as well.
      expect(headers.references, ['<a@example.com>']);
    });

    test('a message with no files gives none', () {
      final plain = Draft(
        accountId: 'a',
        kind: ComposeKind.newMessage,
        to: const [dana],
        subject: 'Hi',
        htmlBody: '<p>Hello</p>',
      );
      expect(attachmentsInMime(mimeOf(plain)), isEmpty);
    });
  });
}
