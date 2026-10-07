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

  group('more of an address matches', () {
    const dana = AddressSuggestion(email: 'dana.levi@mail.hadco.com');

    test('any part before the @', () {
      expect(suggestionMatches(dana, 'levi'), isTrue);
    });

    test('the domain, and each name in it but the last', () {
      expect(suggestionMatches(dana, 'hadco'), isTrue);
      expect(suggestionMatches(dana, 'mail.had'), isTrue);
      expect(suggestionMatches(dana, 'co'), isFalse,
          reason: 'every address in .com would match');
    });
  });

  group('who is written to comes first', () {
    const newsletter = AddressSuggestion(
      email: 'deals@shop.example',
      timesSeen: 300,
    );
    const daniel = AddressSuggestion(
      email: 'daniel@example.com',
      name: 'Daniel',
      timesSeen: 4,
      timesSent: 2,
      weight: 0.4,
    );
    const david = AddressSuggestion(
      email: 'david@example.com',
      name: 'David',
      timesSeen: 3,
      timesSent: 1,
      weight: 0.9,
    );
    const dahlia = AddressSuggestion(
      email: 'dahlia@example.com',
      name: 'Dahlia',
      fromContacts: true,
    );

    test('lately before often, then the address book, then the rest', () {
      final ranked = rankSuggestions(
        'd',
        contacts: const [dahlia],
        history: const [newsletter, daniel, david],
      );

      expect(ranked.map((s) => s.name ?? s.email).toList(),
          ['David', 'Daniel', 'Dahlia', 'deals@shop.example']);
    });

    test('a no-reply address only if it was written to', () {
      const noReply = AddressSuggestion(email: 'no-reply@bank.example');
      const support = AddressSuggestion(
        email: 'do_not_reply@help.example',
        timesSent: 1,
        weight: 1,
      );
      final ranked = rankSuggestions(
        'n',
        contacts: const [],
        history: const [noReply],
      );
      expect(ranked, isEmpty);
      expect(isNoReplyAddress('Mailer-Daemon@x.example'), isTrue);
      expect(
        rankSuggestions('do', contacts: const [], history: const [support]),
        hasLength(1),
      );
    });

    test('nobody already in the field', () {
      final ranked = rankSuggestions(
        'da',
        contacts: const [],
        history: const [daniel, david],
        exclude: {'david@example.com'},
      );
      expect(ranked.map((s) => s.email), ['daniel@example.com']);
    });
  });

  group('the field as written so far', () {
    test('who is in it, without the one being typed', () {
      expect(
        recipientsAlreadyIn(
          '"Levi, Dana" <Dana@example.com>, ron@example.com, ro',
        ),
        {'dana@example.com', 'ron@example.com'},
      );
      expect(recipientsAlreadyIn('ro'), isEmpty);
    });
  });

  group('the mail history', () {
    final now = DateTime.utc(2026, 10, 1);
    AddressSeen seen(
      String email, {
      String? name,
      int daysAgo = 0,
      bool sent = false,
    }) =>
        (
          address: MailAddress(email: email, name: name),
          date: now.subtract(Duration(days: daysAgo)),
          sent: sent,
        );

    test('each address once, counted, with the newest name for it', () {
      final history = historyFrom([
        seen('rosa@example.com', name: 'Rosa L.', daysAgo: 1),
        seen('Rosa@example.com', name: 'Rosa Lind', daysAgo: 9),
        seen('rosa@example.com', daysAgo: 0),
      ], now: now);

      expect(history, hasLength(1));
      expect(history.single.timesSeen, 3);
      expect(history.single.name, 'Rosa L.');
    });

    test('mail written to someone counts toward them, weighed by age', () {
      final history = historyFrom([
        seen('rosa@example.com', sent: true),
        seen('rosa@example.com', sent: true, daysAgo: 30),
        seen('rosa@example.com', daysAgo: 2),
      ], now: now);

      expect(history.single.timesSeen, 3);
      expect(history.single.timesSent, 2);
      expect(history.single.weight, closeTo(1.5, 1e-9));
    });

    test('older mail weighs less', () {
      expect(recencyWeight(now.subtract(const Duration(days: 30)), now), 0.5);
      expect(recencyWeight(now.add(const Duration(days: 2)), now), 1,
          reason: 'a clock that is behind is not the future');
    });

    test('something that is not an address is not a person', () {
      expect(historyFrom([seen('undisclosed-recipients')], now: now), isEmpty);
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
