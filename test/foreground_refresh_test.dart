import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/notifications/notification_action_isolate.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/data/notifications/pending_actions.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_providers.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fakes/fake_webview.dart';

/// What happens when the app comes back to the front.
///
/// The background pass writes new mail into the database the lists read
/// from, but a list already on screen holds what it read last time. The
/// notification said "new message" and the list did not show it. These pin
/// the two halves of the fix: the lists re-read, and a notification tapped
/// while the app was running is acted on.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  late _CountingEngine engine;
  late FakeMailNotifier notifier;

  setUp(() {
    engine = _CountingEngine();
    notifier = FakeMailNotifier(permitted: true);
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        mailNotifierProvider.overrideWithValue(notifier),
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

  /// Away and back, through every state in between: the framework asserts
  /// the order Android would use, and a jump straight to resumed throws.
  Future<void> comeBack(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// Focus taken and given back without the app going away: the shade
  /// pulled down and pushed up, a system dialog, the other app tapped in
  /// split screen.
  Future<void> focusBack(WidgetTester tester) async {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('focus given back reads nothing again', (tester) async {
    // In split screen every tap between the two apps listed every
    // account's folders and resynced the lists on screen.
    await pump(tester);
    final messages = engine.messageLoads;
    final folders = engine.folderLoads;

    await focusBack(tester);

    expect(engine.messageLoads, messages);
    expect(engine.folderLoads, folders);
  });

  testWidgets('but a notification tapped from the shade is still opened',
      (tester) async {
    final c = await pump(tester);
    final elsewhere =
        (await tester.runAsync(() => _aMessageOutsideTheInbox(engine)))!;

    notifier.launchPayload = elsewhere.id;
    await focusBack(tester);

    expect(c.read(selectedMessageIdProvider), elsewhere.id);
  });

  testWidgets('and one just arrived opens at once, from the device',
      (tester) async {
    // A tap on a notification over the app in front only takes focus
    // away and gives it back. The worker stores the message before it
    // posts the notification, but the list heard of it only once the whole
    // pass was done and its own server had answered: on the phone the
    // message opened seconds later, and on the tablet the list, not
    // holding it, landed on another message instead.
    final c = await pump(tester);
    final account = (await tester.runAsync(engine.loadAccounts))!.first;
    final inbox = MailFolder.idFor(account.id, 'INBOX');
    c.read(selectedFolderIdProvider.notifier).select(inbox);
    await tester.pumpAndSettle();
    final arrived = engine.deliver(inbox);
    // A work mailbox slow to answer.
    engine.holdLoads = Completer<void>();

    notifier.launchPayload = arrived.id;
    await focusBack(tester);

    expect(c.read(selectedMessageProvider)?.id, arrived.id);
    engine.holdLoads!.complete();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('and a button pressed in the shade is carried out',
      (tester) async {
    // Pressed with the app behind the shade, then the shade pushed back
    // up: the press is written down for WorkManager, which can take
    // minutes, and the app in front is the quicker way to it.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('myemail-presses'),
    ))!;
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await pump(tester);
    final message =
        (await tester.runAsync(() => _aMessageOutsideTheInbox(engine)))!;

    // Real files on a real clock, which the test's fake one never reaches.
    // Up to ten seconds of it: with other test files running alongside,
    // two seconds was sometimes not long enough for the press to be read.
    await tester.runAsync(() async {
      await PendingActions().add(PendingAction(
        actionId: NotificationActions.deleteId,
        messageId: message.id,
      ));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 200 && engine.deleted.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();

    expect(engine.deleted, [message.id]);
  });

  testWidgets('the list is read again from the cache', (tester) async {
    await pump(tester);
    final before = engine.messageLoads;

    await comeBack(tester);

    expect(engine.messageLoads, greaterThan(before),
        reason: 'what the background pass wrote has to be read to be seen');
  });

  testWidgets('and so are the folder counts', (tester) async {
    await pump(tester);
    final before = engine.folderLoads;

    await comeBack(tester);

    expect(engine.folderLoads, greaterThan(before));
  });

  testWidgets('a notification tapped while running opens its folder',
      (tester) async {
    // The tap sets a payload the shell only looked for at startup, so a tap
    // on the second notification of the day did nothing at all.
    final c = await pump(tester);
    // runAsync: the sample engine answers after a short delay, and a widget
    // test's clock only moves when the test moves it.
    final elsewhere =
        (await tester.runAsync(() => _aMessageOutsideTheInbox(engine)))!;
    expect(c.read(effectiveSelectedFolderIdProvider), isNot(elsewhere.folderId));

    notifier.launchPayload = elsewhere.id;
    await comeBack(tester);

    expect(c.read(selectedFolderIdProvider), elsewhere.folderId);
    expect(c.read(selectedMessageIdProvider), elsewhere.id);

    // And the next one, which is the tap that used to do nothing.
    final next = (await tester.runAsync(
      () => _aMessageIn(engine, 'Finance'),
    ))!;
    notifier.launchPayload = next.id;
    await comeBack(tester);

    expect(c.read(selectedFolderIdProvider), next.folderId);
    expect(c.read(selectedMessageIdProvider), next.id);
  });

  testWidgets('a button pressed in the shade while open refreshes the lists',
      (tester) async {
    // Delete on a notification is carried out in the background even with
    // the app in front, and the list went on showing the deleted message.
    await pump(tester);
    final messages = engine.messageLoads;
    final folders = engine.folderLoads;

    // What the worker does once it has carried the press out.
    await tester.runAsync(() async {
      announceActionsDone();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(engine.messageLoads, greaterThan(messages));
    expect(engine.folderLoads, greaterThan(folders));
  });

  testWidgets('but put away, a press carried out reads nothing again',
      (tester) async {
    // Push keeps the hidden app alive, and each press the worker carried
    // out had it list every account's folders and resync the open list.
    // Coming back reads them all again anyway.
    await pump(tester);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    final messages = engine.messageLoads;
    final folders = engine.folderLoads;

    await tester.runAsync(() async {
      announceActionsDone();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(engine.messageLoads, messages);
    expect(engine.folderLoads, folders);
  });

  testWidgets('coming back with nothing tapped changes nothing', (tester) async {
    final c = await pump(tester);
    final folder = c.read(effectiveSelectedFolderIdProvider);

    await comeBack(tester);

    expect(c.read(effectiveSelectedFolderIdProvider), folder);
  });
}

/// A message in some folder other than the one the app opens on.
Future<MailMessage> _aMessageOutsideTheInbox(SampleMailEngine engine) =>
    _aMessageIn(engine, 'Travel');

Future<MailMessage> _aMessageIn(SampleMailEngine engine, String name) async {
  final account = (await engine.loadAccounts()).first;
  for (final folder in await engine.loadFolders(account.id)) {
    if (folder.displayName == name) {
      return (await engine.loadMessages(folder.id)).first;
    }
  }
  throw StateError('the sample data has a $name folder');
}

/// The sample engine, counting what the app asks it for.
class _CountingEngine extends SampleMailEngine {
  int messageLoads = 0;
  int folderLoads = 0;

  /// Held open to keep the server from answering.
  Completer<void>? holdLoads;

  /// What the background pass stored, by folder, newest first.
  final _delivered = <String, List<MailMessage>>{};

  /// A new message in [folderId], on the server and stored on the device,
  /// as the worker leaves it before it posts the notification.
  MailMessage deliver(String folderId) {
    final uid = 900000 + (_delivered[folderId]?.length ?? 0);
    final message = MailMessage(
      id: MailMessage.idFor(folderId, uid),
      accountId: folderId.substring(0, folderId.indexOf(':')),
      folderId: folderId,
      uid: uid,
      subject: 'Just arrived',
      preview: '',
      from: const MailAddress(email: 'dana@example.com'),
      to: const [],
      date: DateTime.now(),
    );
    (_delivered[folderId] ??= []).insert(0, message);
    return message;
  }

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    messageLoads++;
    await holdLoads?.future;
    return [
      if (offset == 0) ...?_delivered[folderId],
      ...await super.loadMessages(folderId, offset: offset, limit: limit),
    ];
  }

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      [
        if (offset == 0) ...?_delivered[folderId],
        ...await super.cachedMessages(folderId, offset: offset, limit: limit),
      ];

  @override
  Future<List<MailFolder>> loadFolders(String accountId) {
    folderLoads++;
    return super.loadFolders(accountId);
  }

  final deleted = <String>[];

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) {
    deleted.addAll(messageIds);
    return super.deleteMessages(messageIds);
  }
}
