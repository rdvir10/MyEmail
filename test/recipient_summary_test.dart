import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/recipient_summary.dart';

/// The one folded line under a sender: as many names as fit, then a count.
void main() {
  List<MailAddress> people(int n) => [
        for (var i = 0; i < n; i++)
          MailAddress(email: 'p$i@example.com', name: 'Person $i'),
      ];

  bool upTo(int length, String line) => line.length <= length;

  test('names everyone when everyone fits', () {
    expect(
      recipientSummary(people(3), const [], fits: (l) => upTo(200, l)),
      'To: Person 0, Person 1, Person 2',
    );
  });

  test('names as many as fit, then says how many more', () {
    final line =
        recipientSummary(people(9), const [], fits: (l) => upTo(40, l));
    expect(line, 'To: Person 0, Person 1, Person 2 +6');
    expect(line.length, lessThanOrEqualTo(40));
  });

  test('always names one, however narrow', () {
    // "To: +9" would say nothing about who the message is to.
    expect(
      recipientSummary(people(9), const [], fits: (_) => false),
      'To: Person 0 +8',
    );
  });

  test('counts the copied beside the names', () {
    expect(
      recipientSummary(
        people(2),
        [const MailAddress(email: 'c@example.com', name: 'Chris Mai')],
        fits: (l) => upTo(200, l),
      ),
      'To: Person 0, Person 1  ·  CC 1',
    );
  });

  test('names the copied when nobody is on To', () {
    expect(
      recipientSummary(const [], people(2), fits: (l) => upTo(200, l)),
      'CC: Person 0, Person 1',
    );
  });

  test('a name with no display name is shown by its address', () {
    expect(
      recipientSummary(
        const [MailAddress(email: 'dana@example.com')],
        const [],
        fits: (_) => true,
      ),
      'To: dana@example.com',
    );
  });

  test('a list of hundreds costs a few measurements, not hundreds', () {
    var asked = 0;
    recipientSummary(people(300), const [], fits: (l) {
      asked++;
      return upTo(60, l);
    });
    expect(asked, lessThan(10));
  });
}
