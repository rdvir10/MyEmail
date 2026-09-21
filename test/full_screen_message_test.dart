import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/full_screen_message.dart';
import 'package:myemail/ui/messages/html_body_view.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// The body on its own, with the app and Android's bars out of the way.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  /// What the app asked Android to do with its bars, newest last.
  List<String> systemUiCalls(WidgetTester tester) => _systemUi;

  setUp(() {
    _systemUi.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        _systemUi.add('${call.arguments}');
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
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

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  testWidgets('the button opens the body with nothing else on screen',
      (tester) async {
    final c = await pump(tester);
    final open = c.read(selectedMessageProvider)!;

    await tester.tap(find.byTooltip('Full screen (F11)'));
    await tester.pumpAndSettle();

    expect(find.byType(FullScreenMessage), findsOneWidget);
    expect(find.byType(AppShell), findsNothing, reason: 'no list, no tree');
    // The sample engine sends some messages as HTML and some as text, and
    // full screen shows whichever this one is.
    expect(
      find.byType(HtmlBodyView).evaluate().length +
          find.byType(SelectableText).evaluate().length,
      greaterThan(0),
    );
    // The subject is on the bar, which starts shown so the way out is
    // obvious, and the sender's block is not carried over.
    expect(find.text(open.subject), findsOneWidget);
    expect(find.byTooltip('Reply'), findsNothing);
  });

  testWidgets('the bar goes on its own, and a tap brings it back',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Full screen (F11)'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Leave full screen'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    final hidden = tester.widget<AnimatedSlide>(find.byType(AnimatedSlide));
    expect(hidden.offset, const Offset(0, -1), reason: 'slid out of the way');

    await tester.tapAt(const Offset(700, 600));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedSlide>(find.byType(AnimatedSlide)).offset,
      Offset.zero,
    );
  });

  testWidgets('Android\'s bars go while reading and come back after',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byTooltip('Full screen (F11)'));
    await tester.pumpAndSettle();
    expect(systemUiCalls(tester).last, contains('immersiveSticky'));

    await tester.tap(find.byTooltip('Leave full screen'));
    await tester.pumpAndSettle();

    expect(find.byType(FullScreenMessage), findsNothing);
    expect(systemUiCalls(tester).last, contains('edgeToEdge'),
        reason: 'the shell would otherwise be left with a gap');
  });

  testWidgets('F11 opens it and Esc leaves', (tester) async {
    await pump(tester);

    await press(tester, LogicalKeyboardKey.f11);
    expect(find.byType(FullScreenMessage), findsOneWidget);

    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(FullScreenMessage), findsNothing);
    expect(find.byType(ReadingPane), findsOneWidget,
        reason: 'back where it was opened from');
  });

  testWidgets('F11 again, from inside, leaves too', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.f11);
    expect(find.byType(FullScreenMessage), findsOneWidget);

    await press(tester, LogicalKeyboardKey.f11);

    expect(find.byType(FullScreenMessage), findsNothing);
  });

  testWidgets('a plain-text message fills the screen as text', (tester) async {
    // No WebView involved, and no chrome around it either.
    final message = MailMessage(
      id: 'a:INBOX#9',
      accountId: 'a',
      folderId: 'a:INBOX',
      uid: 9,
      subject: 'Just words',
      from: const MailAddress(email: 'dana@example.com'),
      to: const [],
      date: DateTime(2026, 9, 20),
      preview: '',
      isRead: true,
    );
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      messageBodyProvider(message.id)
          .overrideWith((ref) async => const MailBody(text: 'Line after line')),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: FullScreenMessage(message: message)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Line after line'), findsOneWidget);
    expect(find.byType(HtmlBodyView), findsNothing);
    expect(find.text('Just words'), findsOneWidget, reason: 'on the bar');
  });
}

final _systemUi = <String>[];
