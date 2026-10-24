import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/follow_up.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/quick_step.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/quick_steps.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/quick_steps/quick_steps_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/app_shortcuts.dart';

import 'fakes/fake_webview.dart';

/// More Quick Steps (#38): Archive, Flag for a day, Forward to, Reply then
/// delete, New message to and Meeting from it, and Ctrl+Shift with a step's
/// number.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  QuickStep step(List<QuickStepAction> actions, {String name = 'Step'}) =>
      QuickStep(id: 'qs-1', name: name, actions: actions);

  group('the new actions', () {
    test('keep what they need, and say what they do', () {
      final s = step(const [
        QuickStepAction(QuickStepActionType.forwardTo,
            address: 'boss@example.com'),
        QuickStepAction(QuickStepActionType.flagFor,
            when: FollowUpChoice.tomorrow),
        QuickStepAction(QuickStepActionType.archive),
      ]);

      final back = QuickStep.fromJson(s.toJson());
      expect(back.actions, s.actions);
      expect(
        [for (final a in s.actions) a.describe((id) => id)],
        ['Forward to boss@example.com', 'Flag for Tomorrow', 'Archive'],
      );
      expect(s.isValid, isTrue);
      expect(
        step(const [QuickStepAction(QuickStepActionType.forwardTo)]).isValid,
        isFalse,
        reason: 'nobody to forward to',
      );
      expect(
        step(const [QuickStepAction(QuickStepActionType.flagFor)]).isValid,
        isFalse,
      );
    });

    test('Archive and Reply then delete end a step, as a move does', () {
      final s = step(const [
        QuickStepAction(QuickStepActionType.replyDelete),
        QuickStepAction(QuickStepActionType.markRead),
      ]);
      expect(s.effectiveActions.single.type, QuickStepActionType.replyDelete);
      expect(QuickStepActionType.archive.isTerminal, isTrue);
    });

    test('a step with a day this build does not know is skipped, not the rest',
        () {
      final steps = QuickStep.listFromJson('['
          '{"id":"a","name":"Later","actions":[{"type":"flagFor","when":"someday"}]},'
          '{"id":"b","name":"Read","actions":[{"type":"markRead"}]}'
          ']');
      expect(steps!.map((s) => s.name), ['Read']);
    });
  });

  group('running them', () {
    late SampleMailEngine engine;
    late ProviderContainer c;
    late List<({ComposeKind kind, MailMessage? original, List<MailAddress> to})>
        composed;
    late List<MailMessage> meetings;
    late List<({MailMessage message, DateTime? due})> remembered;
    const listId = 'acct-personal:INBOX';

    setUp(() async {
      engine = SampleMailEngine();
      c = ProviderContainer(overrides: [
        mailEngineProvider.overrideWithValue(engine),
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ]);
      addTearDown(c.dispose);
      await c.read(foldersProvider.future);
      await c.read(messagesProvider(listId).future);
      composed = [];
      meetings = [];
      remembered = [];
    });

    QuickStepHooks hooks() => QuickStepHooks(
          archiveTarget: (accountId) => '$accountId:[Gmail]/All Mail',
          compose: (kind, original, to) async =>
              composed.add((kind: kind, original: original, to: to)),
          meeting: (message) async => meetings.add(message),
          rememberDue: (message, due) =>
              remembered.add((message: message, due: due)),
        );

    Future<MailMessage> run(List<QuickStepAction> actions,
        {QuickStepHooks? with_}) async {
      final message = c.read(messagesProvider(listId)).value!.first;
      await runQuickStep(
        step: step(actions),
        notifier: c.read(messagesProvider(listId).notifier),
        message: message,
        engine: engine,
        hooks: with_ ?? hooks(),
      );
      return message;
    }

    test('Archive files it where the account archives', () async {
      final message =
          await run(const [QuickStepAction(QuickStepActionType.archive)]);

      expect(c.read(messagesProvider(listId)).value!.map((m) => m.id),
          isNot(contains(message.id)));
      final all = await engine.loadMessages('acct-personal:[Gmail]/All Mail');
      expect(all.any((m) => m.subject == message.subject), isTrue);
    });

    test('Flag for flags it for that day, kept where the account keeps none',
        () async {
      final message = await run(const [
        QuickStepAction(QuickStepActionType.flagFor,
            when: FollowUpChoice.tomorrow),
      ]);

      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      expect(engine.followUps.single.ids, [message.id]);
      expect(engine.followUps.single.due, tomorrow);
      expect(remembered.single.due, tomorrow);
    });

    test('Forward to opens the forward, to them, and the chain goes on',
        () async {
      final message = await run(const [
        QuickStepAction(QuickStepActionType.forwardTo,
            address: 'boss@example.com'),
        QuickStepAction(QuickStepActionType.markRead),
      ]);

      expect(composed.single.kind, ComposeKind.forward);
      expect(composed.single.original?.id, message.id);
      expect(composed.single.to.single.email, 'boss@example.com');
      expect(
        c.read(messagesProvider(listId)).value!
            .firstWhere((m) => m.id == message.id)
            .isRead,
        isTrue,
      );
    });

    test('Reply then delete opens the reply, and then deletes', () async {
      final message =
          await run(const [QuickStepAction(QuickStepActionType.replyDelete)]);

      expect(composed.single.kind, ComposeKind.reply);
      expect(composed.single.original?.id, message.id);
      expect(c.read(messagesProvider(listId)).value!.map((m) => m.id),
          isNot(contains(message.id)));
    });

    test('New message to and Meeting from it open theirs', () async {
      final message = await run(const [
        QuickStepAction(QuickStepActionType.newMessageTo,
            address: 'dana@example.com'),
        QuickStepAction(QuickStepActionType.meeting),
      ]);

      expect(composed.single.kind, ComposeKind.newMessage);
      expect(composed.single.original, isNull);
      expect(composed.single.to.single.email, 'dana@example.com');
      expect(meetings.single.id, message.id);
    });

    test('one that opens a screen fails where none can be opened', () async {
      await expectLater(
        run(const [
          QuickStepAction(QuickStepActionType.forwardTo,
              address: 'boss@example.com'),
        ], with_: const QuickStepHooks()),
        throwsStateError,
      );
    });
  });

  group('on screen', () {
    Future<ProviderContainer> pump(WidgetTester tester, {Widget? home}) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: home ?? const AppShell()),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    Future<void> add(WidgetTester tester, String type) async {
      await tester.tap(find.text('Add action'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('qs-type-$type')));
      await tester.pumpAndSettle();
    }

    testWidgets('the editor asks who to forward to, and which day',
        (tester) async {
      final c = await pump(tester, home: const QuickStepsScreen());
      await tester.tap(find.text('New'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'To the boss');

      await add(tester, 'forwardTo');
      await tester.enterText(
          find.byKey(const ValueKey('qs-address')), 'not an address');
      await tester.tap(find.byKey(const ValueKey('qs-address-ok')));
      await tester.pumpAndSettle();
      expect(find.text('An email address'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('qs-address')), 'boss@example.com');
      await tester.tap(find.byKey(const ValueKey('qs-address-ok')));
      await tester.pumpAndSettle();

      await add(tester, 'flagFor');
      await tester.tap(find.byKey(const ValueKey('qs-when-tomorrow')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = c.read(quickStepsProvider).single;
      expect(saved.actions, const [
        QuickStepAction(QuickStepActionType.forwardTo,
            address: 'boss@example.com'),
        QuickStepAction(QuickStepActionType.flagFor,
            when: FollowUpChoice.tomorrow),
      ]);
      expect(find.text('Forward to boss@example.com, then Flag for Tomorrow'),
          findsOneWidget);
    });

    test('Ctrl+Shift and which number: the key\'s place, not its character',
        () {
      expect(quickStepNumber(PhysicalKeyboardKey.digit1), 1);
      expect(quickStepNumber(PhysicalKeyboardKey.digit9), 9);
      expect(quickStepNumber(PhysicalKeyboardKey.numpad3), 3);
      expect(quickStepNumber(PhysicalKeyboardKey.digit0), isNull);
      expect(quickStepNumber(PhysicalKeyboardKey.keyA), isNull);
    });

    testWidgets('Ctrl+Shift+2 runs the second Quick Step on the message',
        (tester) async {
      final c = await pump(tester);
      c.read(quickStepsProvider.notifier)
        ..add(const QuickStep(id: 'a', name: 'Read it', actions: [
          QuickStepAction(QuickStepActionType.markRead),
        ]))
        ..add(const QuickStep(id: 'b', name: 'Flag it', actions: [
          QuickStepAction(QuickStepActionType.flag),
        ]));
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final message = c.read(selectedMessageProvider)!;
      expect(message.isFlagged, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.text('Flag it applied'), findsOneWidget);
      expect(c.read(selectedMessageProvider)!.isFlagged, isTrue);
    });
  });
}
