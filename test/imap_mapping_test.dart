import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/folder_role.dart';

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

  group('folderFromMailbox', () {
    final selectable = {
      'INBOX',
      '[Gmail]/Sent Mail',
      '[Gmail]/Starred',
      'Work',
      'Work/Invoices',
      'Orphan/Child',
    };

    test('the [Gmail] container is not a folder', () {
      final f = folderFromMailbox(
        accountId: 'a',
        provider: MailProvider.gmail,
        box: _box('[Gmail]',
            flags: [em.MailboxFlag.noSelect, em.MailboxFlag.hasChildren]),
        selectableModelPaths: selectable,
      );
      expect(f, isNull);
    });

    test('system folders are flattened to the root with counts', () {
      final f = folderFromMailbox(
        accountId: 'a',
        provider: MailProvider.gmail,
        box: _box('[Gmail]/Sent Mail',
            flags: [em.MailboxFlag.sent], exists: 120, unseen: 0),
        selectableModelPaths: selectable,
      )!;
      expect(f.id, 'a:[Gmail]/Sent Mail');
      expect(f.role, FolderRole.sent);
      expect(f.parentId, isNull, reason: 'not nested under [Gmail]');
      expect(f.displayName, 'Sent');
      expect(f.totalCount, 120);
      expect(f.capabilities.canRename, isFalse);
    });

    test('user folders keep their nesting when the parent is real', () {
      final f = folderFromMailbox(
        accountId: 'a',
        provider: MailProvider.gmail,
        box: _box('Work/Invoices', exists: 5, unseen: 2),
        selectableModelPaths: selectable,
      )!;
      expect(f.parentId, 'a:Work');
      expect(f.name, 'Invoices');
      expect(f.unreadCount, 2);
      expect(f.capabilities.canRename, isTrue);
    });

    test('a child whose parent is not selectable sits at the root', () {
      final f = folderFromMailbox(
        accountId: 'a',
        provider: MailProvider.gmail,
        box: _box('Orphan/Child'),
        selectableModelPaths: selectable,
      )!;
      expect(f.parentId, isNull);
    });

    test('Gmail Starred is browsable and droppable but locked', () {
      final f = folderFromMailbox(
        accountId: 'a',
        provider: MailProvider.gmail,
        box: _box('[Gmail]/Starred', flags: [em.MailboxFlag.flagged]),
        selectableModelPaths: selectable,
      )!;
      expect(f.role, FolderRole.user);
      expect(f.capabilities.canRename, isFalse);
      expect(f.capabilities.canDelete, isFalse);
      expect(f.capabilities.canAcceptMessages, isTrue);
    });

    test('a dotted delimiter yields slash paths', () {
      final f = folderFromMailbox(
        accountId: 'a',
        provider: MailProvider.gmail,
        box: _box('Work.Invoices', sep: '.'),
        selectableModelPaths: {'Work', 'Work/Invoices'},
      )!;
      expect(f.path, 'Work/Invoices');
      expect(f.parentId, 'a:Work');
    });
  });

  group('pageSequence', () {
    test('first page is the newest window', () {
      expect(pageSequence(exists: 100, offset: 0, limit: 50),
          (start: 51, end: 100));
    });

    test('later pages walk down and clamp at 1', () {
      expect(pageSequence(exists: 100, offset: 50, limit: 50),
          (start: 1, end: 50));
      expect(pageSequence(exists: 30, offset: 0, limit: 50),
          (start: 1, end: 30));
    });

    test('past the end is null, as is an empty folder', () {
      expect(pageSequence(exists: 100, offset: 100, limit: 50), isNull);
      expect(pageSequence(exists: 0, offset: 0, limit: 50), isNull);
    });
  });

  group('messageFromMime', () {
    em.MimeMessage build() {
      final builder = em.MessageBuilder.prepareMultipartAlternativeMessage(
        plainText: 'Hello there.\n\nSecond paragraph.',
        htmlText: '<p>Hello <b>there</b>.</p><p>Second paragraph.</p>',
      )
        ..from = [em.MailAddress('Dana Levi', 'dana@example.com')]
        ..to = [em.MailAddress(null, 'me@example.com')]
        ..subject = 'Invoice ready';
      return builder.buildMimeMessage()
        ..uid = 42
        ..flags = [em.MessageFlags.seen, em.MessageFlags.flagged];
    }

    test('headers and flags come through', () {
      final m = messageFromMime(
        accountId: 'a',
        folderId: 'a:INBOX',
        m: build(),
        fallbackDate: DateTime(2026, 9, 14),
      );
      expect(m.id, 'a:INBOX#42');
      expect(m.uid, 42);
      expect(m.subject, 'Invoice ready');
      expect(m.from.email, 'dana@example.com');
      expect(m.from.name, 'Dana Levi');
      expect(m.to.single.email, 'me@example.com');
      expect(m.isRead, isTrue);
      expect(m.isFlagged, isTrue);
      expect(m.hasAttachments, isFalse);
      expect(m.preview, isEmpty, reason: 'filled from the cached body later');
    });

    test('Reply-To comes through when it names someone else', () {
      final mime = build()
        ..setHeader('reply-to', 'Support <ticket-4411@vendor.example>');
      final m = messageFromMime(accountId: 'a', folderId: 'a:INBOX', m: mime);
      final h = remoteHeaderFromMime(mime);

      expect(m.replyTo.single.email, 'ticket-4411@vendor.example');
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

    test('a missing subject is labelled', () {
      final mime = build()..setHeader('subject', '');
      final m = messageFromMime(accountId: 'a', folderId: 'a:INBOX', m: mime);
      expect(m.subject, '(No subject)');
    });

    test('a message without a UID is a programming error', () {
      final mime = build()..uid = null;
      expect(
        () => messageFromMime(accountId: 'a', folderId: 'a:INBOX', m: mime),
        throwsArgumentError,
      );
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
