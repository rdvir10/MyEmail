import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_now.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Pulling the message list down checks for mail, the way every mail app
/// answers that gesture. The same check as the ribbon's Sync button, which
/// on a phone is not there to press.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late _CountingEngine engine;

  setUp(() => engine = _CountingEngine());

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
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
  }

  /// The message list, not the folder tree, which scrolls too.
  Finder messageList() => find.ancestor(
        of: find.byType(MessageTile).first,
        matching: find.byType(Scrollable),
      );

  Future<void> pullDown(WidgetTester tester) async {
    // Far enough to pass the indicator's threshold, and slowly, so it reads
    // as a pull rather than a fling.
    await tester.fling(messageList().first, const Offset(0, 400), 800);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  testWidgets('on a phone, pulling down checks every account', (tester) async {
    await pump(tester, const Size(400, 900));
    final before = engine.folderLoads;

    await pullDown(tester);

    expect(engine.folderLoads, greaterThan(before),
        reason: 'the folder counts are refreshed, not just the list');
  });

  testWidgets('and reads the list again', (tester) async {
    await pump(tester, const Size(400, 900));
    final before = engine.messageLoads;

    await pullDown(tester);

    expect(engine.messageLoads, greaterThan(before));
  });

  testWidgets('one account failing does not stop the others being checked',
      (tester) async {
    // It stopped at the first account that failed: one expired sign-in, and
    // no other account and not the list was ever refreshed by hand.
    await pump(tester, const Size(400, 900));
    engine.refused = 'acct-personal';
    final before = engine.loadsOf['acct-side'] ?? 0;
    final listBefore = engine.messageLoads;

    await pullDown(tester);

    expect(engine.loadsOf['acct-side'] ?? 0, greaterThan(before));
    expect(engine.messageLoads, greaterThan(listBefore));
    expect(find.textContaining('Could not sync'), findsOneWidget);
  });

  group('Sync now', () {
    // It read the list again, which drew it from what the device already
    // had and asked the server behind it, quietly: the spinner stopped
    // before the mail being waited for had been looked for, and a list
    // that could not be checked said nothing at all.
    const inbox = 'acct-personal:INBOX';

    Future<(ProviderContainer, WidgetRef)> open(WidgetTester tester) async {
      final c = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          mailEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(c.dispose);
      late WidgetRef widgetRef;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: Consumer(builder: (context, ref, _) {
            widgetRef = ref;
            // The tree and the list, as on screen.
            ref.watch(foldersProvider);
            ref.watch(messagesProvider(inbox));
            return const SizedBox();
          }),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      return (c, widgetRef);
    }

    testWidgets('is over once the open list has been checked, not before',
        (tester) async {
      final (_, ref) = await open(tester);
      final server = engine.holdList = Completer<void>();
      var done = false;

      unawaited(syncNow(ref, inbox).then((_) => done = true));
      await tester.pump(const Duration(seconds: 1));
      expect(done, isFalse, reason: 'the server has not answered for it');

      server.complete();
      await tester.pump(const Duration(seconds: 1));
      expect(done, isTrue);
    });

    testWidgets('a list that cannot be checked says so', (tester) async {
      final (_, ref) = await open(tester);
      engine.listFails = inbox;

      Object? thrown;
      unawaited(syncNow(ref, inbox).catchError((Object e) => thrown = e));
      await tester.pump(const Duration(seconds: 1));

      expect(thrown, isA<SyncIncomplete>());
      expect('$thrown', 'Personal: The folder is not there.');
    });

    testWidgets('and an account that failed is said once, not twice',
        (tester) async {
      final (_, ref) = await open(tester);
      engine.refused = 'acct-personal';
      engine.listFails = inbox;

      Object? thrown;
      unawaited(syncNow(ref, inbox).catchError((Object e) => thrown = e));
      await tester.pump(const Duration(seconds: 1));

      expect('$thrown', 'Personal: Sign in again.');
    });
  });

  testWidgets('a list too short to fill the screen can still be pulled',
      (tester) async {
    // A list with a scroll controller of its own did not scroll at all while
    // it fitted on screen, and the pull is a scroll: an inbox of thirteen on
    // a tablet never checked for mail however hard it was pulled.
    engine.keep = 2;
    await pump(tester, const Size(1400, 900));
    final before = engine.messageLoads;

    await pullDown(tester);

    expect(engine.messageLoads, greaterThan(before));
  });

  testWidgets('and so can an empty folder', (tester) async {
    engine.keep = 0;
    await pump(tester, const Size(400, 900));
    final before = engine.messageLoads;

    await tester.fling(
      find.ancestor(
        of: find.textContaining('Nothing in'),
        matching: find.byType(Scrollable),
      ),
      const Offset(0, 400),
      800,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(engine.messageLoads, greaterThan(before));
  });

  testWidgets('the indicator is there on a tablet too', (tester) async {
    // A tablet has the ribbon's Sync button, but a finger on a list still
    // expects the pull to work.
    await pump(tester, const Size(1400, 900));

    expect(find.byType(RefreshIndicator), findsOneWidget);
  });
}

/// The sample engine, counting what the app asks it for.
class _CountingEngine extends SampleMailEngine {
  int messageLoads = 0;
  int folderLoads = 0;
  final loadsOf = <String, int>{};

  /// An account whose folders cannot be listed: a sign-in to renew.
  String? refused;

  /// A folder whose messages cannot be fetched.
  String? listFails;

  /// Held open to keep the server's answer for a list on its way.
  Completer<void>? holdList;

  /// How many messages each folder shows, where not all of them.
  int? keep;

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    messageLoads++;
    await holdList?.future;
    if (folderId == listFails) {
      throw const AuthenticationFailed('The folder is not there.');
    }
    final all = await super.loadMessages(folderId, offset: offset, limit: limit);
    return [...all.take(keep ?? all.length)];
  }

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final all =
        await super.cachedMessages(folderId, offset: offset, limit: limit);
    return [...all.take(keep ?? all.length)];
  }

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    folderLoads++;
    loadsOf[accountId] = (loadsOf[accountId] ?? 0) + 1;
    if (accountId == refused) {
      throw const AuthenticationFailed('Sign in again.');
    }
    return super.loadFolders(accountId);
  }
}
