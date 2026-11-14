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

  /// Handed over, and no answer: as Microsoft says it.
  const mayHaveGone = SendMayHaveGone(
    'Microsoft did not answer in time, so it may or may not have gone. '
    'Check Sent Items before sending it again.',
  );

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

  /// Not [disposable] for a message with writing in it, which is what
  /// puts a copy in Drafts as the app goes out of sight.
  Future<void> open(
    WidgetTester tester,
    _Engine engine,
    Draft draft, {
    UndoSend undo = UndoSend.five,
    bool inWindow = false,
    bool disposable = true,
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
                      builder: (_) => ComposeScreen(
                        draft: draft,
                        inWindow: inWindow,
                        disposable: disposable,
                      ),
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

  /// The held message's time up, and its send done.
  Future<void> holdOver(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  const draftsId = 'acct-personal:[Gmail]/Drafts';

  /// The subjects in Drafts, as the server has them.
  Future<List<String>> drafts(WidgetTester tester, _Engine engine) async =>
      (await tester.runAsync(() => engine.loadMessages(draftsId)))!
          .map((m) => m.subject)
          .toList();

  void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void away(WidgetTester tester) => lifecycle(tester, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);

  void back(WidgetTester tester) => lifecycle(tester, const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);

  /// Out of sight and back, as for the file picker: the window puts what is
  /// written in Drafts as it goes, against Android ending the app.
  Future<void> awayAndBack(WidgetTester tester) async {
    away(tester);
    back(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
  }

  /// Every bar in the app puts out the one before it.
  void anotherBar(WidgetTester tester) =>
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Something else')));

  List<HeldSend> held(WidgetTester tester) => ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      ).read(heldSendsProvider);

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

    testWidgets(
        'a send that fails opens it again by itself, with the problem, and '
        'it stays once the bar has gone', (tester) async {
      // It was said on a bar with Open, for ten seconds. Not looked at in
      // time, or put out by any other bar, the bar took the message with
      // it: and the copy in Drafts had gone as the window closed.
      final engine = _Engine()..refuseSend = true;
      final before = await drafts(tester, engine);
      await open(tester, engine, draft(), disposable: false);
      await awayAndBack(tester);
      expect(await drafts(tester, engine),
          unorderedEquals([...before, 'Numbers']),
          reason: 'a copy against the app being ended');

      await send(tester);
      await holdOver(tester);
      anotherBar(tester);
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('The server said no.'), findsOneWidget);
      expect(find.text('Numbers'), findsOneWidget, reason: 'as it was');
      expect(engine.sent, isEmpty);
      expect(await drafts(tester, engine),
          unorderedEquals([...before, 'Numbers']),
          reason: 'the copy in Drafts is still there');
    });

    testWidgets(
        'one that may have gone says so, and to look in Sent Items, not '
        'that it was not sent', (tester) async {
      // "The message was not sent." stood in front of the engine's own
      // word that it may have gone, beside a button that invited sending
      // it again.
      final engine = _Engine()
        ..refuseSend = true
        ..failure = mayHaveGone;
      await open(tester, engine, draft());
      await send(tester);
      await holdOver(tester);

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.textContaining('may or may not have gone'), findsOneWidget);
      expect(find.textContaining('Check Sent Items'), findsOneWidget);
      expect(find.textContaining('not sent'), findsNothing);
    });

    testWidgets(
        'one that fails while the app is out of sight is kept, and opens '
        'when it is back', (tester) async {
      // Going out of sight sends what is held at once. Opened while it is
      // away, the screen is not built until the app is back, so a put-away
      // closing what is open would take it away unasked.
      final engine = _Engine()..refuseSend = true;
      await open(tester, engine, draft());
      await send(tester);

      away(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(held(tester), hasLength(1), reason: 'kept, failed, till opened');
      expect(held(tester).single.waiting, isFalse);
      expect(find.byType(ComposeScreen), findsNothing);

      back(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('The server said no.'), findsOneWidget);
      expect(held(tester), isEmpty, reason: 'the window has it now');
    });

    group('with nowhere left to open it', () {
      /// Sent from a pane with a navigator of its own, which has gone by
      /// the time the send fails.
      Future<void> sendFromPaneThatGoes(
        WidgetTester tester,
        _Engine engine,
      ) async {
        final pane = ValueNotifier(true);
        addTearDown(pane.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              mailEngineProvider.overrideWithValue(engine),
              uiStateStoreProvider.overrideWithValue(settings()),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: pane,
                  builder: (_, there, _) => !there
                      ? const Text('the pane has gone')
                      : Navigator(
                          onGenerateRoute: (_) => MaterialPageRoute<void>(
                            builder: (context) => Center(
                              child: ElevatedButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute<bool>(
                                    builder: (_) =>
                                        ComposeScreen(draft: draft()),
                                  ),
                                ),
                                child: const Text('open compose'),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open compose'));
        await tester.pumpAndSettle();
        await send(tester);
        pane.value = false;
        await tester.pumpAndSettle();
        await holdOver(tester);
      }

      testWidgets('it is kept, and a bar that stays offers it',
          (tester) async {
        final engine = _Engine()..refuseSend = true;
        await sendFromPaneThatGoes(tester, engine);

        expect(held(tester), hasLength(1), reason: 'kept, failed, till opened');
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        expect(find.textContaining('The message was not sent.'),
            findsOneWidget);
        expect(find.textContaining('The server said no.'), findsOneWidget);

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(ComposeScreen), findsOneWidget);
        expect(find.text('Numbers'), findsOneWidget);
        expect(held(tester), isEmpty, reason: 'the window has it now');
      });

      testWidgets('the bar says one that may have gone may have',
          (tester) async {
        final engine = _Engine()
          ..refuseSend = true
          ..failure = mayHaveGone;
        await sendFromPaneThatGoes(tester, engine);

        expect(find.textContaining('may or may not have gone'), findsOneWidget);
        expect(find.textContaining('Check Sent Items'), findsOneWidget);
        expect(find.textContaining('not sent'), findsNothing);
      });
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

    group('its copy in Drafts', () {
      // Put there as the app went out of sight while it was written, and
      // taken out as the window closed: a send that then failed left the
      // message nowhere at all.
      testWidgets('stays while it waits, and goes once it has gone',
          (tester) async {
        final engine = _Engine();
        final before = await drafts(tester, engine);
        await open(tester, engine, draft(), disposable: false);
        await awayAndBack(tester);

        await send(tester);
        await tester.pump(const Duration(milliseconds: 200));
        expect(await drafts(tester, engine),
            unorderedEquals([...before, 'Numbers']));

        await holdOver(tester);
        expect(engine.sent.single.subject, 'Numbers');
        expect(await drafts(tester, engine), unorderedEquals(before));
      });

      for (final (choice, kept) in [('Save draft', true), ('Discard', false)]) {
        testWidgets("taken back with Undo, it is the window's again: "
            '$choice leaves ${kept ? 'one copy, not two' : 'none'}',
            (tester) async {
          final engine = _Engine();
          final before = await drafts(tester, engine);
          await open(tester, engine, draft(), disposable: false);
          await awayAndBack(tester);

          await send(tester);
          await tester.tap(find.text('Undo'));
          await tester.pumpAndSettle();
          expect(find.byType(ComposeScreen), findsOneWidget);
          expect(await drafts(tester, engine),
              unorderedEquals([...before, 'Numbers']));

          await tester.pageBack();
          await tester.pumpAndSettle();
          await tester.tap(find.text(choice));
          await tester.pumpAndSettle();

          expect(find.byType(ComposeScreen), findsNothing);
          expect(await drafts(tester, engine),
              unorderedEquals([...before, if (kept) 'Numbers']));
          expect(engine.sent, isEmpty);
        });
      }
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

  /// What a refused send throws, where not a plain no.
  SendFailed? failure;
  final sent = <Draft>[];

  @override
  Future<void> sendDraft(Draft draft) async {
    if (refuseSend) throw failure ?? const SendFailed('The server said no.');
    sent.add(draft);
  }
}
