import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/domain/pending_change.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/waiting_changes.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// What the screen says of a change kept for later, the server being out
/// of reach: the report of it, the line over the list while it waits, and
/// what is said of one given up on.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  group('in the app', () {
    Future<(ProviderContainer, _KeepingEngine)> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = _KeepingEngine();
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
      return (c, engine);
    }

    Finder inPane(Finder f) =>
        find.descendant(of: find.byType(ReadingPane), matching: f);

    testWidgets('a delete kept for later says it will sync, and the list '
        'says what waits until it has', (tester) async {
      final (c, engine) = await pump(tester);
      expect(find.byKey(const ValueKey('waiting-changes-bar')), findsNothing);

      await tester.tap(inPane(find.byTooltip('Delete')));
      await tester.pumpAndSettle();

      expect(
        find.text('Message deleted. It will sync when the connection is back.'),
        findsOneWidget,
      );
      expect(find.text('Undo'), findsOneWidget);
      expect(find.text('1 change waiting to sync'), findsOneWidget);

      // Still no answer when it is tried.
      await tester.tap(find.text('Try now'));
      await tester.pumpAndSettle();
      expect(find.text('The server is still not answering. They go when it '
          'does.'), findsOneWidget);
      expect(find.text('1 change waiting to sync'), findsOneWidget);

      // And then the server answers.
      engine.answering = true;
      await tester.tap(find.text('Try now'));
      await tester.pumpAndSettle();
      expect(find.text('Synced.'), findsOneWidget);
      expect(find.byKey(const ValueKey('waiting-changes-bar')), findsNothing);
      expect(c.read(waitingChangesProvider), isEmpty);

      // Past any send the delete asked for.
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('one given up on is said, with what the server said',
        (tester) async {
      final (c, engine) = await pump(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      engine.failed.add(FailedChange(
        accountId: 'acct-personal',
        kind: PendingKind.move,
        count: 1,
        fromFolderId: folder,
        reason: 'Microsoft refused the request (ErrorAccessDenied)',
        subject: 'Lunch',
      ));

      await c.read(waitingChangesProvider.notifier).sendIfWaiting();
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not move "Lunch"'), findsOneWidget);
      expect(find.textContaining('It is back in'), findsOneWidget);
    });
  });

  group('a change given up on, said', () {
    FailedChange failed(
      PendingKind kind, {
      int count = 1,
      String? subject = 'Lunch',
      bool? wanted,
      String reason = 'Microsoft refused the request (ErrorAccessDenied)',
    }) =>
        FailedChange(
          accountId: 'a',
          kind: kind,
          count: count,
          fromFolderId: 'a:Inbox',
          toFolderId: 'a:Work',
          reason: reason,
          subject: subject,
          wanted: wanted,
        );

    test('a delete names the message and where it is back', () {
      expect(
        failedChangeSaid(failed(PendingKind.delete), from: 'Inbox'),
        'Could not delete "Lunch": Microsoft refused the request '
        '(ErrorAccessDenied). It is back in Inbox.',
      );
    });

    test('a move says where it was going, and several are counted', () {
      expect(
        failedChangeSaid(failed(PendingKind.move, count: 3),
            from: 'Inbox', to: 'Work'),
        'Could not move 3 messages to Work: Microsoft refused the request '
        '(ErrorAccessDenied). They are back in Inbox.',
      );
    });

    test('a mark says which, and nothing of where it is', () {
      expect(
        failedChangeSaid(
            failed(PendingKind.read, wanted: false, subject: null),
            from: 'Inbox'),
        'Could not mark a message unread: Microsoft refused the request '
        '(ErrorAccessDenied).',
      );
      expect(
        failedChangeSaid(failed(PendingKind.flag, wanted: true), from: 'Inbox'),
        startsWith('Could not flag "Lunch": '),
      );
    });
  });
}

/// The sample mail, with every delete kept for later as though the server
/// were out of reach, and sent when [answering].
class _KeepingEngine extends SampleMailEngine implements KeepsChangesForLater {
  var waiting = 0;
  var answering = false;
  final failed = <FailedChange>[];

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    final moves = await super.deleteMessages(messageIds);
    waiting += messageIds.length;
    return [
      for (final m in moves)
        MessageMove(
          fromFolderId: m.fromFolderId,
          toFolderId: m.toFolderId,
          movedIds: const [],
          waiting: messageIds,
          action: 'one',
        ),
    ];
  }

  @override
  Future<Map<String, int>> changesWaiting() async =>
      waiting == 0 ? const {} : {'acct-personal': waiting};

  @override
  Future<SentChanges> sendWaitingChanges({bool evenJustMade = false}) async {
    if (!answering) return SentChanges(waiting: waiting);
    final sent = waiting;
    waiting = 0;
    return SentChanges(sent: sent);
  }

  @override
  Future<List<FailedChange>> takeFailedChanges() async {
    final all = [...failed];
    failed.clear();
    return all;
  }
}
