import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/contacts/device_contacts.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/address_suggestions.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/contact_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';

import 'fakes/fake_webview.dart';

/// Typing a recipient offers people, from the address book and from mail.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late FakeDeviceContacts contacts;
  late MemoryUiStateStore uiState;

  setUp(() {
    contacts = FakeDeviceContacts(
      people: const [
        AddressSuggestion(email: 'ron@example.com', name: 'Ron Dvir'),
        AddressSuggestion(email: 'rosa@example.com', name: 'Rosa Lind'),
      ],
    );
    uiState = MemoryUiStateStore();
  });

  Draft draft({bool reply = false}) => Draft(
        accountId: 'acct-personal',
        kind: reply ? ComposeKind.reply : ComposeKind.newMessage,
        to: reply ? const [MailAddress(email: 'them@example.com')] : const [],
        cc: const [],
        bcc: const [],
        subject: '',
        htmlBody: '<p></p>',
        attachments: const [],
      );

  Future<ProviderContainer> open(
    WidgetTester tester, {
    bool reply = false,
    SampleMailEngine? engine,
  }) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = ProviderContainer(
      overrides: [
        mailEngineProvider.overrideWithValue(engine ?? SampleMailEngine()),
        deviceContactsProvider.overrideWithValue(contacts),
        uiStateStoreProvider.overrideWithValue(uiState),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: ComposeScreen(draft: draft(reply: reply))),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  /// The To field: the text field on the row whose name box says To.
  Finder toField() => find.descendant(
        of: find.ancestor(
          of: find.descendant(
            of: find.byWidgetPredicate((w) => w is SizedBox && w.width == 64),
            matching: find.text('To'),
          ),
          matching: find.byType(Row),
        ),
        matching: find.byType(TextField),
      );

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(toField(), text);
    // The suggestions are looked up after the keystroke, and the engine
    // answers after a short delay.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
  }

  group('with the address book allowed', () {
    setUp(() => contacts.granted = true);

    testWidgets('typing offers matching people', (tester) async {
      await open(tester);

      await type(tester, 'ro');

      expect(find.text('Ron Dvir'), findsOneWidget);
      expect(find.text('Rosa Lind'), findsOneWidget);
    });

    testWidgets('choosing one writes it in, with a comma for the next',
        (tester) async {
      await open(tester);
      await type(tester, 'ro');

      await tester.tap(find.text('Ron Dvir'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(toField());
      expect(field.controller?.text, 'Ron Dvir <ron@example.com>, ');
    });

    testWidgets('the second name is completed on its own', (tester) async {
      // The whole field is one name after another; choosing must not
      // throw away the ones already there.
      await open(tester);
      await type(tester, 'Rosa Lind <rosa@example.com>, ro');

      await tester.tap(find.text('Ron Dvir'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(toField());
      expect(
        field.controller?.text,
        'Rosa Lind <rosa@example.com>, Ron Dvir <ron@example.com>, ',
      );
    });
  });

  group('the permission', () {
    testWidgets('is asked for once, when a recipient field is first used',
        (tester) async {
      // A reply: its To is filled in, so nothing takes focus on opening. A
      // new message puts the cursor in To at once, which counts as use.
      await open(tester, reply: true);
      expect(contacts.asked, 0, reason: 'not before anyone types');

      await tester.tap(toField());
      await tester.pumpAndSettle();

      expect(contacts.asked, 1);
    });

    testWidgets('and not again after a refusal', (tester) async {
      // A dialog that comes back every message is a nag, and Android stops
      // showing it anyway. Settings has the switch for a change of mind.
      contacts.grantWhenAsked = false;
      await open(tester);

      await tester.tap(toField());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cc'));
      await tester.pumpAndSettle();

      expect(contacts.asked, 1);
    });

    testWidgets('refused, the mail history still suggests', (tester) async {
      contacts.grantWhenAsked = false;
      final c = await open(tester);
      // The sample engine makes a folder's mail up the first time the
      // folder is read, so the history is empty until an inbox has been
      // looked at; and it answers after a short delay, so real time has to
      // pass. On a device the cache already holds real mail. The engine is
      // asked directly: a provider future settled under real time would
      // hand the field a completion the fake clock never sees.
      final someone = (await tester.runAsync(() async {
        final engine = c.read(mailEngineProvider);
        final account = (await engine.loadAccounts()).first;
        for (final folder in await engine.loadFolders(account.id)) {
          if (folder.displayName == 'Inbox') await engine.loadMessages(folder.id);
        }
        return engine.recentAddresses();
      }))!
          .firstWhere((p) => !isNoReplyAddress(p.email));
      // The field read the history, empty, when it took focus on opening.
      c.invalidate(addressHistoryProvider);

      await type(tester, someone.email.substring(0, 3));

      expect(find.text('Ron Dvir'), findsNothing,
          reason: 'the address book was refused');
      expect(find.textContaining(someone.email), findsWidgets,
          reason: 'people already mailed are still offered');
    });
  });

  group('the list', () {
    testWidgets('waits for a letter to be typed', (tester) async {
      // A new message puts the cursor in To on opening. A list that came
      // up on its own covered Cc and Subject (2.83.0).
      await open(tester, engine: _Known());

      expect(find.text('Dana Levi'), findsNothing);
      expect(find.text('Omer Tal'), findsNothing);
    });

    testWidgets('closes at a tap anywhere else', (tester) async {
      await open(tester, engine: _Known());
      await type(tester, 'da');
      expect(find.text('Dana Levi'), findsOneWidget);

      // The field's own label, which takes no focus: the list closes for
      // the tap, not because the cursor went somewhere else.
      await tester.tap(find.text('To'));
      await tester.pumpAndSettle();
      expect(find.text('Dana Levi'), findsNothing);

      // And comes back with the next letter.
      await type(tester, 'dan');
      expect(find.text('Dana Levi'), findsOneWidget);

      // Low on the screen, in the body, well clear of the list.
      await tester.tapAt(const Offset(450, 1100));
      await tester.pumpAndSettle();
      expect(find.text('Dana Levi'), findsNothing);
    });

    testWidgets('but not straight after one is chosen', (tester) async {
      // The list would cover Subject just as that is where to go next.
      await open(tester, engine: _Known());
      await type(tester, 'da');

      await tester.tap(find.text('Dana Levi'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(toField());
      expect(field.controller?.text, 'Dana Levi <dana@example.com>, ');
      expect(find.text('Omer Tal'), findsNothing);
    });

    testWidgets('the arrow keys move through the list, Next takes it',
        (tester) async {
      await open(tester, engine: _Known());
      await type(tester, 'example');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(toField());
      expect(field.controller?.text, 'Omer Tal <omer@example.com>, ');
    });

    testWidgets('Esc closes the list and leaves the message open',
        (tester) async {
      await open(tester, engine: _Known());
      await type(tester, 'da');
      expect(find.text('Dana Levi'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Dana Levi'), findsNothing);
      expect(find.byType(ComposeScreen), findsOneWidget);
    });

    testWidgets('nobody already in the field is offered again',
        (tester) async {
      await open(tester, engine: _Known());

      await type(tester, 'Dana Levi <dana@example.com>, d');

      expect(find.text('Dana Levi'), findsNothing);
      expect(find.text('deals@shop.example'), findsOneWidget);
    });
  });

  group("the accounts' address books online", () {
    testWidgets('add who they find once typing pauses', (tester) async {
      final engine = _Known(online: const [
        AddressSuggestion(
          email: 'tyler@hadco.example',
          name: 'Tyler Lee',
          fromContacts: true,
        ),
      ]);
      await open(tester, engine: engine);

      await type(tester, 'ty');
      expect(find.text('Tyler Lee'), findsNothing, reason: 'not asked yet');

      await tester.pump(RecipientSuggester.onlineDelay);
      await tester.pumpAndSettle();

      expect(find.text('Tyler Lee'), findsOneWidget);
      expect(engine.searched, ['ty']);
    });

    testWidgets('are not asked for letters typed over', (tester) async {
      final engine = _Known();
      await open(tester, engine: engine);

      await tester.enterText(toField(), 't');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(toField(), 'ty');
      await tester.pump(RecipientSuggester.onlineDelay);
      await tester.pumpAndSettle();

      expect(engine.searched, ['ty']);
    });
  });
}

/// A mail history with two people written to and a shop that only writes,
/// and online address books that find whoever [online] holds.
class _Known extends SampleMailEngine {
  _Known({this.online = const []});

  final List<AddressSuggestion> online;
  final searched = <String>[];

  @override
  Future<List<AddressSuggestion>> recentAddresses() async => const [
        AddressSuggestion(
          email: 'dana@example.com',
          name: 'Dana Levi',
          timesSeen: 5,
          timesSent: 3,
          weight: 2,
        ),
        AddressSuggestion(
          email: 'omer@example.com',
          name: 'Omer Tal',
          timesSeen: 2,
          timesSent: 1,
          weight: 1,
        ),
        AddressSuggestion(email: 'deals@shop.example', timesSeen: 90),
      ];

  @override
  Future<List<AddressSuggestion>> searchPeople(String query) async {
    searched.add(query);
    return [
      for (final p in online)
        if (suggestionMatches(p, query.toLowerCase())) p,
    ];
  }
}
