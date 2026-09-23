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

    String routeTo(String path) =>
        Uri(path: windowRoutePrefix, queryParameters: {'file': path})
            .toString();

    test('names a file, which is read once and taken away', () async {
      final file = File('${dir.path}${Platform.pathSeparator}1234567.json');
      await file.writeAsString(MessageWindow(message).encode());

      final request =
          await windowRequestFromRoute(routeTo(file.path), handoffDir: dir);

      expect(request, isA<MessageWindow>());
      expect((request as MessageWindow).message.id, message.id);
      expect(file.existsSync(), isFalse,
          reason: 'a window the system restarts must not show a stale draft');
    });

    test('is not the ordinary start', () async {
      expect(await windowRequestFromRoute('/', handoffDir: dir), isNull);
    });

    test('with its file gone, is nothing to show', () async {
      expect(
        await windowRequestFromRoute(
          routeTo('${dir.path}${Platform.pathSeparator}7654321.json'),
          handoffDir: dir,
        ),
        isNull,
      );
    });

    // Another app can start the app on a route of its choosing. A route
    // naming any file the app could reach used to read it and delete it,
    // the stored sign-ins among them.
    test('a file outside the windows folder is neither read nor deleted',
        () async {
      final elsewhere = await Directory.systemTemp.createTemp('private');
      addTearDown(() => elsewhere.delete(recursive: true));
      final secret = File('${elsewhere.path}${Platform.pathSeparator}1.json');
      await secret.writeAsString(MessageWindow(message).encode());

      expect(
        await windowRequestFromRoute(routeTo(secret.path), handoffDir: dir),
        isNull,
      );
      expect(secret.existsSync(), isTrue);
    });

    test('nor a way out of it through ..', () async {
      final sibling = File('${dir.parent.path}${Platform.pathSeparator}'
          '${DateTime.now().microsecondsSinceEpoch}.json');
      await sibling.writeAsString(MessageWindow(message).encode());
      addTearDown(() {
        if (sibling.existsSync()) sibling.deleteSync();
      });
      final sep = Platform.pathSeparator;
      final escaping = '${dir.path}$sep..$sep${sibling.uri.pathSegments.last}';

      expect(
        await windowRequestFromRoute(routeTo(escaping), handoffDir: dir),
        isNull,
      );
      expect(sibling.existsSync(), isTrue);
    });

    test('nor a file in it that is not named as a hand-off', () async {
      final other = File('${dir.path}${Platform.pathSeparator}notes.xml');
      await other.writeAsString('<map/>');

      expect(
        await windowRequestFromRoute(routeTo(other.path), handoffDir: dir),
        isNull,
      );
      expect(other.existsSync(), isTrue);
    });

    test('a hand-off that does not read as a window is left in place',
        () async {
      final broken = File('${dir.path}${Platform.pathSeparator}42.json');
      await broken.writeAsString('not a window');

      expect(
        await windowRequestFromRoute(routeTo(broken.path), handoffDir: dir),
        isNull,
      );
      expect(broken.existsSync(), isTrue);
    });
  });
}
