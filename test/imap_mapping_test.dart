import 'package:enough_mail/enough_mail.dart' as em;
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/domain/account.dart';
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

  group('htmlToText / preview', () {
    test('strips tags, decodes entities, keeps paragraph breaks', () {
      const html = '<html><head><style>p{}</style></head><body>'
          '<p>Tom &amp; Jerry</p><p>Next &lt;line&gt;</p>'
          '<script>alert(1)</script></body></html>';
      expect(htmlToText(html), 'Tom & Jerry\nNext <line>');
    });

    test('preview flattens whitespace and truncates with an ellipsis', () {
      expect(previewFromText('  a\n\n b   c '), 'a b c');
      final long = List.filled(50, 'word').join(' ');
      final p = previewFromText(long, maxLength: 20);
      expect(p.length, lessThanOrEqualTo(21));
      expect(p, endsWith('…'));
    });
  });
}
