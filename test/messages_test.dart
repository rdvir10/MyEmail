import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/data/sample/sample_mail_engine.dart';
import 'package:mailtree/data/sample/sample_messages.dart';
import 'package:mailtree/domain/folder_role.dart';
import 'package:mailtree/domain/mail_folder.dart';
import 'package:mailtree/domain/mail_message.dart';
import 'package:mailtree/state/folder_tree.dart';
import 'package:mailtree/state/message_providers.dart';
import 'package:mailtree/state/providers.dart';
import 'package:mailtree/ui/messages/date_format.dart';

Future<MailFolder> _folder(String path, {String account = 'acct-personal'}) async {
  final engine = SampleMailEngine();
  await engine.loadAccounts();
  final list = await engine.loadFolders(account);
  return list.firstWhere((f) => f.path == path);
}

final _fixedDate = DateTime(2026, 9, 16, 9);

void main() {
  group('MailMessage equality', () {
    // Riverpod skips notifying when a provider's new value equals the old.
    // With id-only equality a flag change was invisible to anything watching
    // a provider that hands out a message, so the reading pane and the ribbon
    // kept offering "mark as read" for a message that had just been read.
    final base = MailMessage(
      id: 'a:INBOX#1',
      accountId: 'a',
      folderId: 'a:INBOX',
      uid: 1,
      subject: 'Subject',
      from: MailAddress(email: 'dana@example.com'),
      to: [],
      date: _fixedDate,
      preview: '',
    );

    test('the same message in a different state is not equal', () {
      expect(base.copyWith(isRead: true), isNot(base));
      expect(base.copyWith(isFlagged: true), isNot(base));
      expect(
        base.copyWith(isRead: true).hashCode,
        isNot(base.hashCode),
      );
    });

    test('the same message in the same state is equal', () {
      expect(base.copyWith(isRead: false), base);
      expect(base.copyWith(isRead: false).hashCode, base.hashCode);
    });
  });

  group('sample messages', () {
    test('are deterministic for a folder', () async {
      final folder = await _folder('INBOX');
      final now = DateTime(2026, 9, 14, 12);
      final a = generateSampleMessages(folder, now: now);
      final b = generateSampleMessages(folder, now: now);
      expect(a.map((m) => m.id), b.map((m) => m.id));
      expect(a.map((m) => m.subject), b.map((m) => m.subject));
    });

    test('follow the folder counts, capped per page', () async {
      final inbox = await _folder('INBOX');
      final msgs = generateSampleMessages(inbox);
      expect(msgs, hasLength(60), reason: 'INBOX has 2310, capped at 60');
      expect(msgs.where((m) => !m.isRead), hasLength(14),
          reason: 'unread count is honoured');

      final drafts = await _folder('[Gmail]/Drafts');
      expect(generateSampleMessages(drafts), hasLength(3));
    });

    test('are newest first with unique uids', () async {
      final msgs = generateSampleMessages(await _folder('INBOX'));
      for (var i = 1; i < msgs.length; i++) {
        expect(msgs[i].date.isBefore(msgs[i - 1].date), isTrue);
      }
      expect(msgs.map((m) => m.uid).toSet().length, msgs.length);
      expect(msgs.first.id, endsWith('#2310'));
    });

    test('outgoing folders are from me and already read', () async {
      final sent = await _folder('[Gmail]/Sent Mail');
      final msgs = generateSampleMessages(sent);
      expect(msgs.every((m) => m.from.email == 'me@example.com'), isTrue);
      expect(msgs.every((m) => m.isRead), isTrue);
    });

    test('bodies are generated and stable', () async {
      final msgs = generateSampleMessages(await _folder('INBOX'));
      final body = generateSampleBody(msgs.first);
      expect(body.text, startsWith('Hi,'));
      expect(body.text, contains(msgs.first.preview));
      expect(generateSampleBody(msgs.first).text, body.text);
    });
  });

  group('engine paging', () {
    test('offset and limit page through a folder', () async {
      final engine = SampleMailEngine();
      await engine.loadAccounts();
      await engine.loadFolders('acct-personal');
      final first = await engine.loadMessages('acct-personal:INBOX', limit: 10);
      final second = await engine.loadMessages(
        'acct-personal:INBOX',
        offset: 10,
        limit: 10,
      );
      expect(first, hasLength(10));
      expect(second, hasLength(10));
      expect(first.last.date.isAfter(second.first.date), isTrue);
      expect(
        await engine.loadMessages('acct-personal:INBOX', offset: 500),
        isEmpty,
      );
    });

    test('a body can be fetched for a listed message', () async {
      final engine = SampleMailEngine();
      await engine.loadAccounts();
      await engine.loadFolders('acct-personal');
      final msgs = await engine.loadMessages('acct-personal:INBOX', limit: 1);
      final body = await engine.loadMessageBody(msgs.single.id);
      expect(body.text, isNotEmpty);
    });
  });

  group('providers', () {
    ProviderContainer container() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('unified inbox merges every account newest first', () async {
      final c = container();
      await c.read(foldersProvider.future);
      final merged = await c.read(messagesProvider(kUnifiedInboxId).future);
      expect(merged.map((m) => m.accountId).toSet(),
          {'acct-personal', 'acct-side'});
      for (var i = 1; i < merged.length; i++) {
        expect(merged[i].date.isAfter(merged[i - 1].date), isFalse);
      }
      expect(
        merged.every((m) => m.folderId.endsWith(':INBOX')),
        isTrue,
        reason: 'only Inboxes contribute',
      );
    });

    test('a selected message clears itself when the folder changes',
        () async {
      final c = container();
      await c.read(foldersProvider.future);
      c.read(selectedFolderIdProvider.notifier).select('acct-personal:INBOX');
      final msgs =
          await c.read(messagesProvider('acct-personal:INBOX').future);
      c.read(selectedMessageIdProvider.notifier).select(msgs.first.id);
      expect(c.read(selectedMessageProvider), msgs.first);

      c.read(selectedFolderIdProvider.notifier).select('acct-personal:Travel');
      await c.read(messagesProvider('acct-personal:Travel').future);
      expect(c.read(selectedMessageProvider), isNull);
    });
  });

  group('date format', () {
    final now = DateTime(2026, 9, 14, 15, 30);

    test('today shows the time', () {
      expect(formatMessageDate(DateTime(2026, 9, 14, 9, 5), now: now), '09:05');
    });

    test('this year shows day and month', () {
      expect(formatMessageDate(DateTime(2026, 3, 2), now: now), '2 Mar');
    });

    test('older shows the full date', () {
      expect(
        formatMessageDate(DateTime(2025, 12, 31, 23), now: now),
        '31/12/2025',
      );
    });

    test('long form for the reading pane', () {
      expect(
        formatMessageDateLong(DateTime(2026, 9, 14, 9, 41)),
        'Mon 14 Sep 2026, 09:41',
      );
    });
  });

  test('folder role sanity for sample data', () async {
    final inbox = await _folder('INBOX');
    expect(inbox.role, FolderRole.inbox);
  });
}
