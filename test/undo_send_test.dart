import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/held_sends.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';

import 'fakes/fake_webview.dart';

/// Undo Send, the checks before a message goes, and the ⋮ menu's
/// importance and receipt.
void main() {
  setUp(FakeWebViewPlatform.install);

  const dana = MailAddress(email: 'dana@example.com');

  Draft draft({String subject = 'Numbers', String body = '<p>Thursday.</p>'}) =>
      Draft(
        accountId: 'acct-personal',
        kind: ComposeKind.newMessage,
        to: const [dana],
        subject: subject,
        htmlBody: body,
      );

  /// The settings a test sends under: Undo Send as given.
  MemoryUiStateStore settings({UndoSend undo = UndoSend.five}) =>
      MemoryUiStateStore()
        ..writeString(
          UiStateKeys.display,
          jsonEncode(DisplaySettings(undoSend: undo).toJson()),
        );

  Future<void> open(
    WidgetTester tester,
    _Engine engine,
    Draft draft, {
    UndoSend undo = UndoSend.five,
    bool inWindow = false,
  }) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mailEngineProvider.overrideWithValue(engine),
          uiStateStoreProvider.overrideWithValue(settings(undo: undo)),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) =>
                          ComposeScreen(draft: draft, inWindow: inWindow),
                    ),
                  ),
                  child: const Text('open compose'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open compose'));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
  }

  group('Undo Send', () {
    testWidgets('the window closes at once, and the message waits',
        (tester) async {
      final engine = _Engine();
      await open(tester, engine, draft());
      await send(tester);

      expect(find.byType(ComposeScreen), findsNothing);
      expect(find.text('Sending…'), findsOneWidget);
      expect(engine.sent, isEmpty);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(engine.sent.single.subject, 'Numbers');
      expect(find.text('Message sent'), findsOneWidget);
    });

    testWidgets('Undo takes it back and opens it again as it was',
        (tester) async {
      final engine = _Engine();
      await open(tester, engine, draft());
      await send(tester);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(engine.sent, isEmpty, reason: 'taken back in time');
    });

    testWidgets('a send that fails says so, with the way back to it',
        (tester) async {
      final engine = _Engine()..refuseSend = true;
      await open(tester, engine, draft());
      await send(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.textContaining('The message was not sent.'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(ComposeScreen), findsOneWidget);
    });

    testWidgets('off, or in a window of its own, it goes at once',
        (tester) async {
      final engine = _Engine();
      await open(tester, engine, draft(), undo: UndoSend.off);
      await send(tester);
      expect(engine.sent, hasLength(1));

      final windowed = _Engine();
      await open(tester, windowed, draft(), inWindow: true);
      await send(tester);
      expect(windowed.sent, hasLength(1));
    });

    testWidgets('going out of sight sends what is held, now', (tester) async {
      final engine = _Engine();
      final container = ProviderContainer(
        overrides: [mailEngineProvider.overrideWithValue(engine)],
      );
      addTearDown(container.dispose);
      final held = container
          .read(heldSendsProvider.notifier)
          .hold(draft(), const Duration(seconds: 10));
      expect(held.waiting, isTrue);

      container.read(heldSendsProvider.notifier).flush();
      await tester.pump();
      expect(engine.sent, hasLength(1));
      expect(held.undo(), isFalse, reason: 'too late: it has gone');
      // The folder counts read again after it, as after any send.
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('the checks before Send', () {
    testWidgets('no subject: asked, and Keep writing keeps it', (tester) async {
      final engine = _Engine();
      await open(tester, engine, draft(subject: ''), undo: UndoSend.off);
      await send(tester);
      expect(find.text('This message has no subject. Send it anyway?'),
          findsOneWidget);

      await tester.tap(find.text('Keep writing'));
      await tester.pumpAndSettle();
      expect(engine.sent, isEmpty);
      expect(find.byType(ComposeScreen), findsOneWidget);

      await send(tester);
      await tester.tap(find.text('Send anyway'));
      await tester.pumpAndSettle();
      expect(engine.sent, hasLength(1));
    });

    testWidgets('"see attached" with nothing attached: reminded',
        (tester) async {
      final engine = _Engine();
      await open(
        tester,
        engine,
        draft(body: '<p>The plans are attached.</p>'),
        undo: UndoSend.off,
      );
      await send(tester);
      expect(find.text('Attachment reminder'), findsOneWidget);

      await tester.tap(find.text('Send anyway'));
      await tester.pumpAndSettle();
      expect(engine.sent, hasLength(1));
    });
  });

  testWidgets('the ⋮ menu: high importance and a read receipt, said under '
      'the subject and sent', (tester) async {
    final engine = _Engine();
    await open(tester, engine, draft(), undo: UndoSend.off);

    await tester.tap(find.byKey(const ValueKey('compose-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High importance'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('compose-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request a read receipt'));
    await tester.pumpAndSettle();

    expect(find.text('High importance'), findsOneWidget);
    expect(find.text('Read receipt requested'), findsOneWidget);

    await send(tester);
    expect(engine.sent.single.importance, Importance.high);
    expect(engine.sent.single.requestReadReceipt, isTrue);
  });
}

class _Engine extends SampleMailEngine {
  bool refuseSend = false;
  final sent = <Draft>[];

  @override
  Future<void> sendDraft(Draft draft) async {
    if (refuseSend) throw const SendFailed('The server said no.');
    sent.add(draft);
  }
}
