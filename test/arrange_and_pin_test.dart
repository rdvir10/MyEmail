import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_sort.dart';
import 'package:myemail/state/conversations.dart';
import 'package:myemail/ui/messages/list_groups.dart';

/// Outlook's other arrangements (size, attachments, flag, To, account),
/// the bars over them, and pinned messages at the top.
void main() {
  MailMessage m(
    int uid, {
    int day = 1,
    int size = 0,
    bool files = false,
    bool flagged = false,
    String account = 'a',
    List<MailAddress> to = const [],
    String subject = 'Numbers',
  }) =>
      MailMessage(
        id: '$account:INBOX#$uid',
        accountId: account,
        folderId: '$account:INBOX',
        uid: uid,
        subject: subject,
        preview: '',
        from: const MailAddress(email: 'dana@example.com'),
        to: to,
        date: DateTime(2026, 9, day),
        isRead: true,
        sizeBytes: size,
        hasAttachments: files,
        isFlagged: flagged,
      );

  List<int> uids(List<MailMessage> list) => [for (final x in list) x.uid];

  group('arranging', () {
    test('by size runs largest first, the newest first among equals', () {
      final sorted = sortMessages([
        m(1, size: 2000, day: 1),
        m(2, size: 900000, day: 2),
        m(3, size: 2000, day: 3),
      ], MessageSort.size);
      expect(uids(sorted), [2, 3, 1]);
    });

    test('by attachments puts what has files first', () {
      final sorted = sortMessages([
        m(1, day: 3),
        m(2, files: true, day: 1),
        m(3, files: true, day: 2),
      ], MessageSort.attachments);
      expect(uids(sorted), [3, 2, 1]);
    });

    test('by flag puts what is flagged first', () {
      final sorted = sortMessages([
        m(1, day: 3),
        m(2, flagged: true, day: 1),
      ], MessageSort.flag);
      expect(uids(sorted), [2, 1]);
    });

    test('by To runs A to Z on the first recipient, with nobody last', () {
      final sorted = sortMessages([
        m(1),
        m(2, to: const [MailAddress(email: 'z@x.com', name: 'Zoe')]),
        m(3, to: const [MailAddress(email: 'a@x.com', name: 'Avi')]),
      ], MessageSort.recipient);
      expect(uids(sorted), [3, 2, 1]);
    });

    test('by account follows the folder pane, an unknown account last', () {
      final sorted = sortMessages(
        [m(1, account: 'c'), m(2, account: 'b'), m(3, account: 'a')],
        MessageSort.account,
        accountRank: const {'b': 0, 'a': 1},
      );
      expect(uids(sorted), [2, 3, 1]);
    });
  });

  group('bars', () {
    test('sizes fall into Outlook\'s groups', () {
      const kb = 1024;
      expect(sizeGroup(0).key, 'size:unknown');
      expect(sizeGroup(4 * kb).label, 'Tiny (under 10 KB)');
      expect(sizeGroup(20 * kb).key, 'size:small');
      expect(sizeGroup(60 * kb).key, 'size:medium');
      expect(sizeGroup(200 * kb).key, 'size:large');
      expect(sizeGroup(700 * kb).key, 'size:very-large');
      expect(sizeGroup(3 * kb * kb).key, 'size:huge');
      expect(sizeGroup(9 * kb * kb).label, 'Enormous (over 5 MB)');
    });

    test('a name or a subject draws no bars', () {
      expect(MessageSort.sender.hasBars, isFalse);
      expect(MessageSort.recipient.hasBars, isFalse);
      expect(MessageSort.subject.hasBars, isFalse);
      expect(listGroupOf(m(1), MessageSort.sender), isNull);
      expect(MessageSort.size.hasBars, isTrue);
      expect(MessageSort.account.hasBars, isTrue);
    });

    test('an account bar is named as the folder pane names it', () {
      final group = listGroupOf(
        m(1, account: 'b'),
        MessageSort.account,
        accountNames: const {'b': 'Hadco'},
      );
      expect(group?.label, 'Hadco');
    });

    test('a closed size bar folds its rows away from the keys too', () {
      final folded = foldedUnder({'size:huge'}, MessageSort.size)!;
      expect(folded(m(1, size: 3 * 1024 * 1024)), isTrue);
      expect(folded(m(2, size: 2048)), isFalse);
    });
  });

  group('pinned', () {
    test('pinned messages come first, in the order the list has them', () {
      final sorted = sortMessages(
        [m(1, day: 1), m(2, day: 2), m(3, day: 3)],
        MessageSort.dateNewest,
        pinned: {'a:INBOX#1', 'a:INBOX#2'},
      );
      expect(uids(sorted), [2, 1, 3]);
    });

    test('a thread with a pinned message in it comes first', () {
      final old = m(1, day: 1, subject: 'Lunch?');
      final reply = m(2, day: 2, subject: 'Re: Lunch?');
      final fresh = m(3, day: 5, subject: 'Other');
      final threads = conversationsInOrder(
        [fresh, reply, old],
        MessageSort.dateNewest,
        pinned: {old.id},
      );
      expect(threads.first.messages.map((x) => x.uid), [1, 2]);
    });

    test('closing the Pinned bar hides the pinned rows and nothing else', () {
      final rows = visibleMessages(
        [m(1, day: 1), m(2, day: 2)],
        conversations: false,
        expandedIds: const {},
        sort: MessageSort.dateNewest,
        pinned: {'a:INBOX#2'},
        pinnedClosed: true,
      );
      expect(uids(rows), [1]);
    });
  });
}
