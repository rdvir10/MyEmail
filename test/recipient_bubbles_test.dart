import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/contacts/device_contacts.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/compose_providers.dart';
import 'package:myemail/state/contact_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/compose/header_fields.dart';

import 'fakes/fake_webview.dart';

/// A recipients line is a bubble a person, as Outlook has them: folded to
/// one row while the cursor is elsewhere, a menu on a tap, and dragged from
/// To to Cc or Bcc (Ron, 2026-11-09).
void main() {
  setUpAll(FakeWebViewPlatform.install);

  const dana = MailAddress(email: 'dana@example.com', name: 'Dana Levi');
  const sam = MailAddress(email: 'sam@example.com');

  /// Twenty people, Person 01 to Person 20.
  final many = [
    for (var i = 1; i <= 20; i++)
      MailAddress(
        email: 'p${'$i'.padLeft(2, '0')}@example.com',
        name: 'Person ${'$i'.padLeft(2, '0')}',
      ),
  ];

  Draft draft({
    List<MailAddress> to = const [],
    List<MailAddress> cc = const [],
  }) =>
      Draft(
        accountId: 'acct-personal',
        kind: to.isEmpty ? ComposeKind.newMessage : ComposeKind.replyAll,
        to: to,
        cc: cc,
        bcc: const [],
        subject: to.isEmpty ? '' : 'Re: Budget',
        htmlBody: '<p></p>',
        attachments: const [],
      );

  Future<void> open(WidgetTester tester, Draft d) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
        deviceContactsProvider.overrideWithValue(FakeDeviceContacts()),
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: ComposeScreen(draft: d)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder line(String label) =>
      find.byWidgetPredicate((w) => w is RecipientField && w.label == label);

  /// What [label]'s line holds, as the message will have it.
  String holds(WidgetTester tester, String label) =>
      tester.widget<RecipientField>(line(label)).controller.text;

  /// The field a line's next person is typed in.
  Finder field(String label) =>
      find.descendant(of: line(label), matching: find.byType(TextField));

  /// A line's name, to the left of it: somewhere to drop a bubble.
  Finder name(String label) => find.descendant(
        of: find.byWidgetPredicate((w) => w is SizedBox && w.width == 64),
        matching: find.text(label),
      );

  Finder more() => find.textContaining(RegExp(r'^\+\d+$'));

  Finder subject() => find.descendant(
        of: find.byType(HeaderField),
        matching: find.byType(TextField),
      );

  /// [person]'s bubble on [label]'s line held until it is picked up, and
  /// moved a little.
  Future<TestGesture> pickUp(
    WidgetTester tester,
    String person, {
    String label = 'To',
  }) async {
    final gesture = await tester.startGesture(tester.getCenter(
        find.descendant(of: line(label), matching: find.text(person))));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump();
    return gesture;
  }

  Future<void> dropOn(
    WidgetTester tester,
    TestGesture gesture,
    Offset at,
  ) async {
    await gesture.moveTo(at);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  group('a long line', () {
    testWidgets('folds to one row, the rest counted after it',
        (tester) async {
      await open(tester, draft(to: const [dana], cc: many));

      final count = int.parse(
          tester.widget<Text>(more()).data!.substring(1));
      final shown = [
        for (final p in many)
          if (find.text(p.name!).evaluate().isNotEmpty) p,
      ];
      expect(shown, isNotEmpty);
      expect(shown.length + count, many.length);
      expect(shown, many.take(shown.length), reason: 'the first ones');
      expect(tester.getSize(line('Cc')).height, lessThan(50),
          reason: 'one row');
      expect(parseAddresses(holds(tester, 'Cc')), many,
          reason: 'everyone is still on the message');
    });

    testWidgets('a tap opens it, and leaving folds it again',
        (tester) async {
      await open(tester, draft(to: const [dana], cc: many));

      await tester.tap(more());
      await tester.pumpAndSettle();

      expect(more(), findsNothing);
      for (final p in many) {
        expect(find.text(p.name!), findsOneWidget);
      }
      expect(tester.widget<TextField>(field('Cc')).focusNode!.hasFocus,
          isTrue);
      expect(find.text('Person 20').hitTestable(), findsOneWidget,
          reason: 'the end in sight, by the cursor');

      await tester.tap(subject());
      await tester.pumpAndSettle();

      expect(more(), findsOneWidget);
      expect(find.text('Person 20'), findsNothing);
    });

    testWidgets("stays folded under a bubble's menu", (tester) async {
      await open(tester, draft(to: const [dana], cc: many));

      await tester.tap(find.text('Person 01'));
      await tester.pumpAndSettle();
      expect(find.text('p01@example.com'), findsOneWidget,
          reason: 'the menu is up');
      expect(more(), findsOneWidget, reason: 'and the line still folded');

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(more(), findsOneWidget);
      expect(parseAddresses(holds(tester, 'Cc')), many.skip(1));
    });

    testWidgets('a short one is shown whole', (tester) async {
      await open(tester, draft(to: const [dana], cc: many.take(2).toList()));

      expect(more(), findsNothing);
      expect(find.text('Person 01'), findsOneWidget);
      expect(find.text('Person 02'), findsOneWidget);
    });
  });

  group('a bubble', () {
    testWidgets('shows the name, or the address where there is none',
        (tester) async {
      await open(tester, draft(to: const [dana, sam]));

      expect(find.text('Dana Levi'), findsOneWidget);
      expect(find.text('dana@example.com'), findsNothing);
      expect(find.text('sam@example.com'), findsOneWidget);
    });

    testWidgets('is made of what comes before a comma', (tester) async {
      await open(tester, draft());

      await tester.enterText(field('To'), 'sam@example.com, da');
      await tester.pump();

      expect(find.text('sam@example.com'), findsOneWidget);
      expect(tester.widget<TextField>(field('To')).controller!.text, 'da');
      expect(holds(tester, 'To'), 'sam@example.com, da');
    });

    testWidgets('and of the rest on leaving the line', (tester) async {
      await open(tester, draft());

      await tester.enterText(field('To'), 'sam@example.com');
      await tester.tap(subject());
      await tester.pumpAndSettle();

      expect(find.text('sam@example.com'), findsOneWidget);
      expect(tester.widget<TextField>(field('To')).controller!.text, '');
      expect(holds(tester, 'To'), 'sam@example.com');
    });

    testWidgets('Backspace picks out the last one, and a second takes it '
        'away', (tester) async {
      await open(tester, draft(to: const [dana, sam]));
      await tester.tap(field('To'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(holds(tester, 'To'), 'Dana Levi <dana@example.com>, '
          'sam@example.com', reason: 'only picked out');

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(holds(tester, 'To'), 'Dana Levi <dana@example.com>');
    });
  });

  group('dragged', () {
    testWidgets('from To to Cc, moves there', (tester) async {
      await open(tester, draft(to: const [dana, sam]));

      final gesture = await pickUp(tester, 'Dana Levi');
      await dropOn(tester, gesture, tester.getCenter(name('Cc')));

      expect(holds(tester, 'To'), 'sam@example.com');
      expect(holds(tester, 'Cc'), 'Dana Levi <dana@example.com>');
    });

    testWidgets('Bcc shows while one is carried, and stays dropped on',
        (tester) async {
      await open(tester, draft(to: const [dana, sam]));
      expect(name('Bcc'), findsNothing);

      final gesture = await pickUp(tester, 'Dana Levi');
      expect(name('Bcc'), findsOneWidget);
      await dropOn(tester, gesture, tester.getCenter(name('Bcc')));

      expect(name('Bcc'), findsOneWidget);
      expect(holds(tester, 'Bcc'), 'Dana Levi <dana@example.com>');
      expect(holds(tester, 'To'), 'sam@example.com');
    });

    testWidgets('dropped nowhere, stays put, and Bcc goes again',
        (tester) async {
      await open(tester, draft(to: const [dana, sam]));

      final gesture = await pickUp(tester, 'Dana Levi');
      await dropOn(tester, gesture, const Offset(450, 1000));

      expect(name('Bcc'), findsNothing);
      expect(holds(tester, 'To'),
          'Dana Levi <dana@example.com>, sam@example.com');
    });

    testWidgets('onto a line that has them already, leaves one',
        (tester) async {
      await open(tester, draft(to: const [dana, sam], cc: const [dana]));

      final gesture = await pickUp(tester, 'sam@example.com');
      await dropOn(tester, gesture, tester.getCenter(name('Cc')));
      final again = await pickUp(tester, 'Dana Levi');
      await dropOn(tester, again, tester.getCenter(name('Cc')));

      expect(holds(tester, 'To'), '');
      expect(holds(tester, 'Cc'),
          'Dana Levi <dana@example.com>, sam@example.com');
    });
  });

  group('the menu', () {
    Future<void> menuOf(WidgetTester tester, String person) async {
      await tester.tap(find.text(person));
      await tester.pumpAndSettle();
    }

    testWidgets('has the address, and the other lines to move to',
        (tester) async {
      await open(tester, draft(to: const [dana]));
      await menuOf(tester, 'Dana Levi');

      expect(find.text('dana@example.com'), findsOneWidget);
      expect(find.text('Move to To'), findsNothing);
      expect(find.text('Move to Cc'), findsOneWidget);
      expect(find.text('Move to Bcc'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Copy address'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('Move to Bcc shows Bcc, with them on it', (tester) async {
      await open(tester, draft(to: const [dana, sam]));
      await menuOf(tester, 'Dana Levi');

      await tester.tap(find.text('Move to Bcc'));
      await tester.pumpAndSettle();

      expect(name('Bcc'), findsOneWidget);
      expect(holds(tester, 'Bcc'), 'Dana Levi <dana@example.com>');
      expect(holds(tester, 'To'), 'sam@example.com');
    });

    testWidgets('Edit puts them back in the field, to be typed over',
        (tester) async {
      await open(tester, draft(to: const [dana, sam]));
      await menuOf(tester, 'Dana Levi');

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      final to = tester.widget<TextField>(field('To'));
      expect(to.controller!.text, 'Dana Levi <dana@example.com>');
      expect(to.focusNode!.hasFocus, isTrue);
      expect(find.text('Dana Levi'), findsNothing, reason: 'no bubble now');
      expect(holds(tester, 'To'),
          'sam@example.com, Dana Levi <dana@example.com>');
    });

    testWidgets('Copy address copies it', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await open(tester, draft(to: const [dana]));
      await menuOf(tester, 'Dana Levi');

      await tester.tap(find.text('Copy address'));
      await tester.pumpAndSettle();

      expect(copied, 'dana@example.com');
      expect(find.text('Address copied.'), findsOneWidget);
      expect(holds(tester, 'To'), 'Dana Levi <dana@example.com>');
    });

    testWidgets('Remove takes them off', (tester) async {
      await open(tester, draft(to: const [dana, sam]));
      await menuOf(tester, 'Dana Levi');

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(find.text('Dana Levi'), findsNothing);
      expect(holds(tester, 'To'), 'sam@example.com');
    });
  });

  testWidgets("a line that does not fold, a group's people, shows everyone, "
      'and has nowhere to move them', (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final people = TextEditingController(text: formatAddresses(many));
    addTearDown(people.dispose);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              RecipientField(
                label: 'People',
                controller: people,
                enabled: true,
                folds: false,
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(more(), findsNothing);
    for (final p in many) {
      expect(find.text(p.name!), findsOneWidget);
    }

    await tester.tap(find.text('Person 03'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Move to'), findsNothing);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(parseAddresses(people.text).map((p) => p.name),
        isNot(contains('Person 03')));
    expect(parseAddresses(people.text), hasLength(19));
  });
}
