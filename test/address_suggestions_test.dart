import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/address_suggestions.dart';
import 'package:myemail/domain/mail_message.dart';

/// Who is suggested as a recipient is typed, and in what order.
void main() {
  const ron = AddressSuggestion(
    email: 'ron@example.com',
    name: 'Ron Dvir',
    fromContacts: true,
  );
  const rosa = AddressSuggestion(
    email: 'rosa@example.com',
    name: 'Rosa Lind',
    timesSeen: 12,
  );
  const robotics = AddressSuggestion(
    email: 'robotics@example.com',
    timesSeen: 40,
  );

  group('what counts as a match', () {
    test('the start of the name, of any word in it, or of the address', () {
      expect(suggestionMatches(ron, 'ron'), isTrue);
      expect(suggestionMatches(ron, 'dv'), isTrue, reason: 'second word');
      expect(suggestionMatches(ron, 'ron@'), isTrue, reason: 'address');
      expect(suggestionMatches(ron, 'vir'), isFalse, reason: 'not a prefix of anything');
    });

    test('an address alone is matched on the address', () {
      expect(suggestionMatches(robotics, 'rob'), isTrue);
      expect(suggestionMatches(robotics, 'ics'), isFalse);
    });
  });

  group('ranking', () {
    test('the address book comes before the mail history', () {
      // A person in the address book is a person, not a mailing list that
      // happened to write a lot.
      final ranked = rankSuggestions(
        'ro',
        contacts: const [ron],
        history: const [rosa, robotics],
      );

      expect(ranked.map((s) => s.email).toList(), [
        'ron@example.com',
        'robotics@example.com',
        'rosa@example.com',
      ]);
    });

    test('one entry per address, spelled the way the address book has it',
        () {
      final ranked = rankSuggestions(
        'ron',
        contacts: const [ron],
        history: const [
          AddressSuggestion(
            email: 'RON@example.com',
            name: 'ron dvir (work)',
            timesSeen: 5,
          ),
        ],
      );

      expect(ranked, hasLength(1));
      expect(ranked.single.name, 'Ron Dvir');
      expect(ranked.single.fromContacts, isTrue);
      expect(ranked.single.timesSeen, 5,
          reason: 'how often they come up is still worth knowing');
    });

    test('nothing for nothing typed', () {
      expect(rankSuggestions('  ', contacts: const [ron], history: const [rosa]),
          isEmpty);
    });

    test('a long list is cut', () {
      final many = [
        for (var i = 0; i < 30; i++)
          AddressSuggestion(email: 'person$i@example.com', timesSeen: i),
      ];

      expect(rankSuggestions('person', contacts: const [], history: many),
          hasLength(8));
    });
  });

  group('the mail history', () {
    test('each address once, counted, with the newest name for it', () {
      // Newest first, as the cache hands messages over.
      final history = historyFrom(const [
        MailAddress(email: 'rosa@example.com', name: 'Rosa L.'),
        MailAddress(email: 'Rosa@example.com', name: 'Rosa Lind'),
        MailAddress(email: 'rosa@example.com'),
      ]);

      expect(history, hasLength(1));
      expect(history.single.timesSeen, 3);
      expect(history.single.name, 'Rosa L.');
    });

    test('something that is not an address is not a person', () {
      expect(historyFrom(const [MailAddress(email: 'undisclosed-recipients')]),
          isEmpty);
    });
  });

  group('completing what was typed', () {
    test('the last name on the line is the one being typed', () {
      expect(lastRecipientToken('Ron Dvir <ron@example.com>, ro'), 'ro');
      expect(lastRecipientToken('ro'), 'ro');
      expect(lastRecipientToken('a@example.com, '), '');
    });

    test('choosing replaces it and leaves a comma for the next', () {
      expect(
        completeLastRecipient('a@example.com, ro', ron),
        'a@example.com, Ron Dvir <ron@example.com>, ',
      );
      expect(completeLastRecipient('ro', ron), 'Ron Dvir <ron@example.com>, ');
    });

    test('a name-less address is written bare', () {
      expect(completeLastRecipient('rob', robotics), 'robotics@example.com, ');
    });
  });
}
