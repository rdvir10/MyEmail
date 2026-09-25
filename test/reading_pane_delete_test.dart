import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Delete from the open message's own toolbar.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Size size, {
    MailEngine? engine,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        if (engine != null) mailEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  Finder inPane(Finder f) =>
      find.descendant(of: find.byType(ReadingPane), matching: f);

  bool inList(ProviderContainer c, String id) {
    final folder = c.read(effectiveSelectedFolderIdProvider)!;
    return c.read(messagesProvider(folder)).value!.any((m) => m.id == id);
  }

  testWidgets('on a tablet, Delete takes the message out and empties the pane',
      (tester) async {
    final c = await pump(tester, const Size(1400, 900));
    final id = c.read(selectedMessageIdProvider)!;
    expect(inPane(find.byTooltip('Flag')), findsOneWidget,
        reason: 'room for both here');

    await tester.tap(inPane(find.byTooltip('Delete')));
    await tester.pumpAndSettle();

    expect(inList(c, id), isFalse);
    // The list lands on another message, as it does whenever the selection
    // goes; what must not happen is the deleted one staying on show.
    for (final pane in tester.widgetList<ReadingPane>(find.byType(ReadingPane))) {
      expect(pane.message.id, isNot(id));
    }
  });

  testWidgets('on a tablet, the bar says it was deleted, with Undo, though '
      'the pane that asked has gone by then', (tester) async {
    // The pane is keyed by its message, and the message leaves the list
    // before the server answers, so the pane is disposed mid-delete. Read
    // through its ref after that, the delete that had gone through was
    // reported as "Could not delete: Bad state: ...", with no Undo.
    final engine = _SlowDelete();
    await pump(tester, const Size(1400, 900), engine: engine);

    await tester.tap(inPane(find.byTooltip('Delete')));
    await tester.pump(const Duration(milliseconds: 300));
    engine.answer();
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not delete'), findsNothing);
    expect(find.text('Message deleted'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
  });

  group('on a phone', () {
    Future<(ProviderContainer, String)> openFirst(WidgetTester tester) async {
      final c = await pump(tester, const Size(400, 900));
      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
      return (c, first.message.id);
    }

    testWidgets('Delete stands where the flag was, and closes the screen',
        (tester) async {
      final (c, id) = await openFirst(tester);
      expect(inPane(find.byTooltip('Flag')), findsNothing);
      expect(inPane(find.byTooltip('Remove flag')), findsNothing);

      await tester.tap(inPane(find.byTooltip('Delete')));
      await tester.pumpAndSettle();

      expect(find.byType(MessageScreen), findsNothing);
      expect(inList(c, id), isFalse);
    });

    testWidgets('the screen closes at once, before the server has answered',
        (tester) async {
      // A swipe has the row gone before the server is asked; this used to
      // wait for the answer, a round trip the swipe never showed.
      final engine = _SlowDelete();
      await pump(tester, const Size(400, 900), engine: engine);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);

      await tester.tap(inPane(find.byTooltip('Delete')));
      // Settles: nothing is waiting on the server, only the route's own
      // transition out.
      await tester.pumpAndSettle();

      expect(engine.pending, isTrue, reason: 'the server has not answered');
      expect(find.byType(MessageScreen), findsNothing,
          reason: 'gone while the delete is still on its way');

      engine.answer();
      await tester.pumpAndSettle();
      expect(find.text('Message deleted'), findsOneWidget);
    });

    testWidgets('Undo still works once the screen has closed',
        (tester) async {
      // The bar outlives the screen that raised it. Its Undo read that
      // screen's ref, gone by then, and on the phone in 2.28.0 the message
      // stayed deleted with nothing said.
      final (c, id) = await openFirst(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final gone = c
          .read(messagesProvider(folder))
          .value!
          .firstWhere((m) => m.id == id);

      await tester.tap(inPane(find.byTooltip('Delete')));
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsNothing);
      expect(inList(c, id), isFalse);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Message put back'), findsOneWidget);
      // By what it is: put back, it may have a new id.
      expect(
        c.read(messagesProvider(folder)).value!.where(
              (m) => m.subject == gone.subject && m.date == gone.date,
            ),
        hasLength(1),
      );
    });

    testWidgets('the flag moved into the three-dot menu', (tester) async {
      final (c, id) = await openFirst(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      bool flagged() => c
          .read(messagesProvider(folder))
          .value!
          .firstWhere((m) => m.id == id)
          .isFlagged;
      final before = flagged();

      await tester.tap(inPane(find.byTooltip('More')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(before ? 'Remove flag' : 'Flag'));
      await tester.pumpAndSettle();

      expect(flagged(), !before);
    });
  });
}

/// A sample engine whose delete waits to be told to answer, so a test can
/// look at what is on screen in the meantime.
class _SlowDelete extends SampleMailEngine {
  Completer<void>? _gate;

  bool get pending => _gate != null && !_gate!.isCompleted;

  void answer() => _gate?.complete();

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    _gate = Completer<void>();
    await _gate!.future;
    return super.deleteMessages(messageIds);
  }
}
