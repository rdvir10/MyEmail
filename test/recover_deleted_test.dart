import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/folder_tree/recover_deleted_screen.dart';

/// Recover Deleted Items: mail emptied out of a Microsoft account's Deleted
/// Items, which Exchange keeps for a few weeks, put back in the Inbox.
void main() {
  RecoverableMessage gone(String id, {int day = 1, String subject = 'Gone'}) =>
      RecoverableMessage(
        id: id,
        subject: '$subject $id',
        from: const MailAddress(email: 'dana@example.com', name: 'Dana'),
        received: DateTime(2026, 10, day),
        deletedOn: DateTime(2026, 10, 20),
      );

  test('a Gmail account has none: its Trash keeps mail in sight', () {
    expect(SampleMailEngine().canRecoverDeleted('acct-personal'), isFalse);
  });

  testWidgets('lists what was emptied, newest first, and puts it back',
      (tester) async {
    final engine = _Microsoft();
    const account = _Microsoft.account;
    engine.recoverable[account] = [
      gone('1', day: 3, subject: 'Older'),
      gone('2', day: 9, subject: 'Newer'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          mailEngineProvider.overrideWithValue(engine),
        ],
        child: const MaterialApp(
          home: RecoverDeletedScreen(accountId: account),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final subjects = [
      for (final t in tester.widgetList<Text>(find.textContaining('Older')))
        t.data,
      for (final t in tester.widgetList<Text>(find.textContaining('Newer')))
        t.data,
    ];
    expect(subjects, containsAll(['Older 1', 'Newer 2']));
    expect(
      tester.getTopLeft(find.text('Newer 2')).dy,
      lessThan(tester.getTopLeft(find.text('Older 1')).dy),
    );

    await tester.tap(find.text('Older 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recover-restore')));
    await tester.pumpAndSettle();

    expect(find.text('Restored to the Inbox.'), findsOneWidget);
    expect(find.text('Older 1'), findsNothing);
    expect(engine.recoverable[account]!.map((m) => m.id), ['2']);
  });

  testWidgets('says when there is nothing to recover', (tester) async {
    final engine = _Microsoft();
    const account = _Microsoft.account;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          mailEngineProvider.overrideWithValue(engine),
        ],
        child: const MaterialApp(
          home: RecoverDeletedScreen(accountId: account),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing to recover'), findsOneWidget);
  });
}

/// The sample engine, with its Projects account taken for a Microsoft one.
class _Microsoft extends SampleMailEngine {
  static const account = 'acct-side';

  @override
  bool canRecoverDeleted(String accountId) => accountId == account;
}
