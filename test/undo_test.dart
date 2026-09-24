import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_actions.dart';

/// Taking a delete or a move back.
///
/// A delete is a move into Trash, so both are undone the same way: the
/// messages go back to the folder they came from. The ids used are the ones
/// the server gave them on the way out, because the ones the list was
/// holding stopped resolving the moment they moved.
void main() {
  group('what the engine reports', () {
    late SampleMailEngine engine;
    late MailFolder inbox;
    late MailFolder trash;

    setUp(() async {
      engine = SampleMailEngine();
      await engine.loadAccounts();
      final folders = await engine.loadFolders('acct-personal');
      inbox = folders.firstWhere((f) => f.role == FolderRole.inbox);
      trash = folders.firstWhere((f) => f.role == FolderRole.deleted);
    });

    test('a delete says where the message went, and it goes back', () async {
      final before = await engine.loadMessages(inbox.id);
      final subject = before.first.subject;

      final moves = await engine.deleteMessages([before.first.id]);

      expect(moves, hasLength(1));
      expect(moves.single.fromFolderId, inbox.id);
      expect(moves.single.toFolderId, trash.id);
      expect(canUndoAll(moves, 1), isTrue);
      expect(
        (await engine.loadMessages(inbox.id)).map((m) => m.id),
        isNot(contains(before.first.id)),
      );

      await engine.moveMessages(
        moves.single.movedIds,
        moves.single.fromFolderId,
      );

      expect((await engine.loadMessages(inbox.id)).first.subject, subject);
    });

    test('a move says the same, both ways', () async {
      final before = await engine.loadMessages(inbox.id);

      final there = await engine.moveMessages([before.first.id], trash.id);
      final back = await engine.moveMessages(
        there.single.movedIds,
        there.single.fromFolderId,
      );

      expect(there.single.toFolderId, trash.id);
      expect(back.single.toFolderId, inbox.id);
      expect((await engine.loadMessages(inbox.id)), hasLength(before.length));
    });

    test('a delete from Trash has nothing to put back', () async {
      // Already there, so it goes for good. The empty entry is how the
      // caller knows not to offer Undo for something it cannot do.
      final inTrash = await engine.loadMessages(trash.id);
      if (inTrash.isEmpty) {
        final fromInbox = await engine.loadMessages(inbox.id);
        await engine.deleteMessages([fromInbox.first.id]);
      }
      final doomed = (await engine.loadMessages(trash.id)).first;

      final moves = await engine.deleteMessages([doomed.id]);

      expect(moves.single.movedIds, isEmpty);
      expect(canUndoAll(moves, 1), isFalse);
    });

    test('several folders at once come back one report each', () async {
      final fromInbox = await engine.loadMessages(inbox.id);
      final folders = await engine.loadFolders('acct-personal');
      final other = folders.firstWhere(
        (f) => f.role == FolderRole.user && f.id != inbox.id,
      );
      final fromOther = await engine.loadMessages(other.id);

      final moves = await engine.deleteMessages(
        [fromInbox.first.id, fromOther.first.id],
      );

      expect(moves, hasLength(2));
      expect(
        moves.map((m) => m.fromFolderId),
        containsAll(<String>[inbox.id, other.id]),
      );
      expect(canUndoAll(moves, 2), isTrue);
    });
  });

  group('offering it', () {
    test('a batch only half accounted for is not offered', () {
      // Half moved to Trash, half deleted for good. Putting back one of two
      // while the snackbar says Undo would be worse than no Undo.
      const moves = [
        MessageMove(
          fromFolderId: 'a:INBOX',
          toFolderId: 'a:Trash',
          movedIds: ['a:Trash#1'],
        ),
        MessageMove(
          fromFolderId: 'a:Trash',
          toFolderId: 'a:Trash',
          movedIds: [],
        ),
      ];

      expect(canUndoAll(moves, 2), isFalse);
    });

    test('a server that will not say where a message landed is not offered',
        () {
      // IMAP without UIDPLUS: the move works, the new UID is never reported.
      const moves = [
        MessageMove(
          fromFolderId: 'a:INBOX',
          toFolderId: 'a:Trash',
          movedIds: [],
        ),
      ];

      expect(canUndoAll(moves, 1), isFalse);
    });

    test('nothing at all is not offered', () {
      expect(canUndoAll(const [], 0), isFalse);
    });
  });

  group('on screen', () {
    Future<(ProviderContainer, String, String)> setUpFolders(
      WidgetTester tester, {
      MailEngine? engine,
    }) async {
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        if (engine != null) mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      // The sample engine's latency is a real delay, which the fake clock in
      // a widget test will not run out on its own.
      final folders = await tester.runAsync(
        () => c.read(foldersProvider.future),
      );
      final list = folders!['acct-personal']!;
      return (
        c,
        list.firstWhere((f) => f.role == FolderRole.inbox).id,
        list.firstWhere((f) => f.role == FolderRole.deleted).id,
      );
    }

    Future<void> show(
      WidgetTester tester,
      ProviderContainer c,
      String folderId,
    ) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: _DeleteHarness(folderId: folderId)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('deleting offers Undo, and Undo puts the message back',
        (tester) async {
      final (c, inbox, _) = await setUpFolders(tester);
      await show(tester, c, inbox);
      final subject = c.read(messagesProvider(inbox)).value!.first.subject;
      expect(find.text('top $subject'), findsOneWidget);

      await tester.tap(find.text('Delete the first'));
      await tester.pumpAndSettle();

      expect(find.text('Message deleted'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      expect(find.text('top $subject'), findsNothing);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Message put back'), findsOneWidget);
      expect(find.text('top $subject'), findsOneWidget);
    });

    testWidgets('an undo that fails part way still shows what came back',
        (tester) async {
      // Across two accounts the first can be put back and the second fail.
      // The lists were only refreshed on success, so the message restored
      // stayed missing until a pull.
      final (c, inbox, _) =
          await setUpFolders(tester, engine: _UndoThenFail());
      await show(tester, c, inbox);
      final subject = c.read(messagesProvider(inbox)).value!.first.subject;

      await tester.tap(find.text('Delete the first'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not undo'), findsOneWidget);
      expect(find.text('top $subject'), findsOneWidget);
    });

    testWidgets('a delete that cannot be taken back offers nothing',
        (tester) async {
      final (c, inbox, trash) = await setUpFolders(tester);
      // Put one in Trash first, so there is something there to delete.
      await show(tester, c, inbox);
      await tester.tap(find.text('Delete the first'));
      await tester.pumpAndSettle();

      await show(tester, c, trash);
      await tester.tap(find.text('Delete the first'));
      await tester.pumpAndSettle();

      expect(find.text('Message deleted'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });
  });
}

/// A list with one button on it, so the snackbar and its link can be tested
/// without going through a swipe, a menu or a keyboard.
class _DeleteHarness extends ConsumerWidget {
  const _DeleteHarness({required this.folderId});

  final String folderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(messagesProvider(folderId));
    return Scaffold(
      body: messages.when(
        loading: () => const Center(child: Text('loading')),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (list.isNotEmpty) Text('top ${list.first.subject}'),
            if (list.isNotEmpty)
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => MessageActions(ref, folderId)
                      .delete(context, [list.first]),
                  child: const Text('Delete the first'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Puts everything back, then fails, as an undo does whose second account
/// stopped answering after the first had been restored.
class _UndoThenFail extends SampleMailEngine {
  @override
  Future<void> undoMoves(List<MessageMove> moves) async {
    await super.undoMoves(moves);
    throw const ConnectionFailed('The other account did not answer.');
  }
}
