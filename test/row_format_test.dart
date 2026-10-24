import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/row_format.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/row_formats.dart';

/// Outlook's conditional formatting: which messages a rule matches, which
/// rule wins, and that the rules are kept.
void main() {
  MailMessage m({
    String from = 'crystal@hadco-metal.com',
    String? name = 'Crystal R',
    String subject = 'Quote 4411',
    List<MailAddress> to = const [MailAddress(email: 'ron@hadco.com')],
    List<MailAddress> cc = const [],
  }) =>
      MailMessage(
        id: 'a:INBOX#1',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 1,
        subject: subject,
        preview: '',
        from: MailAddress(email: from, name: name),
        to: to,
        cc: cc,
        date: DateTime(2026, 9, 1),
        isRead: true,
      );

  const own = {'ron@hadco.com'};

  RowFormat rule(RowCondition c, [String text = '']) =>
      RowFormat(id: '${c.name}-$text', condition: c, text: text);

  group('matching', () {
    test('From looks in the address and the name, any case', () {
      expect(rule(RowCondition.from, 'HADCO-metal').matches(m(), own), isTrue);
      expect(rule(RowCondition.from, 'crystal r').matches(m(), own), isTrue);
      expect(rule(RowCondition.from, 'gilad').matches(m(), own), isFalse);
    });

    test('Subject looks in the subject', () {
      expect(rule(RowCondition.subject, 'quote').matches(m(), own), isTrue);
      expect(rule(RowCondition.subject, 'invoice').matches(m(), own), isFalse);
    });

    test('Sent only to me: you alone on To, nobody copied', () {
      final r = rule(RowCondition.onlyToMe);
      expect(r.matches(m(), own), isTrue);
      expect(
        r.matches(m(cc: const [MailAddress(email: 'gilad@hadco.com')]), own),
        isFalse,
      );
      expect(
        r.matches(
          m(to: const [
            MailAddress(email: 'ron@hadco.com'),
            MailAddress(email: 'gilad@hadco.com'),
          ]),
          own,
        ),
        isFalse,
      );
    });

    test('a rule with nothing to look for matches nothing', () {
      expect(rule(RowCondition.from, '  ').matches(m(), own), isFalse);
    });

    test('the first rule that matches is the one a message gets', () {
      final rules = [
        rule(RowCondition.subject, 'invoice'),
        rule(RowCondition.from, 'hadco'),
        rule(RowCondition.subject, 'quote'),
      ];
      expect(rowFormatFor(m(), rules, own)?.id, 'from-hadco');
    });
  });

  test('each colour has a shade for the light list and the dark one', () {
    expect(RowColour.red.on(Brightness.light), const Color(0xFFC50F1F));
    expect(RowColour.red.on(Brightness.dark), isNot(RowColour.red.light));
  });

  test('a rule written and read back is the same rule', () {
    const original = RowFormat(
      id: 'r1',
      condition: RowCondition.from,
      text: 'hadco.com',
      colour: RowColour.teal,
      bold: true,
    );
    expect(RowFormat.fromJson(original.toJson()), original);
    expect(RowFormat.fromJson({'id': 'x', 'condition': 'nonsense'}), isNull);
  });

  group('the rules are kept', () {
    test('saved, moved and removed, and there after a restart', () {
      final store = MemoryUiStateStore();
      ProviderContainer open() => ProviderContainer(
            overrides: [uiStateStoreProvider.overrideWithValue(store)],
          );

      final first = open();
      final rules = first.read(rowFormatsProvider.notifier);
      rules.save(rule(RowCondition.from, 'hadco'));
      rules.save(rule(RowCondition.subject, 'quote'));
      rules.move('subject-quote', -1);
      rules.save(rule(RowCondition.from, 'hadco').copyWith(bold: true));
      first.dispose();

      final again = open();
      addTearDown(again.dispose);
      final kept = again.read(rowFormatsProvider);
      expect([for (final r in kept) r.id], ['subject-quote', 'from-hadco']);
      expect(kept.last.bold, isTrue, reason: 'saved over, in its place');

      again.read(rowFormatsProvider.notifier).remove('subject-quote');
      expect([for (final r in again.read(rowFormatsProvider)) r.id],
          ['from-hadco']);
    });
  });
}
