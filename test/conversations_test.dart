import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/conversations.dart';

int _uid = 0;

MailMessage _m({
  required String subject,
  String from = 'dana@example.com',
  String? messageId,
  String? inReplyTo,
  String? conversationId,
  int minute = 0,
  bool isRead = false,
  bool isFlagged = false,
  String accountId = 'a',
}) {
  final uid = ++_uid;
  return MailMessage(
    id: '$accountId:INBOX#$uid',
    accountId: accountId,
    folderId: '$accountId:INBOX',
    uid: uid,
    subject: subject,
    from: MailAddress(email: from),
    to: const [MailAddress(email: 'me@example.com')],
    date: DateTime(2026, 9, 16, 9, minute),
    preview: '',
    isRead: isRead,
    isFlagged: isFlagged,
    messageId: messageId,
    inReplyTo: inReplyTo,
    conversationId: conversationId,
  );
}

void main() {
  setUp(() => _uid = 0);

  group('normaliseSubject', () {
    test('strips the reply and forward prefixes', () {
      expect(normaliseSubject('Re: Contract'), 'contract');
      expect(normaliseSubject('FW: Contract'), 'contract');
      expect(normaliseSubject('Fwd: Contract'), 'contract');
    });

    test('strips the stack a thread collects passing through clients', () {
      expect(normaliseSubject('Re: Fwd: RE: Contract'), 'contract');
      expect(normaliseSubject('Re[2]: Contract'), 'contract');
    });

    test('strips the localised forms other clients send', () {
      // A thread with one German or Scandinavian participant should not split
      // in two the moment they reply.
      expect(normaliseSubject('AW: Contract'), 'contract');
      expect(normaliseSubject('SV: Contract'), 'contract');
    });

    test('flattens the differences a person would not call a difference', () {
      expect(normaliseSubject('  Contract   draft '), 'contract draft');
      expect(normaliseSubject('CONTRACT'), normaliseSubject('contract'));
    });

    test('leaves a subject that merely starts with those letters alone', () {
      expect(normaliseSubject('Research budget'), 'research budget');
      expect(normaliseSubject('Reminder'), 'reminder');
    });
  });

  group('groupIntoConversations', () {
    test('the conversation the server keeps says which subjects are one, '
        'and which are not', () {
      // Two unrelated "SEO"s, which the subject alone made one thread and
      // both Outlooks show apart; and a renamed reply, which Exchange keeps
      // with what it answered.
      final apart = groupIntoConversations([
        _m(subject: 'SEO', conversationId: 'AAQk-1', minute: 1),
        _m(subject: 'SEO', from: 'sam@example.com', conversationId: 'AAQk-2',
            minute: 2),
      ]);
      expect(apart, hasLength(2));

      final together = groupIntoConversations([
        _m(subject: 'Quote', conversationId: 'AAQk-3', minute: 1),
        _m(subject: 'Re: Quote (final)', conversationId: 'AAQk-3', minute: 2),
      ]);
      expect(together.single.length, 2);
    });

    test('the server\'s conversation is scoped to the account, like the '
        'subject', () {
      final grouped = groupIntoConversations([
        _m(subject: 'SEO', conversationId: 'AAQk-1', accountId: 'a'),
        _m(subject: 'SEO', conversationId: 'AAQk-1', accountId: 'b'),
      ]);
      expect(grouped, hasLength(2));
    });

    test('a reply joins the message it answers', () {
      final first = _m(subject: 'Contract', messageId: 'one@example.com');
      final reply = _m(
        subject: 'Re: Contract',
        messageId: 'two@example.com',
        inReplyTo: 'one@example.com',
        minute: 5,
      );

      final grouped = groupIntoConversations([reply, first]);

      expect(grouped, hasLength(1));
      expect(grouped.single.length, 2);
      expect(grouped.single.oldest.id, first.id,
          reason: 'a thread reads oldest first');
    });

    test('a chain of three is one conversation, whatever the order', () {
      final a = _m(subject: 'Plan', messageId: 'a@x');
      final b = _m(subject: 'Re: Plan', messageId: 'b@x', inReplyTo: 'a@x', minute: 1);
      final c = _m(subject: 'Re: Plan', messageId: 'c@x', inReplyTo: 'b@x', minute: 2);

      expect(groupIntoConversations([c, a, b]).single.length, 3);
      expect(groupIntoConversations([b, c, a]).single.length, 3);
    });

    test('a renamed subject stays in the thread when the headers say so', () {
      // The whole reason to trust the headers over the subject.
      final first = _m(subject: 'Contract', messageId: 'one@x');
      final reply = _m(
        subject: 'Re: Contract, now about the invoice',
        messageId: 'two@x',
        inReplyTo: 'one@x',
        minute: 5,
      );

      expect(groupIntoConversations([first, reply]), hasLength(1));
    });

    test('messages with no headers at all still group by subject', () {
      // Everything cached before threading existed is in this state.
      final first = _m(subject: 'Lunch?');
      final reply = _m(subject: 'Re: Lunch?', minute: 5);

      expect(groupIntoConversations([first, reply]).single.length, 2);
    });

    test('different subjects stay apart', () {
      final grouped = groupIntoConversations([
        _m(subject: 'Contract'),
        _m(subject: 'Invoice', minute: 1),
      ]);
      expect(grouped, hasLength(2));
    });

    test('a blank subject joins nothing', () {
      // Otherwise every "(No subject)" in a mailbox becomes one conversation.
      final grouped = groupIntoConversations([
        _m(subject: '   '),
        _m(subject: '', minute: 1),
      ]);
      expect(grouped, hasLength(2));
    });

    test('the same subject in two accounts is two conversations', () {
      // Two people can both send "Lunch?" and a unified inbox must not merge
      // them just because both landed in it.
      final grouped = groupIntoConversations([
        _m(subject: 'Lunch?', accountId: 'a'),
        _m(subject: 'Lunch?', accountId: 'b', minute: 1),
      ]);
      expect(grouped, hasLength(2));
    });

    test('an In-Reply-To pointing at nothing we have does not lose the message',
        () {
      // The parent is older than the cached window, which is the normal case.
      final orphan = _m(
        subject: 'Re: Ancient',
        messageId: 'new@x',
        inReplyTo: 'long-gone@x',
      );
      final grouped = groupIntoConversations([orphan]);
      expect(grouped.single.length, 1);
    });

    test('conversations are newest first, by their newest message', () {
      final old = _m(subject: 'Old thread', minute: 0);
      final fresh = _m(subject: 'Fresh', minute: 30);
      final revived = _m(subject: 'Re: Old thread', minute: 45);

      final grouped = groupIntoConversations([old, fresh, revived]);

      expect(grouped.first.subject, 'Old thread',
          reason: 'a reply pulls its whole thread back to the top');
      expect(grouped.first.length, 2);
    });

    test('the collapsed row keeps the subject the thread started with', () {
      final first = _m(subject: 'Contract', messageId: 'one@x');
      final reply = _m(
        subject: 'Re: Contract (final, revised)',
        messageId: 'two@x',
        inReplyTo: 'one@x',
        minute: 5,
      );

      expect(groupIntoConversations([first, reply]).single.subject, 'Contract');
    });

    test('unread, flagged and attachments are true if any message is', () {
      final conversation = groupIntoConversations([
        _m(subject: 'T', messageId: 'a@x', isRead: true),
        _m(subject: 'Re: T', messageId: 'b@x', inReplyTo: 'a@x', minute: 1),
        _m(subject: 'Re: T', messageId: 'c@x', inReplyTo: 'b@x', minute: 2,
            isRead: true, isFlagged: true),
      ]).single;

      expect(conversation.hasUnread, isTrue,
          reason: 'one unread message means the row is not dealt with');
      expect(conversation.unreadCount, 1);
      expect(conversation.isFlagged, isTrue);
    });

    test('participants are listed once each, in the order they wrote', () {
      final conversation = groupIntoConversations([
        _m(subject: 'T', from: 'dana@example.com', messageId: 'a@x'),
        _m(subject: 'Re: T', from: 'sam@example.com', messageId: 'b@x',
            inReplyTo: 'a@x', minute: 1),
        _m(subject: 'Re: T', from: 'dana@example.com', messageId: 'c@x',
            inReplyTo: 'b@x', minute: 2),
      ]).single;

      expect(
        conversation.participants.map((p) => p.email),
        ['dana@example.com', 'sam@example.com'],
      );
    });

    test('a single message is a conversation of one, not a thread', () {
      final one = groupIntoConversations([_m(subject: 'Alone')]).single;
      expect(one.length, 1);
      expect(one.isThread, isFalse);
      expect(one.newest.id, one.oldest.id);
    });

    test('an empty list yields nothing rather than throwing', () {
      expect(groupIntoConversations(const []), isEmpty);
    });
  });

  group('normaliseMessageId', () {
    test('strips the angle brackets both ends of a link use', () {
      // The two ends have to match exactly or the thread breaks in half.
      expect(normaliseMessageId('<abc@example.com>'), 'abc@example.com');
      expect(normaliseMessageId('  <abc@example.com>  '), 'abc@example.com');
      expect(normaliseMessageId('abc@example.com'), 'abc@example.com');
    });

    test('takes the first id when a header carries several', () {
      expect(
        normaliseMessageId('<first@x> <second@x>'),
        'first@x',
        reason: 'the first is the message actually being answered',
      );
    });

    test('nothing in, nothing out', () {
      expect(normaliseMessageId(null), isNull);
      expect(normaliseMessageId('   '), isNull);
      expect(normaliseMessageId('<>'), isNull);
    });
  });
}
