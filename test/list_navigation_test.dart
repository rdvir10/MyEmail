import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/list_navigation.dart';

/// Where the list puts you, and where the arrow keys take you.
void main() {
  MailMessage m(String id) => MailMessage(
    id: id,
    accountId: 'a',
    folderId: 'a:INBOX',
    uid: int.parse(id.substring(1)),
    subject: 'Subject $id',
    preview: 'Body of $id',
    from: const MailAddress(email: 'someone@example.com'),
    to: const [MailAddress(email: 'me@example.com')],
    date: DateTime.utc(2026, 9, 18),
  );

  final messages = [m('m1'), m('m2'), m('m3')];

  group('where a folder opens', () {
    test('at the top when there is nothing to go back to', () {
      expect(messageToLandOn(messages: messages), 'm1');
    });

    test('back where the folder was left', () {
      expect(messageToLandOn(messages: messages, lastOpened: 'm2'), 'm2');
    });

    test('an existing selection is left alone', () {
      // The list rebuilds whenever anything in it changes — a flag, a read
      // mark, a sync arriving. A rule that reached for the remembered message
      // each time would drag someone back off whatever they had moved to.
      expect(
        messageToLandOn(messages: messages, lastOpened: 'm1', current: 'm3'),
        'm3',
      );
    });

    test('a remembered message that has gone falls back to the top', () {
      // Deleted from another device, or moved. Landing on nothing would leave
      // the keyboard with nowhere to start.
      expect(messageToLandOn(messages: messages, lastOpened: 'deleted'), 'm1');
    });

    test('an empty folder lands nowhere', () {
      expect(messageToLandOn(messages: const []), isNull);
    });
  });

  group('the arrow keys', () {
    test('move down and up', () {
      expect(neighbourOf(messages, 'm1', 1), 'm2');
      expect(neighbourOf(messages, 'm2', -1), 'm1');
    });

    test('stop at the ends rather than wrapping', () {
      // Wrapping from the last message to the first loses someone's place in
      // a list of four hundred, and holding a key to the bottom should come
      // to rest there rather than start again.
      expect(neighbourOf(messages, 'm3', 1), 'm3');
      expect(neighbourOf(messages, 'm1', -1), 'm1');
    });

    test('a page past an end goes to that end', () {
      // Page Down with fewer than a page left did nothing at all.
      expect(neighbourOf(messages, 'm2', 10), 'm3');
      expect(neighbourOf(messages, 'm2', -10), 'm1');
    });

    test(
      'with nothing selected, down starts at the top and up at the bottom',
      () {
        expect(neighbourOf(messages, null, 1), 'm1');
        expect(neighbourOf(messages, null, -1), 'm3');
      },
    );

    test('a selection that has gone falls back to the top', () {
      expect(neighbourOf(messages, 'deleted', 1), 'm1');
    });

    test('an empty list goes nowhere', () {
      expect(neighbourOf(const [], 'm1', 1), isNull);
    });
  });

  group('the arrow keys past a closed date bar', () {
    // m2 and m3 are under a closed bar.
    final five = [m('m1'), m('m2'), m('m3'), m('m4'), m('m5')];
    const shown = {'m1', 'm4', 'm5'};

    test('step over the rows folded away', () {
      expect(neighbourOf(five, 'm1', 1, shown: shown), 'm4');
      expect(neighbourOf(five, 'm4', -1, shown: shown), 'm1');
      expect(neighbourOf(five, 'm1', 2, shown: shown), 'm5');
    });

    test('from a selection closed in with its group, go on either side', () {
      // Closing Today over the message being read leaves it selected. Down
      // from there went to the top of the list.
      expect(neighbourOf(five, 'm2', 1, shown: shown), 'm4');
      expect(neighbourOf(five, 'm3', 1, shown: shown), 'm4');
      expect(neighbourOf(five, 'm3', -1, shown: shown), 'm1');
      expect(neighbourOf(five, 'm2', 10, shown: shown), 'm5');
      expect(neighbourOf(five, 'm2', -10, shown: shown), 'm1');
    });

    test('with nothing above or below, stay at the end', () {
      expect(neighbourOf(five, 'm2', -1, shown: const {'m4', 'm5'}), 'm4');
      expect(neighbourOf(five, 'm5', 1, shown: shown), 'm5');
    });

    test('everything closed goes nowhere', () {
      expect(neighbourOf(five, 'm2', 1, shown: const {}), isNull);
    });
  });
}
