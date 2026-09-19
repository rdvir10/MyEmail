import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/files/file_bridge.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/drop_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';

import 'fakes/fake_webview.dart';

/// Files coming into the app: dropped from another window, or pasted.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late Directory temp;
  late FakeFileBridge bridge;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('myemail-drop');
    bridge = FakeFileBridge();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  IncomingFile aFile(String name, {String contents = 'hello'}) {
    final file = File('${temp.path}/$name')..writeAsStringSync(contents);
    return IncomingFile(
      path: file.path,
      name: name,
      mimeType: 'text/plain',
      sizeBytes: file.lengthSync(),
    );
  }

  Draft draft() => const Draft(
        accountId: 'acct-personal',
        kind: ComposeKind.newMessage,
        to: [],
        cc: [],
        bcc: [],
        subject: 'Numbers',
        htmlBody: '<p></p>',
        attachments: [],
      );

  /// Reading a file is real work on a real disk, and a widget test's clock
  /// does not wait for it. Anything that ends in a file being read has to
  /// run where time still passes.
  Future<void> reallyDo(WidgetTester tester, Future<void> Function() act) async {
    await tester.runAsync(() async {
      await act();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  Future<ProviderContainer> openCompose(WidgetTester tester) async {
    final c = ProviderContainer(
      overrides: [
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
        fileBridgeProvider.overrideWithValue(bridge),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: ComposeScreen(draft: draft())),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  group('reading what arrived', () {
    test('a dropped file becomes something a draft can carry', () async {
      final read = await readIncoming([aFile('notes.txt', contents: 'abc')]);

      expect(read, hasLength(1));
      expect(read.first.fileName, 'notes.txt');
      expect(read.first.bytes, hasLength(3));
    });

    test('a file that has gone is skipped, not thrown', () async {
      // The copy lives in a cache Android may clear at any moment.
      const missing = IncomingFile(
        path: '/nowhere/gone.txt',
        name: 'gone.txt',
        mimeType: 'text/plain',
        sizeBytes: 3,
      );

      expect(await readIncoming([missing]), isEmpty);
    });
  });

  group('while a message is being written', () {
    testWidgets('a dropped file is attached to it', (tester) async {
      final c = await openCompose(tester);

      await reallyDo(tester, () async {
        c.read(dropTargetProvider).current!([aFile('quote.txt')]);
      });

      expect(find.textContaining('quote.txt'), findsOneWidget);
    });

    testWidgets('a file on the clipboard pastes in as an attachment',
        (tester) async {
      await openCompose(tester);
      bridge.onClipboard = [aFile('pasted.txt')];

      await reallyDo(tester, () => tester.tap(find.byTooltip('Paste file')));

      expect(find.textContaining('pasted.txt'), findsOneWidget);
    });

    testWidgets('an empty clipboard says so rather than doing nothing',
        (tester) async {
      await openCompose(tester);

      await tester.tap(find.byTooltip('Paste file'));
      await tester.pumpAndSettle();

      expect(find.text('No file on the clipboard.'), findsOneWidget);
    });

    testWidgets('closing the window gives the drop back', (tester) async {
      // Otherwise a file dropped later is attached to a message nobody is
      // looking at any more.
      final c = await openCompose(tester);
      expect(c.read(dropTargetProvider).current, isNotNull);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
        ),
      );
      await tester.pumpAndSettle();

      expect(c.read(dropTargetProvider).current, isNull);
    });
  });
}
