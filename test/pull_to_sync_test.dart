import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
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
