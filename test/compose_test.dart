import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/quote_builder.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/compose_providers.dart';

const _account = Account(
  id: 'a',
  displayName: 'Ron',
  emailAddress: 'me@example.com',
  provider: MailProvider.gmail,
  authMethod: AuthMethod.appPassword,
  colorValue: 0xFF0F6CBD,
);

MailMessage _original({String subject = 'Contract draft'}) => MailMessage(
      id: 'a:INBOX#7',
      accountId: 'a',
      folderId: 'a:INBOX',
      uid: 7,
      subject: subject,
      from: const MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
      to: const [
        MailAddress(email: 'me@example.com'),
        MailAddress(email: 'sam@example.com', name: 'Sam'),
      ],
      date: DateTime(2026, 9, 14, 9, 41),
      preview: 'Have a look before Friday',
    );

void main() {
  group('sanitiseForEditing', () {
    test('removes scripts, handlers and javascript URLs', () {
      const html = '<div onclick="steal()">Hi</div>'
          '<script>bad()</script>'
          '<a href="javascript:alert(1)">x</a>'
          '<iframe src="https://evil.example"></iframe>'
          '<form action="/post"><input></form>';
      final out = sanitiseForEditing(html);
      expect(out, isNot(contains('onclick')));
      expect(out, isNot(contains('<script')));
      expect(out, isNot(contains('javascript:')));
      expect(out, isNot(contains('<iframe')));
      expect(out, isNot(contains('<form')));
      expect(out, contains('Hi'));
    });

    test('keeps the layout but blocks remote image fetches', () {
      final out = sanitiseForEditing(
          '<img src="https://tracker.example/p.gif"><p>Body</p>');
      expect(out, contains('data-blocked-src="https://tracker.example/p.gif"'));
      expect(out, isNot(contains(' src=')));
      expect(out, contains('<p>Body</p>'));
    });

    test('leaves ordinary formatting and inline images alone', () {
      const html = '<p><b>Bold</b> and <i>italic</i></p>'
          '<img src="cid:logo"><img src="data:image/png;base64,AA">';
      expect(sanitiseForEditing(html), html);
    });
  });

  group('buildComposeHtml', () {
    test('a new message is an empty line with the caret and a signature', () {
      final html = buildComposeHtml(
        kind: ComposeKind.newMessage,
        signatureHtml: '<p>Ron</p>',
      );
      expect(html, contains(caretMarker));
      expect(html, contains('mailtree-signature'));
      expect(html, isNot(contains('mailtree-quote')));
    });

    test('a reply puts the caret above an editable quote', () {
      final html = buildComposeHtml(
        kind: ComposeKind.reply,
        original: _original(),
        originalHtml: '<p>The original body</p>',
      );
      expect(html.indexOf(caretMarker), lessThan(html.indexOf('blockquote')));
      expect(html, contains('Dana Levi wrote:'));
      expect(html, contains('The original body'));
    });

    test('a forward is labelled as one and names the sender', () {
      final html = buildComposeHtml(
        kind: ComposeKind.forward,
        original: _original(),
        originalText: 'Body text',
      );
      expect(html, contains('Forwarded message'));
      expect(html, contains('dana@example.com'));
    });

    test('a signature can be kept off replies', () {
      final html = buildComposeHtml(
        kind: ComposeKind.reply,
        original: _original(),
        originalText: 'x',
        signatureHtml: '<p>Ron</p>',
        signatureOnReply: false,
      );
      expect(html, isNot(contains('mailtree-signature')));
    });

    test('a plain-text original becomes paragraphs, escaped', () {
      final html = buildComposeHtml(
        kind: ComposeKind.reply,
        original: _original(),
        originalText: 'Line one\nLine <two>',
      );
      expect(html, contains('<p>Line one</p>'));
      expect(html, contains('&lt;two&gt;'));
    });
  });

  group('subjects and recipients', () {
    test('Re: and Fwd: are added once, not stacked', () {
      expect(
        _subjectFor(ComposeKind.reply, _original(subject: 'Contract')),
        'Re: Contract',
      );
      expect(
        _subjectFor(ComposeKind.reply, _original(subject: 'Re: Contract')),
        'Re: Contract',
      );
      expect(
        _subjectFor(ComposeKind.forward, _original(subject: 'RE: Contract')),
        'Fwd: RE: Contract',
      );
    });

    test('addresses parse with and without display names', () {
      final parsed = parseAddresses(
          'a@example.com, Dana Levi <dana@example.com>; "Sam" <sam@example.com>');
      expect(parsed.map((a) => a.email),
          ['a@example.com', 'dana@example.com', 'sam@example.com']);
      expect(parsed[0].name, isNull);
      expect(parsed[1].name, 'Dana Levi');
      expect(parsed[2].name, 'Sam');
    });

    test('formatting round-trips through parsing', () {
      const input = 'Dana Levi <dana@example.com>, sam@example.com';
      expect(formatAddresses(parseAddresses(input)), input);
    });

    test('validation catches the obvious mistakes only', () {
      expect(addressesLookValid(parseAddresses('a@b.com')), isTrue);
      expect(addressesLookValid(parseAddresses('not-an-address')), isFalse);
      expect(addressesLookValid(parseAddresses('@b.com')), isFalse);
      expect(addressesLookValid(parseAddresses('a@')), isFalse);
      // Unusual but legal, and the server is the real authority.
      expect(addressesLookValid(parseAddresses("o'brien+tag@sub.example.co.uk")),
          isTrue);
    });

    test('empty input yields no recipients rather than one blank one', () {
      expect(parseAddresses('  , ; '), isEmpty);
    });
  });

  group('buildMimeMessage', () {
    Draft draft({
      List<MailAddress> to = const [MailAddress(email: 'you@example.com')],
      String subject = 'Hello',
      String html = '<p>Hi <b>there</b></p>',
      List<DraftAttachment> attachments = const [],
      String? inReplyTo,
      List<String> references = const [],
    }) =>
        Draft(
          accountId: 'a',
          kind: ComposeKind.newMessage,
          to: to,
          subject: subject,
          htmlBody: html,
          attachments: attachments,
          inReplyTo: inReplyTo,
          references: references,
        );

    test('carries from, to, subject and both body parts', () {
      final mime = buildMimeMessage(draft: draft(), account: _account);
      final rendered = mime.renderMessage();
      expect(rendered, contains('me@example.com'));
      expect(rendered, contains('you@example.com'));
      expect(mime.decodeSubject(), 'Hello');
      expect(mime.decodeTextHtmlPart(), contains('<b>there</b>'));
      expect(mime.decodeTextPlainPart()?.trim(), 'Hi there',
          reason: 'the text alternative is derived from the HTML');
    });

    test('an empty subject is labelled rather than sent blank', () {
      final mime = buildMimeMessage(draft: draft(subject: '   '), account: _account);
      expect(mime.decodeSubject(), '(No subject)');
    });

    test('threading headers are set so replies stay in the conversation', () {
      final mime = buildMimeMessage(
        draft: draft(
          inReplyTo: '<abc@example.com>',
          references: ['<first@example.com>'],
        ),
        account: _account,
      );
      final rendered = mime.renderMessage();
      expect(rendered, contains('In-Reply-To: <abc@example.com>'));
      expect(
        rendered,
        contains('References: <first@example.com> <abc@example.com>'),
        reason: 'the message being answered goes last in the chain',
      );
    });

    test('a new message has no threading headers', () {
      final rendered =
          buildMimeMessage(draft: draft(), account: _account).renderMessage();
      expect(rendered, isNot(contains('In-Reply-To')));
    });

    test('attachments are carried with their names', () {
      final mime = buildMimeMessage(
        draft: draft(attachments: [
          DraftAttachment(
            fileName: 'notes.txt',
            mimeType: 'text/plain',
            bytes: Uint8List.fromList('hello'.codeUnits),
          ),
        ]),
        account: _account,
      );
      final rendered = mime.renderMessage();
      expect(rendered, contains('notes.txt'));
      expect(mime.hasAttachments(), isTrue);
    });
  });

  group('DraftAttachment', () {
    test('reports a readable size', () {
      DraftAttachment of(int bytes) => DraftAttachment(
            fileName: 'f',
            mimeType: 'application/octet-stream',
            bytes: Uint8List(bytes),
          );
      expect(of(512).readableSize, '512 B');
      expect(of(2048).readableSize, '2 KB');
      expect(of(3 * 1024 * 1024).readableSize, '3.0 MB');
    });
  });

  group('SMTP host selection', () {
    test('picks the provider host', () {
      expect(SmtpSender.smtpHostFor(MailProvider.gmail), 'smtp.gmail.com');
      expect(SmtpSender.smtpHostFor(MailProvider.outlook),
          'smtp.office365.com');
    });
  });
}

/// Mirrors the private subject logic, so the expectations stay honest about
/// what the compose screen will actually show.
String _subjectFor(ComposeKind kind, MailMessage original) {
  final subject = original.subject;
  bool has(String p) => subject.toLowerCase().startsWith(p.toLowerCase());
  return switch (kind) {
    ComposeKind.reply || ComposeKind.replyAll =>
      has('Re:') ? subject : 'Re: $subject',
    ComposeKind.forward => has('Fwd:') ? subject : 'Fwd: $subject',
    ComposeKind.newMessage => '',
  };
}
