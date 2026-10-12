import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/contacts/device_contacts.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/address_suggestions.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/contact_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/messages/person_card.dart';
import 'package:myemail/ui/messages/reading_pane.dart';

import 'fakes/fake_webview.dart';

/// A tap on someone on a message, the sender or anyone it went to, opens
/// their card: Add to contacts, or Open contact for someone already in the
/// phone's contacts, New email and Copy address.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  const dana = MailAddress(email: 'dana@example.com', name: 'Dana Levi');
  const sam = MailAddress(email: 'sam@example.com', name: 'Sam Cohen');

  MailMessage message({MailAddress from = dana}) => MailMessage(
        id: 'acct-personal:INBOX#1',
        accountId: 'acct-personal',
        folderId: 'acct-personal:INBOX',
        uid: 1,
        subject: 'Numbers for Thursday',
        preview: '',
        from: from,
        to: const [MailAddress(email: 'personal@example.com', name: 'Ron')],
        cc: const [sam],
        date: DateTime(2026, 10, 12, 9, 30),
        isRead: true,
      );

  late FakeDeviceContacts contacts;

  setUp(() => contacts = FakeDeviceContacts());

  Future<void> pump(WidgetTester tester, {MailMessage? m}) async {
    final shown = m ?? message();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      deviceContactsProvider.overrideWithValue(contacts),
      messageBodyProvider(shown.id)
          .overrideWith((ref) async => const MailBody(text: 'Hello')),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(body: ReadingPane(message: shown, onPopOut: () {})),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// The sender's name in the header, not on a card.
  Finder header(String text) => find.descendant(
        of: find.byType(ReadingPane),
        matching: find.text(text),
      );

  Finder onCard(String text) => find.descendant(
        of: find.byType(PersonCard),
        matching: find.text(text),
      );

  Future<void> openCard(WidgetTester tester, Finder target) async {
    await tester.tap(target.first);
    await tester.pumpAndSettle();
  }

  testWidgets('tapping the sender shows who they are and what can be done',
      (tester) async {
    await pump(tester);

    await openCard(tester, header('Dana Levi'));

    expect(find.byType(PersonCard), findsOneWidget);
    expect(onCard('Dana Levi'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PersonCard),
        matching: find.text('dana@example.com', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(onCard('Add to contacts'), findsOneWidget);
    expect(onCard('New email'), findsOneWidget);
    expect(onCard('Copy address'), findsOneWidget);
    expect(onCard('Open contact'), findsNothing);
  });

  testWidgets('the sender\'s picture and address open it too', (tester) async {
    await pump(tester);

    await openCard(
      tester,
      find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byType(CircleAvatar),
      ),
    );
    expect(find.byType(PersonCard), findsOneWidget);
    Navigator.of(tester.element(find.byType(PersonCard))).pop();
    await tester.pumpAndSettle();

    await openCard(tester, header('dana@example.com'));
    expect(find.byType(PersonCard), findsOneWidget);
  });

  testWidgets('Add to contacts hands the name and address to the contacts app',
      (tester) async {
    await pump(tester);
    await openCard(tester, header('Dana Levi'));

    await tester.tap(onCard('Add to contacts'));
    await tester.pumpAndSettle();

    expect(contacts.added.single.name, 'Dana Levi');
    expect(contacts.added.single.email, 'dana@example.com');
    expect(find.byType(PersonCard), findsNothing, reason: 'the card closes');
  });

  testWidgets('someone already in your contacts is opened, not added again',
      (tester) async {
    contacts = FakeDeviceContacts(
      granted: true,
      people: const [
        // Filed under a name of its own, and an address the case of which
        // is not the mail's: still the same person.
        AddressSuggestion(email: 'DANA@example.com', name: 'Dana L.'),
      ],
    );
    await pump(tester);
    await openCard(tester, header('Dana Levi'));

    expect(onCard('In your contacts as Dana L.'), findsOneWidget);
    expect(onCard('Add to contacts'), findsNothing);
    await tester.tap(onCard('Open contact'));
    await tester.pumpAndSettle();

    expect(contacts.opened.single.name, 'Dana L.');
    expect(contacts.added, isEmpty);
  });

  testWidgets('without leave to read the contacts, Add is offered and '
      'nothing is asked', (tester) async {
    contacts = FakeDeviceContacts(
      people: const [AddressSuggestion(email: 'dana@example.com')],
    );
    await pump(tester);
    await openCard(tester, header('Dana Levi'));

    expect(onCard('Add to contacts'), findsOneWidget);
    expect(find.textContaining('In your contacts'), findsNothing);
    expect(contacts.asked, 0,
        reason: 'the recipient fields ask, once; a card does not nag');
  });

  testWidgets('a phone with no contacts app says so', (tester) async {
    contacts.hasApp = false;
    await pump(tester);
    await openCard(tester, header('Dana Levi'));

    await tester.tap(onCard('Add to contacts'));
    await tester.pumpAndSettle();

    expect(find.text('No contacts app to add them to.'), findsOneWidget);
  });

  testWidgets('Copy address puts the address on the clipboard',
      (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await pump(tester);
    await openCard(tester, header('Dana Levi'));

    await tester.tap(onCard('Copy address'));
    await tester.pumpAndSettle();

    final set = calls.singleWhere((c) => c.method == 'Clipboard.setData');
    expect((set.arguments as Map)['text'], 'dana@example.com');
    expect(find.text('Address copied.'), findsOneWidget);
  });

  testWidgets('New email writes to them, from the account the message came to',
      (tester) async {
    await pump(tester);
    await openCard(tester, header('Dana Levi'));

    await tester.tap(onCard('New email'));
    await tester.pumpAndSettle();

    final draft = tester.widget<ComposeScreen>(find.byType(ComposeScreen)).draft;
    expect(draft.to, [dana]);
    expect(draft.accountId, 'acct-personal');
    expect(draft.originalMessageId, isNull, reason: 'a new message, not a reply');
  });

  testWidgets('anyone the message went to opens their card from the list',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    await openCard(tester, header('Sam Cohen'));
    expect(onCard('Sam Cohen'), findsOneWidget);
    await tester.tap(onCard('Add to contacts'));
    await tester.pumpAndSettle();

    expect(contacts.added.single.email, 'sam@example.com');
  });

  testWidgets('a sender with no name is their address', (tester) async {
    await pump(
      tester,
      m: message(from: const MailAddress(email: 'billing@example.com')),
    );
    await openCard(tester, header('billing@example.com'));

    expect(onCard('billing@example.com'), findsOneWidget);
    await tester.tap(onCard('Add to contacts'));
    await tester.pumpAndSettle();

    expect(contacts.added.single.name, isNull);
    expect(contacts.added.single.email, 'billing@example.com');
  });

  group('the contacts, without a phone', () {
    test('find someone by their address, whatever its case', () async {
      final book = FakeDeviceContacts(
        granted: true,
        people: const [AddressSuggestion(email: 'Dana@Example.com')],
      );

      expect(await book.find(' dana@example.com '), isNotNull);
      expect(await book.find('dana@example.org'), isNull);
    });

    test('find nobody where they may not be read', () async {
      final book = FakeDeviceContacts(
        people: const [AddressSuggestion(email: 'dana@example.com')],
      );

      expect(await book.find('dana@example.com'), isNull);
    });
  });
}
