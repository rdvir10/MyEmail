import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/quick_step.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/quick_steps.dart';
import 'package:myemail/ui/folder_tree/folder_tree_panel.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/quick_steps/quick_steps_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';

QuickStep _step(
  String name,
  List<QuickStepAction> actions, {
  String id = 'qs-1',
}) =>
    QuickStep(id: id, name: name, actions: actions);

void main() {
  group('QuickStep model', () {
    test('actions after a move or delete are dropped as unreachable', () {
      final step = _step('File', const [
        QuickStepAction(QuickStepActionType.markRead),
        QuickStepAction(QuickStepActionType.moveTo, folderId: 'a:Travel'),
        QuickStepAction(QuickStepActionType.flag),
      ]);
      expect(step.actions, hasLength(3));
      expect(
        step.effectiveActions.map((a) => a.type),
        [QuickStepActionType.markRead, QuickStepActionType.moveTo],
      );
    });

    test('validity needs a name, an action, and a folder where required', () {
      expect(_step('', const [QuickStepAction(QuickStepActionType.flag)]).isValid,
          isFalse);
      expect(_step('x', const []).isValid, isFalse);
      expect(
        _step('x', const [QuickStepAction(QuickStepActionType.moveTo)]).isValid,
        isFalse,
      );
      expect(
        _step('x', const [
          QuickStepAction(QuickStepActionType.moveTo, folderId: 'a:T')
        ]).isValid,
        isTrue,
      );
    });

    test('JSON round-trips', () {
      final step = _step('File and read', const [
        QuickStepAction(QuickStepActionType.markRead),
        QuickStepAction(QuickStepActionType.moveTo, folderId: 'a:Travel'),
      ]);
      final back = QuickStep.fromJson(step.toJson());
      expect(back.id, step.id);
      expect(back.name, step.name);
      expect(back.actions, step.actions);
    });
  });

  group('QuickSteps notifier', () {
    ProviderContainer container(UiStateStore store) {
      final c = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('steps persist and come back', () async {
      final store = MemoryUiStateStore();
      final c = container(store);
      c.read(quickStepsProvider.notifier).add(
            _step('Archive it', const [
              QuickStepAction(QuickStepActionType.markRead),
              QuickStepAction(QuickStepActionType.moveTo, folderId: 'a:Travel'),
            ]),
          );
      await Future<void>.delayed(Duration.zero);
      expect(store.readString(UiStateKeys.quickSteps), contains('Archive it'));

      final fresh = container(store);
      expect(fresh.read(quickStepsProvider).single.name, 'Archive it');
    });

    test('corrupt stored JSON yields no steps rather than crashing', () async {
      final store = MemoryUiStateStore();
      await store.writeString(UiStateKeys.quickSteps, 'not json');
      expect(container(store).read(quickStepsProvider), isEmpty);
    });

    test('reorder moves a step to the given position', () {
      final c = container(MemoryUiStateStore());
      final n = c.read(quickStepsProvider.notifier);
      for (final name in ['a', 'b', 'c']) {
        n.add(_step(name, const [QuickStepAction(QuickStepActionType.flag)],
            id: 'qs-$name'));
      }
      n.reorder(0, 2);
      expect(c.read(quickStepsProvider).map((s) => s.name), ['b', 'c', 'a']);
    });
  });

  group('folder changes reach Quick Steps', () {
    test('a renamed folder is followed; a deleted one drops the step',
        () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(foldersProvider.future);

      c.read(quickStepsProvider.notifier)
        ..add(_step('To receipts', const [
          QuickStepAction(QuickStepActionType.moveTo,
              folderId: 'acct-personal:Finance/Receipts'),
        ], id: 'qs-move'))
        ..add(_step('Just flag',
            const [QuickStepAction(QuickStepActionType.flag)], id: 'qs-flag'));

      await c
          .read(foldersProvider.notifier)
          .rename('acct-personal:Finance', 'Money');
      expect(
        c.read(quickStepsProvider).first.actions.single.folderId,
        'acct-personal:Money/Receipts',
      );

      await c.read(foldersProvider.notifier).delete('acct-personal:Money');
      final left = c.read(quickStepsProvider);
      expect(left.map((s) => s.id), ['qs-flag'],
          reason: 'a step pointing at a deleted folder is removed',
      );
    });
  });

  group('running a Quick Step', () {
    test('applies each action in order and stops after the move', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(foldersProvider.future);
      const listId = 'acct-personal:INBOX';
      final messages = await container.read(messagesProvider(listId).future);
      final target = messages.firstWhere((m) => !m.isRead);
      final moves = <String>[];

      await runQuickStep(
        step: _step('File', const [
          QuickStepAction(QuickStepActionType.markRead),
          QuickStepAction(QuickStepActionType.flag),
          QuickStepAction(QuickStepActionType.moveTo,
              folderId: 'acct-personal:Travel'),
          QuickStepAction(QuickStepActionType.delete),
        ]),
        notifier: container.read(messagesProvider(listId).notifier),
        message: target,
        onMoved: moves.add,
      );

      final inbox = container.read(messagesProvider(listId)).value!;
      expect(inbox.map((m) => m.id), isNot(contains(target.id)));
      expect(moves, ['acct-personal:Travel']);

      final travel =
          await container.read(messagesProvider('acct-personal:Travel').future);
      final moved = travel.firstWhere((m) => m.subject == target.subject);
      expect(moved.isRead, isTrue, reason: 'marked read before the move');
      expect(moved.isFlagged, isTrue);
      expect(moved.folderId, 'acct-personal:Travel',
          reason: 'the delete after the move never ran');
    });
  });

  group('Quick Steps UI', () {
    Widget app() => const ProviderScope(child: MaterialApp(home: AppShell()));

    void wide(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('the screen explains itself when empty and creates a step',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // The ribbon has a Settings button too; this is the tree's route.
      await tester.tap(find.descendant(
        of: find.byType(FolderTreePanel),
        matching: find.text('Settings'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quick Steps'));
      await tester.pumpAndSettle();
      expect(find.textContaining('one tap'), findsOneWidget);

      await tester.tap(find.text('New'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Read it');
      await tester.tap(find.text('Add action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as read').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Read it'), findsOneWidget);
      expect(find.text('Mark as read'), findsOneWidget,
          reason: 'the summary describes the chain');
    });

    testWidgets('a saved step appears in the message menu and runs',
        (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppShell)),
      );
      container.read(quickStepsProvider.notifier).add(
            _step('Flag it', const [
              QuickStepAction(QuickStepActionType.flag),
            ]),
          );
      await tester.pumpAndSettle();

      final tile =
          tester.widget<MessageTile>(find.byType(MessageTile).first);
      // The menu is on the right button; a long press ticks instead.
      await tester.tap(find.byType(MessageTile).first, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Flag it'), findsOneWidget);

      await tester.tap(find.text('Flag it'));
      await tester.pumpAndSettle();

      expect(find.text('Flag it applied'), findsOneWidget);
      final after = tester
          .widgetList<MessageTile>(find.byType(MessageTile))
          .firstWhere((t) => t.message.id == tile.message.id);
      expect(after.message.isFlagged, isTrue);
    });
  });

  test('describeQuickStep names the folder and marks a missing one', () {
    final step = _step('x', const [
      QuickStepAction(QuickStepActionType.markRead),
      QuickStepAction(QuickStepActionType.moveTo, folderId: 'a:Gone'),
    ]);
    expect(describeQuickStep(step, const {}),
        'Mark as read, then Move to (missing folder)');
  });
}
