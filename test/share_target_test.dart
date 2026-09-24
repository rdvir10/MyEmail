import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/compose/open_compose.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/file_drop_host.dart';

import 'fakes/fake_webview.dart';

/// MyEmail in the share sheet: whatever another app shares becomes a new
/// message here.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late Directory temp;
  late FakeFileBridge bridge;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('myemail-share');
    bridge = FakeFileBridge();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  IncomingFile aFile(String name) {
    final file = File('${temp.path}/$name')..writeAsStringSync('hello');
    return IncomingFile(
      path: file.path,
      name: name,
      mimeType: 'text/plain',
      sizeBytes: file.lengthSync(),
    );
  }

  /// [realTime] for a share that carries a file: the file is read off the
  /// disk in the first frame's callback, and a chain that has crossed into
  /// real time is not moved along by the test's clock. Everything else
  /// stays on the fake clock, where an app left on screen settles cleanly.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    bool realTime = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
        fileBridgeProvider.overrideWithValue(bridge),
      ],
    );
    addTearDown(c.dispose);
    final app = UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: FileDropHost(child: AppShell())),
    );
    if (realTime) {
      await tester.runAsync(() async {
        await tester.pumpWidget(app);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
    } else {
      await tester.pumpWidget(app);
    }
    await tester.pumpAndSettle();
    return c;
  }

  /// Let a chain of work that touches the disk finish in real time, then
  /// draw whatever it produced.
  Future<void> settleForReal(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
  }

  group('opened from a share sheet', () {
    testWidgets('a shared file starts a message with it attached',
        (tester) async {
      bridge.openedWith = SharedContent(files: [aFile('site-plan.pdf')]);

      await pumpApp(tester, realTime: true);
      await settleForReal(tester);

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.textContaining('site-plan.pdf'), findsOneWidget);
    });

    testWidgets('shared text becomes the body, and a subject the subject',
        (tester) async {
      bridge.openedWith = const SharedContent(
        text: 'Have a look at this',
        subject: 'From the browser',
      );

      await pumpApp(tester);
      await settleForReal(tester);

      expect(find.byType(ComposeScreen), findsOneWidget);
      final screen = tester.widget<ComposeScreen>(find.byType(ComposeScreen));
      expect(screen.draft.subject, 'From the browser');
      expect(screen.draft.htmlBody, contains('Have a look at this'));
    });

    testWidgets('nothing shared opens nothing', (tester) async {
      await pumpApp(tester);
      await settleForReal(tester);

      expect(find.byType(ComposeScreen), findsNothing);
    });
  });

  // Android copies each file in before handing it over, and one it cannot
  // read (refused, gone, a name the disk will not take) used to be left out
  // without a word: the message opened with one file of two, or nothing
  // opened at all.
  group('files Android could not read', () {
    testWidgets('are said to be left out of the message', (tester) async {
      bridge.openedWith =
          SharedContent(files: [aFile('site-plan.pdf')], skipped: 1);

      await pumpApp(tester, realTime: true);
      await settleForReal(tester);

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('One file could not be read, and was left out.'),
          findsOneWidget);
    });

    testWidgets('and said when that was all there was', (tester) async {
      bridge.openedWith = SharedContent.fromMap({'files': [], 'skipped': 2});

      await pumpApp(tester);
      await settleForReal(tester);

      expect(find.byType(ComposeScreen), findsNothing);
      expect(find.text('2 files could not be read, and were left out.'),
          findsOneWidget);
    });

    testWidgets('a drop says so too', (tester) async {
      await pumpApp(tester);

      bridge.drop(const [], skipped: 1);
      await tester.pump();

      expect(find.text('One file could not be read, and was left out.'),
          findsOneWidget);
    });
  });

  group('shared while already running', () {
    testWidgets('the same message appears', (tester) async {
      await pumpApp(tester);

      // The share, and the disk read it starts, in real time together;
      // then a second round, because what follows the read was set up on
      // the test's clock and has to be moved along by it, and may in turn
      // start more real work.
      await tester.runAsync(() async {
        bridge.receiveShare(SharedContent(files: [aFile('photo.jpg')]));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();
      await settleForReal(tester);

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.textContaining('photo.jpg'), findsOneWidget);
    });
  });

  group('shared text as a body', () {
    test('paragraphs stay paragraphs, and lines stay lines', () {
      expect(
        textAsHtml('First line\nsecond line\n\nNew paragraph'),
        '<p>First line<br>second line</p><p>New paragraph</p>',
      );
    });

    test('nothing in it is taken as markup', () {
      // A page's address shared from a browser can carry angle brackets and
      // ampersands, and text is text whatever it contains.
      expect(
        textAsHtml('a < b && c > d'),
        '<p>a &lt; b &amp;&amp; c &gt; d</p>',
      );
    });
  });
}
