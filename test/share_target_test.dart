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

  // A calendar's "Email guests" or an app's "Send feedback" names who it
  // is to, and an address tapped in a browser is a mailto: link. Both
  // opened a message to nobody, or did not offer the app at all.
  group('who it is to', () {
    testWidgets('an app that names them fills in To, Cc and Bcc',
        (tester) async {
      bridge.openedWith = const SharedContent(
        to: ['someone@example.com'],
        cc: ['Dana Levi <dana@example.com>, sam@example.com'],
        bcc: ['audit@example.com'],
        subject: 'App logs',
        text: 'Logs attached.',
      );

      await pumpApp(tester);
      await settleForReal(tester);

      final draft =
          tester.widget<ComposeScreen>(find.byType(ComposeScreen)).draft;
      expect(draft.to.map((a) => a.email), ['someone@example.com']);
      expect(draft.cc.map((a) => a.email),
          ['dana@example.com', 'sam@example.com']);
      expect(draft.cc.first.name, 'Dana Levi');
      expect(draft.bcc.map((a) => a.email), ['audit@example.com']);
      expect(draft.subject, 'App logs');
    });

    testWidgets('a mailto: link is a new message to its address, with its '
        'subject and body', (tester) async {
      bridge.openedWith = SharedContent.fromMap({
        'files': [],
        'mailto': 'mailto:dana@example.com?subject=Site%20visit'
            '&body=Thursday%20at%202%3F',
      });

      await pumpApp(tester);
      await settleForReal(tester);

      final draft =
          tester.widget<ComposeScreen>(find.byType(ComposeScreen)).draft;
      expect(draft.to.single.email, 'dana@example.com');
      expect(draft.subject, 'Site visit');
      expect(draft.htmlBody, contains('Thursday at 2?'));
    });

    testWidgets('an address alone is something to write to', (tester) async {
      bridge.openedWith = SharedContent.fromMap({
        'files': [],
        'mailto': 'mailto:dana@example.com',
      });

      await pumpApp(tester);
      await settleForReal(tester);

      expect(find.byType(ComposeScreen), findsOneWidget);
    });

    test('what the app put beside the link is kept over the link, and the '
        'recipients of both are taken', () {
      final content = SharedContent.fromMap({
        'mailto': 'mailto:dana@example.com?subject=From%20the%20link',
        'subject': 'From the app',
        'to': ['sam@example.com', '  '],
        'cc': ['lee@example.com'],
      })!;
      expect(content.subject, 'From the app');
      expect(content.to, ['dana@example.com', 'sam@example.com']);
      expect(content.cc, ['lee@example.com']);
    });

    testWidgets('an address named in the link and beside it is there once',
        (tester) async {
      // A "Send feedback" as apps write it: the address in a mailto: link,
      // and again in the list of who it is to.
      bridge.openedWith = SharedContent.fromMap({
        'files': [],
        'mailto': 'mailto:feedback@example.com',
        'to': ['Feedback@Example.com'],
        'cc': ['feedback@example.com, dana@example.com'],
        'bcc': ['DANA@example.com', 'audit@example.com'],
      });

      await pumpApp(tester);
      await settleForReal(tester);

      final draft =
          tester.widget<ComposeScreen>(find.byType(ComposeScreen)).draft;
      expect(draft.to.map((a) => a.email), ['feedback@example.com']);
      expect(draft.cc.map((a) => a.email), ['dana@example.com']);
      expect(draft.bcc.map((a) => a.email), ['audit@example.com']);
    });
  });

  group('a mailto: link', () {
    test('is addresses, then headers, each percent-decoded', () {
      final link = MailtoLink.parse(
        'mailto:dana@example.com,sam@example.com'
        '?cc=lee@example.com&bcc=audit@example.com&to=kim@example.com'
        '&subject=Q3%20review&body=Line%20one%0D%0ALine%20two',
      )!;
      expect(link.to, ['dana@example.com,sam@example.com', 'kim@example.com']);
      expect(link.cc, ['lee@example.com']);
      expect(link.bcc, ['audit@example.com']);
      expect(link.subject, 'Q3 review');
      expect(link.body, 'Line one\nLine two');
    });

    test('keeps a plus as a plus, which a query would make a space', () {
      final link =
          MailtoLink.parse('mailto:ron+work@example.com?subject=1+1')!;
      expect(link.to, ['ron+work@example.com']);
      expect(link.subject, '1+1');
    });

    test('reads its headers whatever their case, and leaves out the rest',
        () {
      final link = MailtoLink.parse(
        'MAILTO:?To=dana@example.com&Subject=Hi&In-Reply-To=%3Cx@y%3E',
      )!;
      expect(link.to, ['dana@example.com']);
      expect(link.subject, 'Hi');
    });

    test('broken encoding is kept as it came, and anything else is no link',
        () {
      expect(MailtoLink.parse('mailto:dana@example.com?subject=100%')!.subject,
          '100%');
      // Bytes that are not UTF-8: a different failure underneath, and the
      // same answer.
      final latin = MailtoLink.parse('mailto:dana@example.com?subject=Caf%E9')!;
      expect(latin.to, ['dana@example.com']);
      expect(latin.subject, 'Caf%E9');
      expect(MailtoLink.parse('https://example.com'), isNull);
    });
  });

  // Android's half, which no Dart test runs: what it reads off the intent,
  // and the filters that offer the app at all.
  group('the Android half', () {
    const main = 'android/app/src/main';
    final bridge =
        File('$main/kotlin/com/rdvir/mailtree/FilesBridge.kt').readAsStringSync();
    final take = RegExp(r'fun takeShare\([\s\S]*?\n    }')
        .firstMatch(bridge)!
        .group(0)!;

    test('reads styled text as well as plain', () {
      // Bundle.getString is null for text with spans in it.
      expect(take, contains('getCharSequenceExtra(Intent.EXTRA_TEXT)'));
      expect(take, isNot(contains('getStringExtra(Intent.EXTRA_TEXT)')));
    });

    test('hands over who it is to, under the names Dart reads', () {
      for (final extra in ['EXTRA_EMAIL', 'EXTRA_CC', 'EXTRA_BCC']) {
        expect(take, contains('addresses(intent, Intent.$extra)'));
      }
      for (final key in ['"to"', '"cc"', '"bcc"', '"mailto"']) {
        expect(take, contains('$key to '), reason: key);
      }
    });

    test('takes files only from a share, never from a link', () {
      expect(take, contains('if (sharing) {'));
      expect(take, contains('else if (action == Intent.ACTION_SEND_MULTIPLE)'));
    });

    test('is offered for mailto: links, sent and tapped', () {
      final manifest = File('$main/AndroidManifest.xml').readAsStringSync();
      final activity = RegExp(
        r'<activity\s+android:name="\.MainActivity"[\s\S]*?</activity>',
      ).firstMatch(manifest)!.group(0)!;
      final filters = RegExp(r'<intent-filter>[\s\S]*?</intent-filter>')
          .allMatches(activity)
          .map((m) => m.group(0)!)
          .where((f) => f.contains('android:scheme="mailto"'))
          .toList();
      expect(filters.where((f) => f.contains('action.SENDTO')), hasLength(1));
      expect(
        filters.where((f) =>
            f.contains('action.VIEW') && f.contains('category.BROWSABLE')),
        hasLength(1),
      );
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
