import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/attachment_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// What a message brings with it, its body, its files and the pictures in
/// it, asked for when it opens: what happens when they cannot be had, and
/// what is held on to afterwards.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(WidgetTester tester, MailEngine engine) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
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

  /// Until the pane says the body could not be had, however long anything
  /// spends asking again by itself first.
  Future<void> untilFailed(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      if (inPane(find.textContaining('Could not load the message'))
          .evaluate()
          .isNotEmpty) {
        return;
      }
      await tester.pump(const Duration(seconds: 5));
    }
    fail('the pane never said the message could not be loaded');
  }

  void open(ProviderContainer c, String id) =>
      c.read(selectedMessageIdProvider.notifier).select(id);

  List<MailMessage> listed(ProviderContainer c) => c
      .read(messagesProvider(c.read(effectiveSelectedFolderIdProvider)!))
      .value!;

  testWidgets('a body that could not be loaded offers Try again, which '
      'loads it', (tester) async {
    // Opened on the train with no signal. Back online, the pane went on
    // saying it could not load the message, with nothing on it to tap.
    final engine = _Offline();
    await pump(tester, engine);
    await untilFailed(tester);

    engine.offline = false;
    await tester.tap(inPane(find.text('Try again')));
    await tester.pumpAndSettle();

    expect(inPane(find.text('Back online')), findsOneWidget);
    expect(inPane(find.textContaining('Could not load')), findsNothing);
  });

  testWidgets('a message that failed to load asks again when it is opened '
      'again', (tester) async {
    // The failure was kept for as long as Android kept the app: the same
    // message, opened an hour later with a signal, still said it could not
    // be loaded.
    final engine = _Offline();
    final c = await pump(tester, engine);
    final failed = c.read(selectedMessageIdProvider)!;
    await untilFailed(tester);

    engine.offline = false;
    open(c, listed(c).firstWhere((m) => m.id != failed).id);
    await tester.pumpAndSettle();
    open(c, failed);
    await tester.pumpAndSettle();

    expect(inPane(find.text('Back online')), findsOneWidget);
    expect(inPane(find.textContaining('Could not load')), findsNothing);
  });

  group('a failure is said at once, and not asked again by itself', () {
    // Riverpod asked ten times more over half a minute, a spinner in the
    // pane throughout, each time another request to the server.
    testWidgets('for the body', (tester) async {
      final engine = _Offline()..offline = false;
      final c = await pump(tester, engine);
      final other = listed(c)
          .firstWhere((m) => m.id != c.read(selectedMessageIdProvider));
      engine.offline = true;

      open(c, other.id);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(inPane(find.textContaining('Could not load the message')),
          findsOneWidget);
      await tester.pump(const Duration(minutes: 1));
      expect(engine.bodiesAsked[other.id], 1);
    });

    test('for the files and the pictures', () async {
      final engine = _UnlistedFiles();
      final c = ProviderContainer(
        overrides: [mailEngineProvider.overrideWithValue(engine)],
      );
      addTearDown(c.dispose);
      const id = 'a:INBOX#1';
      c.listen(attachmentsProvider(id), (_, _) {});
      c.listen(inlinePicturesProvider(id), (_, _) {});
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(engine.filesAsked, 1, reason: 'once between them');
      for (final failed in [
        c.read(attachmentsProvider(id)),
        c.read(inlinePicturesProvider(id)),
      ]) {
        expect(failed.error, isA<ConnectionFailed>());
        expect(failed.isLoading, isFalse, reason: 'not a spinner');
      }
    });
  });

  group('once a message is closed', () {
    // Every message read kept its body, and its pictures as data: text of
    // up to 15 MB, until Android stopped the app.
    final ids = [for (var i = 1; i <= 8; i++) 'a:INBOX#$i'];

    Future<ProviderContainer> readAll(_WithPictures engine) async {
      final c = ProviderContainer(
        overrides: [mailEngineProvider.overrideWithValue(engine)],
      );
      addTearDown(c.dispose);
      for (final id in ids) {
        await c.read(inlinePicturesProvider(id).future);
      }
      await c.pump();
      return c;
    }

    test('only the last few read keep what they brought', () async {
      final c = await readAll(_WithPictures());

      final held = [
        for (final id in ids)
          if (c.exists(messageBodyProvider(id))) id,
      ];
      expect(held, isNotEmpty);
      expect(held.length, lessThanOrEqualTo(4), reason: 'a few, not a day');
      expect(held, ids.sublist(ids.length - held.length),
          reason: 'the ones read last');
      for (final id in ids) {
        // A message's files and pictures go with its body.
        expect(c.exists(attachmentsProvider(id)), held.contains(id),
            reason: '$id files');
        expect(c.exists(inlinePicturesProvider(id)), held.contains(id),
            reason: '$id pictures');
      }
    });

    test('going back to the last one asks the server nothing', () async {
      final engine = _WithPictures();
      final c = await readAll(engine);
      final asked = engine.asked.length;

      await c.read(inlinePicturesProvider(ids.last).future);
      await c.read(messageBodyProvider(ids.last).future);

      expect(engine.asked, hasLength(asked));
    });
  });
}

/// A logo named by Content-ID in every body, and everything asked of the
/// server written down.
class _WithPictures extends SampleMailEngine {
  final asked = <String>[];

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    asked.add('body $messageId');
    return const MailBody(text: 'Hi', html: '<p>Hi</p><img src="cid:logo@x">');
  }

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async {
    asked.add('files $messageId');
    return const [
      MailAttachment(
        id: 'p1',
        name: 'logo.png',
        mimeType: 'image/png',
        sizeBytes: 4,
        isInline: true,
        contentId: 'logo@x',
      ),
    ];
  }

  @override
  Future<Uint8List> fetchAttachment(String messageId, String id) async {
    asked.add('picture $messageId');
    return Uint8List.fromList([137, 80, 78, 71]);
  }
}

/// The sample engine with no connection until told otherwise, and a body
/// in plain text once there is one, so the pane shows it as text.
class _Offline extends SampleMailEngine {
  bool offline = true;

  /// How many times each body was asked for.
  final bodiesAsked = <String, int>{};

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    bodiesAsked[messageId] = (bodiesAsked[messageId] ?? 0) + 1;
    if (offline) throw const ConnectionFailed('No connection.');
    return const MailBody(text: 'Back online');
  }
}

/// A body naming a picture, and files that cannot be listed.
class _UnlistedFiles extends SampleMailEngine {
  var filesAsked = 0;

  @override
  Future<MailBody> loadMessageBody(String messageId) async =>
      const MailBody(text: 'Hi', html: '<img src="cid:logo@x">');

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async {
    filesAsked++;
    throw const ConnectionFailed('No connection.');
  }
}
