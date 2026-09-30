import 'dart:async';
import 'dart:math';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/sync/pass_signal.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// The app keeps what is on screen current while it is open.
///
/// Ron: "It looks like the app is not syncing when it's open." A list
/// asked the server only when it was built, and the background sync's new
/// mail reached it only when the app was left and brought back.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  const inbox = 'acct-1:INBOX';

  ProviderContainer container(SampleMailEngine engine) {
    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// The list, kept on screen as the app keeps it.
  Future<List<MailMessage>> onScreen(ProviderContainer c) {
    c.listen(messagesProvider(inbox), (_, _) {});
    return c.read(messagesProvider(inbox).future);
  }

  List<String> subjects(ProviderContainer c) => [
        for (final m in c.read(messagesProvider(inbox)).value!) m.subject,
      ];

  group('asked again,', () {
    test('a list on screen shows the mail that came while it was open',
        () async {
      final engine = _GrowingEngine(inbox)..arrive(3);
      final c = container(engine);
      await onScreen(c);
      expect(subjects(c).first, 'Message 3');

      engine.arrive(1);
      c.read(listRefreshProvider.notifier).ping();
      await pumpEventQueue();

      expect(subjects(c), hasLength(4));
      expect(subjects(c).first, 'Message 4');
    });

    test('is asked in place, not drawn afresh', () async {
      // Rebuilt, the list would go through loading and lose its own
      // changes in hand.
      final engine = _GrowingEngine(inbox)..arrive(3);
      final c = container(engine);
      await onScreen(c);
      final states = <AsyncValue<List<MailMessage>>>[];
      c.listen(messagesProvider(inbox), (_, next) => states.add(next));

      engine.arrive(1);
      c.read(listRefreshProvider.notifier).ping();
      await pumpEventQueue();

      expect(states.where((s) => s.isLoading), isEmpty);
      expect(states.last.value, hasLength(4));
    });

    test('a message on its way out does not come back', () async {
      // The server still has it until the delete lands.
      final engine = _GrowingEngine(inbox)..arrive(3);
      final c = container(engine);
      await onScreen(c);
      final gone = MailMessage.idFor(inbox, 2);
      engine.holdDelete = Completer<void>();
      final deleting = c.read(messagesProvider(inbox).notifier).delete([gone]);

      engine.arrive(1);
      c.read(listRefreshProvider.notifier).ping();
      await pumpEventQueue();

      final ids = c.read(messagesProvider(inbox)).value!.map((m) => m.id);
      expect(ids, isNot(contains(gone)));
      expect(ids, contains(MailMessage.idFor(inbox, 4)),
          reason: 'what came meanwhile is still shown');
      engine.holdDelete!.complete();
      await deleting;
    });

    test('once at a time: an ask while one is on its way is not sent',
        () async {
      final engine = _GrowingEngine(inbox)..arrive(3);
      final c = container(engine);
      await onScreen(c);
      final before = engine.loads;
      engine.holdLoad = Completer<void>();

      c.read(listRefreshProvider.notifier).ping();
      await pumpEventQueue();
      c.read(listRefreshProvider.notifier).ping();
      await pumpEventQueue();
      engine.holdLoad!.complete();
      await pumpEventQueue();

      expect(engine.loads - before, 1);
    });

    test('keeps as deep as the list was scrolled', () async {
      final engine = _GrowingEngine(inbox)..arrive(Messages.pageSize + 10);
      final c = container(engine);
      await onScreen(c);
      await c.read(messagesProvider(inbox).notifier).loadMore();
      expect(subjects(c), hasLength(Messages.pageSize + 10));

      engine.arrive(1);
      c.read(listRefreshProvider.notifier).ping();
      await pumpEventQueue();

      expect(subjects(c), hasLength(Messages.pageSize + 11),
          reason: 'not snapped back to the first page');
    });

    test('the folder tree asks again as well, for its counts', () async {
      final engine = _CountingFolders();
      final c = container(engine);
      c.listen(foldersProvider, (_, _) {});
      await c.read(foldersProvider.future);
      // The sample server answers after a moment, as a real one does: its
      // listing on opening is let finish first.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final before = engine.folderLoads;
      final accounts = (await c.read(accountsProvider.future)).length;

      c.read(listRefreshProvider.notifier).ping();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(engine.folderLoads - before, accounts);
    });
  });

  group('the app, while open,', () {
    Future<ProviderContainer> pumpShell(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
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

    void goTo(WidgetTester tester, List<AppLifecycleState> states) {
      for (final s in states) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    testWidgets('asks again every two minutes while in front, and not in '
        'the background', (tester) async {
      final c = await pumpShell(tester);
      final start = c.read(listRefreshProvider);

      await tester.pump(AppShell.askEvery);
      expect(c.read(listRefreshProvider), start + 1);

      goTo(tester, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      await tester.pump(AppShell.askEvery * 3);
      expect(c.read(listRefreshProvider), start + 1,
          reason: 'the background sync has the mail then');

      goTo(tester, const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pumpAndSettle();
      await tester.pump(AppShell.askEvery);
      expect(c.read(listRefreshProvider), start + 2);
    });

    testWidgets('a background pass that says it is done has the lists asked '
        'at once', (tester) async {
      final c = await pumpShell(tester);
      final start = c.read(listRefreshProvider);

      // As the worker does, from its own isolate in the app's process.
      announceBackgroundPassDone();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      expect(c.read(listRefreshProvider), start + 1);
      // The asking it set off, let finish.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('gone, it leaves nothing listening', (tester) async {
      await pumpShell(tester);
      expect(IsolateNameServer.lookupPortByName(backgroundPassDonePortName),
          isNotNull);

      await tester.pumpWidget(const SizedBox());

      expect(IsolateNameServer.lookupPortByName(backgroundPassDonePortName),
          isNull);
    });
  });
}

/// One folder whose server end gains mail on request, newest first, and
/// answers pages by offset the way a real one does.
class _GrowingEngine extends SampleMailEngine {
  _GrowingEngine(this.folderId);

  final String folderId;
  final List<MailMessage> server = [];
  var _next = 1;

  /// How many times the server was asked for the list.
  var loads = 0;

  /// Held open to keep a delete, or an ask, on its way.
  Completer<void>? holdDelete;
  Completer<void>? holdLoad;

  /// [count] messages arrive, each newer than anything already there.
  void arrive(int count) {
    for (var i = 0; i < count; i++) {
      final uid = _next++;
      server.insert(
        0,
        MailMessage(
          id: MailMessage.idFor(folderId, uid),
          accountId: 'acct-1',
          folderId: folderId,
          uid: uid,
          subject: 'Message $uid',
          preview: '',
          from: const MailAddress(email: 'dana@example.com'),
          to: const [],
          date: DateTime(2026, 9, 1).add(Duration(minutes: uid)),
          isRead: true,
        ),
      );
    }
  }

  List<MailMessage> _page(int offset, int limit) => offset >= server.length
      ? const []
      : List.of(server.sublist(offset, min(server.length, offset + limit)));

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      const [];

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    loads++;
    await holdLoad?.future;
    return _page(offset, limit);
  }

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    await holdDelete?.future;
    server.removeWhere((m) => messageIds.contains(m.id));
    return const [];
  }
}

/// The sample accounts, counting how often their folders are listed.
class _CountingFolders extends SampleMailEngine {
  var folderLoads = 0;

  @override
  Future<List<MailFolder>> loadFolders(String accountId) {
    folderLoads++;
    return super.loadFolders(accountId);
  }
}
