import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_providers.dart';
import 'package:myemail/ui/shell/app_shell.dart';

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
  });

  testWidgets('coming back with nothing tapped changes nothing', (tester) async {
    final c = await pump(tester);
    final folder = c.read(effectiveSelectedFolderIdProvider);

    await comeBack(tester);

    expect(c.read(effectiveSelectedFolderIdProvider), folder);
  });
}

/// A message in some folder other than the one the app opens on.
Future<MailMessage> _aMessageOutsideTheInbox(SampleMailEngine engine) async {
  final account = (await engine.loadAccounts()).first;
  for (final folder in await engine.loadFolders(account.id)) {
    if (folder.displayName == 'Travel') {
      return (await engine.loadMessages(folder.id)).first;
    }
  }
  throw StateError('the sample data has a Travel folder');
}

/// The sample engine, counting what the app asks it for.
class _CountingEngine extends SampleMailEngine {
  int messageLoads = 0;
  int folderLoads = 0;

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) {
    messageLoads++;
    return super.loadMessages(folderId, offset: offset, limit: limit);
  }

  @override
  Future<List<MailFolder>> loadFolders(String accountId) {
    folderLoads++;
    return super.loadFolders(accountId);
  }
}
