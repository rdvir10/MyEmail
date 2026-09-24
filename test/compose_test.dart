import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/compose/quote_builder.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/address_suggestions.dart';
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

    // The ways a handler got past the old patterns: no whitespace before it,
    // which the browser accepts. Each one ran script in the editor, which
    // could post 'send' to the bridge.
    for (final attack in [
      '<img src="x"onerror="MyEmail.postMessage(1)">',
      '<img/onerror=alert(1) src=x>',
      '<svg/onload=alert(1)>',
      '<img src=x ONERROR=alert(1)>',
      '<body onload=alert(1)><p>Hi</p>',
      '<details open ontoggle=alert(1)><summary>x</summary></details>',
    ]) {
      test('no handler survives: $attack', () {
        final out = sanitiseForEditing(attack).toLowerCase();
        expect(out, isNot(matches(RegExp(r'\son[a-z]+\s*='))));
        expect(out, isNot(contains('alert')));
        expect(out, isNot(contains('postmessage')));
      });
    }

    test('removes the tags that act on the page: meta, base, link', () {
      final out = sanitiseForEditing(
        '<meta http-equiv="refresh" content="0;url=data:text/html,x">'
        '<base href="https://evil.example/">'
        '<link rel="stylesheet" href="https://t.example/s.css">'
        '<p>Body</p>',
      );
      expect(out, isNot(contains('<meta')));
      expect(out, isNot(contains('<base')));
      expect(out, isNot(contains('<link')));
      expect(out, contains('<p>Body</p>'));
    });

    test('a link keeps only a web, mail or phone target', () {
      final out = sanitiseForEditing(
        '<a href="data:text/html,<script>x()</script>">a</a>'
        '<a href="java\tscript:x()">b</a>'
        '<a href="  JAVASCRIPT:x()">c</a>'
        '<a href="https://example.com/">d</a>'
        '<a href="mailto:dana@example.com">e</a>',
      );
      expect(out, isNot(contains('data:')));
      expect(out.toLowerCase(), isNot(contains('script:')));
      expect(out, contains('href="https://example.com/"'));
      expect(out, contains('href="mailto:dana@example.com"'));
    });

    test('comments go, and with them anything hidden inside', () {
      final out = sanitiseForEditing('<p>a</p><!--\n.\n.\nRSET\n--><p>b</p>');
      expect(out, '<p>a</p><p>b</p>');
    });

    test('inline styles keep their look but fetch nothing', () {
      final out = sanitiseForEditing(
          '<div style="color:red;background:url(https://t.example/x)">a</div>');
      expect(out, contains('color:red'));
      expect(out, isNot(contains('t.example')));
    });

    test('a srcset with a remote entry after an inline one fetches nothing',
        () {
      // Only the first entry used to be looked at, and phones pick 2x.
      final out = sanitiseForEditing(
          '<img srcset="data:image/png;base64,AA 1x, https://t.example/p.png 2x">');
      expect(out, isNot(matches(RegExp(r'(?<!-)srcset='))));
    });

    test('an unknown tag loses the tag but keeps its words', () {
      expect(sanitiseForEditing('<p>One<o:p>two</o:p></p>'), '<p>Onetwo</p>');
    });

    test('a style sheet stays, less what it would fetch', () {
      // Most HTML mail is laid out by one; dropping it forwarded a booking
      // or a newsletter as an unstyled heap.
      final out = sanitiseForEditing(
        '<html><head><style>@import "https://t.example/x.css";'
        '.hero{background:url(https://t.example/b.png);color:#123}</style>'
        '</head><body><p class="hero">Hi</p></body></html>',
      );
      expect(out, contains('<style>'));
      expect(out, contains('color:#123'));
      expect(out, isNot(contains('t.example')));
      expect(out, contains('<p class="hero">Hi</p>'));
    });

    test('nothing taken out of a style sheet can end it early', () {
      // The sheet's text is written out as it is. Removing the import from
      // "<@import a;/style>" would otherwise leave a closing tag, and the
      // script after it would be markup.
      final out =
          sanitiseForEditing('<style><@import a;/style><script>x()</style>');
      expect(RegExp('</style').allMatches(out), hasLength(1));
      expect(out, isNot(contains('<script')));
    });

    test('a reopened draft keeps its own remote pictures, and nothing else',
        () {
      final out = sanitiseForEditing(
        '<img src="https://example.com/logo.png">'
        '<img src="x"onerror="alert(1)">',
        ownDraft: true,
      );
      expect(out, contains('src="https://example.com/logo.png"'));
      expect(out, isNot(contains('onerror')));
    });
  });

  group('wireText', () {
    Draft draft({
      List<MailAddress> cc = const [],
      List<MailAddress> bcc = const [],
      String html = '<p>Hello</p>',
    }) =>
        Draft(
          accountId: 'a',
          kind: ComposeKind.newMessage,
          to: const [MailAddress(email: 'alice@example.com')],
          cc: cc,
          bcc: bcc,
          subject: 'Plans',
          htmlBody: html,
        );

    const secrets = [
      MailAddress(email: 'secret.one@example.com', name: 'Secret One'),
      MailAddress(email: 'secret.two@example.com', name: 'Secret Two'),
      MailAddress(email: 'secret.three@example.com'),
      MailAddress(email: 'secret.four@example.com'),
    ];

    test('no Bcc address appears anywhere, however long the list', () {
      final message = buildMimeMessage(
        draft: draft(
          cc: const [MailAddress(email: 'carol@example.com')],
          bcc: secrets,
        ),
        account: _account,
      );
      final text = wireText(message);
      for (final s in secrets) {
        expect(text, isNot(contains(s.email)), reason: s.email);
      }
      expect(text, contains('carol@example.com'));
    });

    test('without a Cc the blind copies do not join To either', () {
      final message =
          buildMimeMessage(draft: draft(bcc: secrets), account: _account);
      final text = wireText(message);
      for (final s in secrets) {
        expect(text, isNot(contains(s.email)), reason: s.email);
      }
    });

    test('but every Bcc recipient is in the envelope', () {
      final message = buildMimeMessage(
        draft: draft(
          cc: const [MailAddress(email: 'carol@example.com')],
          bcc: secrets,
        ),
        account: _account,
      );
      expect(
        envelopeRecipients(message).map((a) => a.email),
        containsAll([
          'alice@example.com',
          'carol@example.com',
          for (final s in secrets) s.email,
        ]),
      );
    });

    test('no line of the message can end it early', () {
      final message = buildMimeMessage(
        draft: draft(html: '<p>a</p>\n.\n.\nRSET\nMAIL FROM:<x@y>\n<p>b</p>'),
        account: _account,
      );
      final lines = wireText(message).split('\r\n');
      expect(lines, isNot(contains('.')));
    });

    test('a line starting with a dot keeps it', () {
      final message = buildMimeMessage(
        draft: draft(html: '<p>x</p>\n...and then\n.net is fine'),
        account: _account,
      );
      final lines = wireText(message).split('\r\n');
      // Doubled on the wire; the server takes one off again.
      expect(lines, contains('....and then'));
      expect(lines, contains('..net is fine'));
      for (final line in lines) {
        if (line.startsWith('.')) expect(line, startsWith('..'), reason: line);
      }
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

    test('a name with a comma in it is one person, not two', () {
      // Outlook directories name people "Surname, Given". Reply-all to one
      // of them split the name at its comma, and the send was refused
      // because "Levi" did not look like an address.
      const levi = MailAddress(email: 'dana@example.com', name: 'Levi, Dana');
      const sam = MailAddress(email: 'sam@example.com', name: 'Sam "Q" Cohen');
      final field = formatAddresses([levi, sam]);

      expect(field,
          r'"Levi, Dana" <dana@example.com>, "Sam \"Q\" Cohen" <sam@example.com>');
      final parsed = parseAddresses(field);
      expect(parsed.map((a) => (a.name, a.email)), [
        ('Levi, Dana', 'dana@example.com'),
        ('Sam "Q" Cohen', 'sam@example.com'),
      ]);
      expect(addressesLookValid(parsed), isTrue);
    });

    test('a suggestion chosen for such a name goes in quoted', () {
      const chosen =
          AddressSuggestion(email: 'dana@example.com', name: 'Levi, Dana');
      final field = completeLastRecipient('sam@example.com, lev', chosen);

      expect(field, 'sam@example.com, "Levi, Dana" <dana@example.com>, ');
      expect(parseAddresses(field).map((a) => a.email),
          ['sam@example.com', 'dana@example.com']);
      expect(lastRecipientToken('sam@example.com, "Levi, Da'), 'Levi, Da',
          reason: 'still typing inside the quotes');
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

    test('a forwarded picture reaches the recipient', () {
      // Blocked while the reply was written, so writing it told the sender
      // nothing; the recipient used to get an empty box instead.
      final html = buildComposeHtml(
        kind: ComposeKind.forward,
        original: _original(),
        originalHtml: '<img src="https://cdn.example/hero.png" '
            'srcset="https://cdn.example/hero2.png 2x"><p>Booking</p>',
      );
      expect(html, contains('data-blocked-src'), reason: 'blocked in the editor');

      // Collapsed, because the encoder folds long lines at their spaces.
      final sent = buildMimeMessage(draft: draft(html: html), account: _account)
          .decodeTextHtmlPart()!
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(sent, contains('src="https://cdn.example/hero.png"'));
      expect(sent, contains('srcset="https://cdn.example/hero2.png 2x"'));
      expect(sent, isNot(contains('data-blocked-')));
    });

    test('only a remote address comes back as a source', () {
      // data-blocked-src is on the sanitiser's allow-list, so a message can
      // carry its own; turning that into a source must not let anything in.
      final out = restoreBlockedImages(
        '<img data-blocked-src="javascript:alert(1)">'
        '<img data-blocked-src="cid:x">'
        '<img data-blocked-src="//cdn.example/a.png">',
      );
      expect(out, isNot(contains('javascript')));
      expect(out, isNot(contains('cid:')));
      expect(out, contains('src="//cdn.example/a.png"'));
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

    group('file names', () {
      DraftAttachment file(String name) => DraftAttachment(
            fileName: name,
            mimeType: 'application/pdf',
            bytes: Uint8List.fromList([1, 2, 3]),
          );

      /// What a reader makes of the name, from the message as it went out.
      String? nameReadBack(String rendered) => em.MimeMessage.parseFromText(
            rendered,
          ).allPartsFlat.map((p) => p.decodeFileName()).nonNulls.single;

      test('a Hebrew name goes out encoded, and reads back whole', () {
        // Raw UTF-8 in a header, in a 7-bit session, which strict and older
        // clients show as rubbish.
        const name = 'חשבונית מס 2026.pdf';
        final rendered = buildMimeMessage(
          draft: draft(attachments: [file(name)]),
          account: _account,
        ).renderMessage();

        expect(rendered.runes.every((c) => c < 128), isTrue,
            reason: 'every header is 7-bit');
        expect(rendered, contains(RegExp(r"filename\*(0\*)?=UTF-8''")),
            reason: 'RFC 2231, which is what readers look for first');
        expect(nameReadBack(rendered), name);
      });

      test('a name with quotes in it is not cut short', () {
        const name = 'The "final" plan.pdf';
        final rendered = buildMimeMessage(
          draft: draft(attachments: [file(name)]),
          account: _account,
        ).renderMessage();

        expect(rendered, isNot(contains('"The "final')));
        expect(nameReadBack(rendered), name);
      });

      test('a long name is split, so no line runs past the limit', () {
        final name = '${'דוח רבעוני מפורט של המחלקה ' * 4}.pdf';
        final rendered = buildMimeMessage(
          draft: draft(attachments: [file(name)]),
          account: _account,
        ).renderMessage();

        for (final line in rendered.split('\r\n')) {
          expect(line.length, lessThanOrEqualTo(78), reason: line);
        }
        expect(nameReadBack(rendered), name);
      });

      test('a plain name stays as it is', () {
        final rendered = buildMimeMessage(
          draft: draft(attachments: [file('Q3 report.pdf')]),
          account: _account,
        ).renderMessage();

        expect(rendered, contains('filename="Q3 report.pdf"'));
      });
    });

    test('a multipart carries no transfer encoding of its own', () {
      // RFC 2045 allows a multipart only 7bit, 8bit or binary. enough_mail
      // put base64 on the top of every message.
      final rendered = buildMimeMessage(
        draft: draft(attachments: [
          DraftAttachment(
            fileName: 'a.pdf',
            mimeType: 'application/pdf',
            bytes: Uint8List.fromList([1]),
          ),
        ]),
        account: _account,
      ).renderMessage();
      final head = rendered.substring(0, rendered.indexOf('\r\n\r\n'));

      expect(head, contains('multipart/mixed'));
      expect(head.toLowerCase(), isNot(contains('content-transfer-encoding')));
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
