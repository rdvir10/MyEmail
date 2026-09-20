import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/windows/window_opener.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/window_handoff.dart';

/// What crosses to a second window, and how it gets there.
void main() {
  final draft = Draft(
    accountId: 'acct',
    kind: ComposeKind.reply,
    to: const [MailAddress(email: 'a@example.com', name: 'A')],
    cc: const [MailAddress(email: 'c@example.com')],
    subject: 'Re: numbers',
    htmlBody: '<p>Hi</p><blockquote>quoted</blockquote>',
    attachments: [
      DraftAttachment(
        fileName: 'notes.txt',
        mimeType: 'text/plain',
        bytes: Uint8List.fromList([1, 2, 3, 250, 255]),
      ),
    ],
    inReplyTo: '<x@example.com>',
    references: const ['<w@example.com>', '<x@example.com>'],
    originalMessageId: 'acct:INBOX#12',
    lostAttachmentNames: const ['big.zip'],
  );

  final message = MailMessage(
    id: 'acct:INBOX#12',
    accountId: 'acct',
    folderId: 'acct:INBOX',
    uid: 12,
    subject: 'numbers',
    from: const MailAddress(email: 'a@example.com', name: 'A'),
    to: const [MailAddress(email: 'me@example.com')],
    date: DateTime.utc(2026, 9, 20, 13, 25),
    preview: 'the numbers',
    isRead: true,
    isFlagged: true,
    hasAttachments: true,
    messageId: '<x@example.com>',
  );

  group('a draft', () {
    test('comes back whole, attachment bytes included', () {
      final back = WindowRequest.decode(ComposeWindow(draft).encode());

      final d = (back as ComposeWindow).draft;
      expect(d.accountId, draft.accountId);
      expect(d.kind, draft.kind);
      expect(d.to.single.name, 'A');
      expect(d.cc.single.email, 'c@example.com');
      expect(d.bcc, isEmpty);
      expect(d.subject, draft.subject);
      expect(d.htmlBody, draft.htmlBody);
      expect(d.attachments.single.fileName, 'notes.txt');
      expect(d.attachments.single.bytes, [1, 2, 3, 250, 255]);
      expect(d.inReplyTo, draft.inReplyTo);
      expect(d.references, draft.references);
      expect(d.originalMessageId, draft.originalMessageId);
      expect(d.savedAs, isNull);
      expect(d.lostAttachmentNames, ['big.zip']);
    });
  });

  group('a message', () {
    test('comes back whole', () {
      final back = WindowRequest.decode(MessageWindow(message).encode());

      final m = (back as MessageWindow).message;
      expect(m.id, message.id);
      expect(m.folderId, message.folderId);
      expect(m.uid, 12);
      expect(m.from.name, 'A');
      expect(m.to.single.email, 'me@example.com');
      expect(m.date, message.date);
      expect(m.isRead, isTrue);
      expect(m.isFlagged, isTrue);
      expect(m.hasAttachments, isTrue);
      expect(m.messageId, message.messageId);
      expect(m.inReplyTo, isNull);
    });
  });

  group('the route a window starts on', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('windows'));
    tearDown(() => dir.delete(recursive: true));

    test('names a file, which is read once and taken away', () async {
      final file = File('${dir.path}${Platform.pathSeparator}w.json');
      await file.writeAsString(MessageWindow(message).encode());
      final route = Uri(
        path: windowRoutePrefix,
        queryParameters: {'file': file.path},
      ).toString();

      final request = await windowRequestFromRoute(route);

      expect(request, isA<MessageWindow>());
      expect((request as MessageWindow).message.id, message.id);
      expect(file.existsSync(), isFalse,
          reason: 'a window the system restarts must not show a stale draft');
    });

    test('is not the ordinary start', () async {
      expect(await windowRequestFromRoute('/'), isNull);
    });

    test('with its file gone, is nothing to show', () async {
      final route = Uri(
        path: windowRoutePrefix,
        queryParameters: {'file': '${dir.path}/missing.json'},
      ).toString();

      expect(await windowRequestFromRoute(route), isNull);
    });
  });
}
