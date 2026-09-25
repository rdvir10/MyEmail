import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';

em.Mailbox _box(
  String path, {
  List<em.MailboxFlag> flags = const [],
  String sep = '/',
  int exists = 0,
  int unseen = 0,
}) {
  return em.Mailbox(
    encodedName: path.split(sep).last,
    encodedPath: path,
    flags: flags,
    pathSeparator: sep,
    messagesExists: exists,
    messagesUnseen: unseen,
  );
}

void main() {
  group('paths', () {
    test('server delimiters become slashes and back', () {
      expect(toModelPath('Work.Invoices.2026', '.'), 'Work/Invoices/2026');
      expect(toServerPath('Work/Invoices/2026', '.'), 'Work.Invoices.2026');
      expect(toModelPath('Work/Invoices', '/'), 'Work/Invoices');
    });
  });

  group('roles', () {
    test('special-use flags map to roles', () {
      expect(roleForMailbox(_box('INBOX', flags: [em.MailboxFlag.inbox])),
          FolderRole.inbox);
      expect(
          roleForMailbox(
              _box('[Gmail]/Sent Mail', flags: [em.MailboxFlag.sent])),
          FolderRole.sent);
      expect(roleForMailbox(_box('[Gmail]/Trash', flags: [em.MailboxFlag.trash])),
          FolderRole.deleted);
      expect(roleForMailbox(_box('[Gmail]/Spam', flags: [em.MailboxFlag.junk])),
          FolderRole.junk);
      expect(
          roleForMailbox(_box('[Gmail]/All Mail', flags: [em.MailboxFlag.all])),
          FolderRole.archive);
      expect(roleForMailbox(_box('Work')), FolderRole.user);
    });
  });

  // What the app runs: the transport maps each mailbox with
  // remoteFolderFromMailbox and the engine places it with folderFromRemote.
  // These tests used to go through folderFromMailbox, a copy nothing called.
  group('folders', () {
    final selectable = {
      'INBOX',
      '[Gmail]/Sent Mail',
      '[Gmail]/Starred',
      'Work',
      'Work/Invoices',
      'Orphan/Child',
    };

    MailFolder folder(em.Mailbox box, {Set<String>? paths}) => folderFromRemote(
          accountId: 'a',
          provider: MailProvider.gmail,
          remote: remoteFolderFromMailbox(box),
          allPaths: paths ?? selectable,
        );

    test('the [Gmail] container is not a folder', () {
      final container = _box('[Gmail]',
          flags: [em.MailboxFlag.noSelect, em.MailboxFlag.hasChildren]);
      final inbox = _box('INBOX', flags: [em.MailboxFlag.inbox]);
      expect(selectableMailboxes([container, inbox]), [inbox]);
    });

    test('system folders are flattened to the root with counts', () {
      final f = folder(_box('[Gmail]/Sent Mail',
          flags: [em.MailboxFlag.sent], exists: 120, unseen: 0));
      expect(f.id, 'a:[Gmail]/Sent Mail');
      expect(f.role, FolderRole.sent);
      expect(f.parentId, isNull, reason: 'not nested under [Gmail]');
      expect(f.displayName, 'Sent');
      expect(f.totalCount, 120);
      expect(f.capabilities.canRename, isFalse);
    });

    test('user folders keep their nesting when the parent is real', () {
      final f = folder(_box('Work/Invoices', exists: 5, unseen: 2));
      expect(f.parentId, 'a:Work');
      expect(f.name, 'Invoices');
      expect(f.unreadCount, 2);
      expect(f.totalCount, 5);
      expect(f.capabilities.canRename, isTrue);
    });

    test('a child whose parent is not selectable sits at the root', () {
      expect(folder(_box('Orphan/Child')).parentId, isNull);
    });

    test('Gmail Starred is browsable and droppable but locked', () {
      final f = folder(_box('[Gmail]/Starred', flags: [em.MailboxFlag.flagged]));
      expect(f.role, FolderRole.user);
      expect(f.capabilities.canRename, isFalse);
      expect(f.capabilities.canDelete, isFalse);
      expect(f.capabilities.canAcceptMessages, isTrue);
    });

    test('a dotted delimiter yields slash paths', () {
      final f = folder(
        _box('Work.Invoices', sep: '.'),
        paths: {'Work', 'Work/Invoices'},
      );
      expect(f.path, 'Work/Invoices');
      expect(f.parentId, 'a:Work');
    });
  });

  // remoteHeaderFromMime is what every Gmail list row comes from. The tests
  // went through messageFromMime, a copy nothing called.
  group('remoteHeaderFromMime', () {
    em.MimeMessage build() {
      final builder = em.MessageBuilder.prepareMultipartAlternativeMessage(
        plainText: 'Hello there.\n\nSecond paragraph.',
        htmlText: '<p>Hello <b>there</b>.</p><p>Second paragraph.</p>',
      )
        ..from = [em.MailAddress('Dana Levi', 'dana@example.com')]
        ..to = [em.MailAddress(null, 'me@example.com')]
        ..cc = [em.MailAddress('Omer', 'omer@example.com')]
        ..subject = 'Invoice ready';
      return builder.buildMimeMessage()
        ..uid = 42
        ..flags = [em.MessageFlags.seen, em.MessageFlags.flagged];
    }

    test('headers and flags come through', () {
      final h = remoteHeaderFromMime(build(), fallbackDate: DateTime(2026, 9, 14));
      expect(h.uid, 42);
      expect(h.subject, 'Invoice ready');
      expect(h.from.email, 'dana@example.com');
      expect(h.from.name, 'Dana Levi');
      expect(h.to.single.email, 'me@example.com');
      expect(h.cc.single.email, 'omer@example.com');
      expect(h.cc.single.name, 'Omer');
      expect(h.isRead, isTrue);
      expect(h.isFlagged, isTrue);
      expect(h.hasAttachments, isFalse);
      expect(h.preview, isEmpty, reason: 'IMAP has none to send');
    });

    test('read and flagged are each their own flag', () {
      final mime = build()..flags = [em.MessageFlags.flagged];
      final h = remoteHeaderFromMime(mime);
      expect(h.isRead, isFalse);
      expect(h.isFlagged, isTrue);
    });

    test('so are replied to and forwarded', () {
      // \Answered is IMAP's own flag; $Forwarded is the keyword every mail
      // app that marks a forward uses, and a message can carry both.
      final answered =
          remoteHeaderFromMime(build()..flags = [em.MessageFlags.answered]);
      expect(answered.isAnswered, isTrue);
      expect(answered.isForwarded, isFalse);

      final forwarded = remoteHeaderFromMime(
          build()..flags = [em.MessageFlags.seen, r'$Forwarded']);
      expect(forwarded.isAnswered, isFalse);
      expect(forwarded.isForwarded, isTrue);

      final both = remoteHeaderFromMime(build()
        ..flags = [em.MessageFlags.answered, em.MessageFlags.keywordForwarded]);
      expect(both.isAnswered, isTrue);
      expect(both.isForwarded, isTrue);

      expect(remoteHeaderFromMime(build()).isAnswered, isFalse);
      expect(remoteHeaderFromMime(build()).isForwarded, isFalse);
    });

    test('a forward is read whatever case its keyword comes back in', () {
      // A keyword is written by whichever app did the forwarding, and a
      // server need not hand it back in the case it was set in.
      final h = remoteHeaderFromMime(build()..flags = [r'$FORWARDED']);
      expect(h.isForwarded, isTrue);
    });

    test("the ENVELOPE's Message-ID and In-Reply-To, without brackets", () {
      final mime = build()
        ..envelope = em.Envelope(
          from: [em.MailAddress('Dana Levi', 'dana@example.com')],
          messageId: '<m-1@example.com>',
          inReplyTo: '<m-0@example.com>',
        );
      final h = remoteHeaderFromMime(mime);
      expect(h.messageId, 'm-1@example.com');
      expect(h.inReplyTo, 'm-0@example.com');
    });

    test('Reply-To comes through when it names someone else', () {
      final mime = build()
        ..setHeader('reply-to', 'Support <ticket-4411@vendor.example>');
      final h = remoteHeaderFromMime(mime);

      expect(h.replyTo.single.email, 'ticket-4411@vendor.example');
      expect(h.replyTo.single.name, 'Support');
    });

    test("an ENVELOPE's Reply-To that repeats From is no Reply-To", () {
      // Servers fill the envelope's Reply-To in with From when the header
      // is absent.
      final mime = build()
        ..envelope = em.Envelope(
          from: [em.MailAddress('Dana Levi', 'dana@example.com')],
          replyTo: [em.MailAddress('Dana Levi', 'dana@example.com')],
        );
      expect(remoteHeaderFromMime(mime).replyTo, isEmpty);
    });

    test('with no Date header, the time the server took it in', () {
      // Not the time of the sync, which sorted an old message as new and
      // moved its date at every refill of the cache.
      final mime = build()
        ..removeHeader('date')
        ..internalDate = '25-Oct-2019 16:35:31 +0200';

      final h = remoteHeaderFromMime(mime);

      expect(h.date.toUtc(), DateTime.utc(2019, 10, 25, 14, 35, 31));
    });

    test('when it arrived is kept beside the Date header', () {
      final mime = build()
        ..setHeader('date', 'Fri, 25 Oct 2019 09:00:00 +0000')
        ..internalDate = '25-Oct-2019 16:35:31 +0200';

      final h = remoteHeaderFromMime(mime);

      expect(h.date.toUtc(), DateTime.utc(2019, 10, 25, 9));
      expect(h.arrived!.toUtc(), DateTime.utc(2019, 10, 25, 14, 35, 31));
    });

    test('INTERNALDATE is read in its own format', () {
      expect(parseInternalDate(' 5-Jan-2026 01:02:03 -0500')!.toUtc(),
          DateTime.utc(2026, 1, 5, 6, 2, 3));
      expect(parseInternalDate('"17-Jul-1996 02:44:25 -0700"')!.toUtc(),
          DateTime.utc(1996, 7, 17, 9, 44, 25));
      expect(parseInternalDate(null), isNull);
      expect(parseInternalDate('yesterday'), isNull);
      expect(parseInternalDate('17-Foo-1996 02:44:25 -0700'), isNull);
    });

    test('a missing subject is labelled', () {
      final mime = build()..setHeader('subject', '');
      expect(remoteHeaderFromMime(mime).subject, '(No subject)');
    });

    test('a message without a UID is a programming error', () {
      final mime = build()..uid = null;
      expect(() => remoteHeaderFromMime(mime), throwsArgumentError);
    });
  });

  group('bodyFromMime', () {
    test('prefers the plain-text part and keeps the html alongside', () {
      final builder = em.MessageBuilder.prepareMultipartAlternativeMessage(
        plainText: 'Plain version',
        htmlText: '<p>HTML version</p>',
      );
      final body = bodyFromMime(builder.buildMimeMessage());
      expect(body.text.trim(), 'Plain version');
      expect(body.html, contains('HTML version'));
    });

    test('falls back to a text rendering of html-only mail', () {
      final builder = em.MessageBuilder()
        ..addTextHtml('<div>Only <i>html</i> here.<br>Line two</div>');
      final body = bodyFromMime(builder.buildMimeMessage());
      expect(body.text, 'Only html here.\nLine two');
    });
  });

  group('the invitation in a message', () {
    const ics = 'BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\n'
        'UID:u-7\r\nSUMMARY:Our call\r\nDTSTART:20260923T184500Z\r\n'
        'END:VEVENT\r\nEND:VCALENDAR\r\n';

    test('is read from the calendar part where there is one', () {
      final builder = em.MessageBuilder.prepareMultipartAlternativeMessage(
        plainText: 'Please come.',
        htmlText: '<p>Please come.</p>',
      )..addText(ics, mediaType: em.MediaType.fromSubtype(
          em.MediaSubtype.textCalendar,
        ));

      final body = bodyFromMime(builder.buildMimeMessage());

      expect(body.calendar, contains('UID:u-7'));
    });

    test('is read from an attached .ics that says it is something else', () {
      // A booking made outside the mail system and passed on: the meeting is
      // a file, and the sender's software called it a stream of bytes. It is
      // still the invitation, and the reading pane should offer it.
      final builder = em.MessageBuilder()
        ..addTextHtml('<p>See you then.</p>')
        ..addBinary(
          Uint8List.fromList(utf8.encode(ics)),
          em.MediaType.fromText('application/octet-stream'),
          filename: 'meeting.ics',
        );

      final body = bodyFromMime(builder.buildMimeMessage());

      expect(body.calendar, contains('UID:u-7'));
      expect(CalendarInvite.parse(body.calendar!)!.summary, 'Our call');
    });

    test('an ordinary attachment is not mistaken for one', () {
      final builder = em.MessageBuilder()
        ..addTextHtml('<p>Attached.</p>')
        ..addBinary(
          Uint8List.fromList(utf8.encode('%PDF-1.4')),
          em.MediaType.fromText('application/pdf'),
          filename: 'report.pdf',
        );

      expect(bodyFromMime(builder.buildMimeMessage()).calendar, isNull);
    });

    test('what counts as a calendar file', () {
      expect(isCalendarFile('text/calendar; method=REQUEST', 'x'), isTrue);
      expect(isCalendarFile('application/octet-stream', 'invite.ICS'), isTrue);
      expect(isCalendarFile('application/ics', 'noname'), isTrue);
      expect(isCalendarFile('application/pdf', 'report.pdf'), isFalse);
      expect(isCalendarFile('text/plain', 'notes.txt'), isFalse);
    });
  });

  group('attachmentsOf', () {
    test('a picture named by Content-ID says so, marked inline or not', () {
      // Nothing matched the body's cid: links to the parts they name, so a
      // pasted screenshot showed as a broken image. And a part with a
      // Content-ID and no disposition was not listed at all.
      final root = em.BodyPart()
        ..contentType = em.ContentTypeHeader('multipart/related');
      root
        ..addPart(
          em.BodyPart()..contentType = em.ContentTypeHeader('text/html'),
        )
        ..addPart(
          em.BodyPart()
            ..contentType = em.ContentTypeHeader('image/png; name=logo.png')
            ..cid = '<logo@x>'
            ..size = 300,
        )
        ..addPart(
          em.BodyPart()
            ..contentType = em.ContentTypeHeader('image/jpeg')
            ..contentDisposition =
                em.ContentDispositionHeader('inline; filename=shot.jpg')
            ..cid = '<Shot@Y>'
            ..size = 900,
        );
      final message = em.MimeMessage()..body = root;

      final files = attachmentsOf(message);

      expect({
        for (final a in files) a.name: (a.id, a.isInline, a.contentId),
      }, {
        'shot.jpg': ('3', true, 'Shot@Y'),
        'logo.png': ('2', true, 'logo@x'),
      });
    });
  });

  group('htmlToText / preview', () {
    test('strips tags, decodes entities, keeps paragraph breaks', () {
      const html = '<html><head><style>p{}</style></head><body>'
          '<p>Tom &amp; Jerry</p><p>Next &lt;line&gt;</p>'
          '<script>alert(1)</script></body></html>';
      expect(htmlToText(html), 'Tom & Jerry\nNext <line>');
    });

    test('preview flattens whitespace and truncates with an ellipsis', () {
      expect(previewFromText('  a\n\n b   c '), 'a b c');
    });

    test('entities are decoded and invisible spacers dropped', () {
      // A marketing mail's text part: its HTML with the tags pulled out.
      expect(
        previewFromText(
          '96 MyDisney &zwnj; &zwnj; &zwnj; Email&nbsp;code &amp; more &#8217;s',
        ),
        '96 MyDisney Email code & more ’s',
      );
      expect(previewFromText('a &unknown; b'), 'a &unknown; b',
          reason: 'what is not an entity is left alone');
      final long = List.filled(50, 'word').join(' ');
      final p = previewFromText(long, maxLength: 20);
      expect(p.length, lessThanOrEqualTo(21));
      expect(p, endsWith('…'));
    });
  });
}
