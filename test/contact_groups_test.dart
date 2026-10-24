import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/address_suggestions.dart';
import 'package:myemail/domain/contact_group.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/compose_providers.dart';
import 'package:myemail/state/contact_groups.dart';
import 'package:myemail/state/contact_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/settings/contact_groups_screen.dart';

import 'fakes/fake_webview.dart';

/// Contact groups typed into To like one person, and an address taken out
/// of the suggestions.
void main() {
  const team = ContactGroup(
    id: 'g1',
    name: 'Site team',
    members: [
      MailAddress(email: 'dana@example.com', name: 'Dana Levi'),
      MailAddress(email: 'sam@example.com'),
    ],
  );

  test('a group is kept as written, and chosen it writes everyone in', () {
    expect(ContactGroup.fromJson(team.toJson()), team);
    expect(ContactGroup.fromJson('garbage'), isNull);
    final suggestion = AddressSuggestion.group(team);
    expect(suggestion.isGroup, isTrue);
    expect(
      completeLastRecipient('ron@example.com, si', suggestion),
      'ron@example.com, Dana Levi <dana@example.com>, sam@example.com, ',
    );
    expect(parseAddresses(team.formatted).map((a) => a.email),
        ['dana@example.com', 'sam@example.com']);
  });

  group('the suggestions', () {
    late ProviderContainer c;

    setUp(() {
      c = ProviderContainer(
        overrides: [
          mailEngineProvider.overrideWithValue(_History()),
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        ],
      );
      addTearDown(c.dispose);
    });

    Future<List<AddressSuggestion>> suggest(String query) =>
        c.read(recipientSuggesterProvider).suggest(query).first;

    test('a group whose name has what was typed comes first', () async {
      c.read(contactGroupsProvider.notifier).save(team);
      final found = await suggest('site');
      expect(found.first.isGroup, isTrue);
      expect(found.first.name, 'Site team');
    });

    test('an address forgotten is not suggested, until written to again',
        () async {
      expect((await suggest('typo')).map((s) => s.email),
          contains('typo@exmaple.com'));

      c.read(forgottenAddressesProvider.notifier).forget('Typo@Exmaple.com');
      expect((await suggest('typo')).map((s) => s.email),
          isNot(contains('typo@exmaple.com')));

      await sendWith(
        read: c.read,
        invalidate: c.invalidate,
        alive: () => false,
        draft: const Draft(
          accountId: 'acct-personal',
          kind: ComposeKind.newMessage,
          to: [MailAddress(email: 'typo@exmaple.com')],
          subject: 'On purpose',
        ),
      );
      expect(c.read(forgottenAddressesProvider), isEmpty);
    });
  });

  testWidgets('Settings: a new group, named and filled in', (tester) async {
    FakeWebViewPlatform.install();
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ContactGroupsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Home');
    await tester.enterText(
      fields.at(1),
      'dana@example.com, sam@example.com, dana@example.com',
    );
    await tester.tap(find.byKey(const ValueKey('save-group')));
    await tester.pumpAndSettle();

    final saved = container.read(contactGroupsProvider).single;
    expect(saved.name, 'Home');
    expect(saved.members.map((m) => m.email),
        ['dana@example.com', 'sam@example.com'],
        reason: 'each person once');
    expect(find.text('Home'), findsOneWidget);
  });
}

/// The sample engine, with a typo in its mail history.
class _History extends SampleMailEngine {
  @override
  Future<List<AddressSuggestion>> recentAddresses() async => const [
        AddressSuggestion(email: 'typo@exmaple.com', timesSeen: 1, timesSent: 1),
        AddressSuggestion(email: 'dana@example.com', name: 'Dana', timesSeen: 3),
      ];
}
