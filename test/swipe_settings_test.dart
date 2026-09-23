import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// A swipe set to each of the things it can be set to. Only delete, move
/// and read had been swiped in a test; archive, flag and "nothing" had only
/// been stored and read back.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    SwipeAction right = SwipeAction.move,
    SwipeAction left = SwipeAction.delete,
    SampleMailEngine? engine,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        if (engine != null) mailEngineProvider.overrideWithValue(engine),
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
    c.read(displayProvider.notifier)
      ..setSwipeRight(right)
      ..setSwipeLeft(left);
    await tester.pumpAndSettle();
    return c;
  }

  MailMessage first(WidgetTester tester) =>
      tester.widget<MessageTile>(find.byType(MessageTile).first).message;

  List<MailMessage> listOf(ProviderContainer c) =>
      c.read(messagesProvider(c.read(effectiveSelectedFolderIdProvider)!)).value!;

  Future<void> swipe(WidgetTester tester, double dx) async {
    await tester.drag(find.byType(MessageTile).first, Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('archive on Gmail says there is no Archive folder',
      (tester) async {
    // All Mail is Gmail's archive and cannot be moved into. Taken for an
    // Archive folder, the swipe failed, or seemed to do nothing at all.
    final c = await pump(tester, right: SwipeAction.archive);
    final message = first(tester);

    await swipe(tester, 500);

    expect(find.text('This account has no Archive folder.'), findsOneWidget);
    expect(listOf(c).any((m) => m.id == message.id), isTrue);
  });

  testWidgets('archive where there is an Archive folder files it there',
      (tester) async {
    final engine = _WithArchive();
    await tester.runAsync(() async {
      for (final a in await engine.loadAccounts()) {
        await engine.createFolder(accountId: a.id, name: 'Archive');
      }
    });
    final c = await pump(tester, right: SwipeAction.archive, engine: engine);
    final message = first(tester);

    await swipe(tester, 500);

    expect(find.textContaining('moved to Archive'), findsOneWidget);
    expect(listOf(c).any((m) => m.id == message.id), isFalse);
  });

  testWidgets('flag flags it and leaves it where it is', (tester) async {
    final c = await pump(tester, left: SwipeAction.toggleFlag);
    final message = first(tester);
    expect(message.isFlagged, isFalse);

    await swipe(tester, -500);

    final after = listOf(c).firstWhere((m) => m.id == message.id);
    expect(after.isFlagged, isTrue);
  });

  testWidgets('a side set to nothing does nothing', (tester) async {
    final c = await pump(tester, left: SwipeAction.none);
    final message = first(tester);
    final before = listOf(c).length;

    // Not even half-way: that side does not move, so there is no action
    // behind the row to be half-shown.
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(MessageTile).first));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    expect(find.byIcon(Icons.block), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();

    await swipe(tester, -500);

    expect(listOf(c), hasLength(before));
    final after = listOf(c).firstWhere((m) => m.id == message.id);
    expect(after.isFlagged, message.isFlagged);
    expect(after.isRead, message.isRead);
    expect(find.byType(SnackBar), findsNothing);
  });
}

/// The sample engine with an Outlook-style Archive: a folder of that name
/// that takes mail, beside Gmail's All Mail, which does not.
class _WithArchive extends SampleMailEngine {
  List<MailFolder> _marked(List<MailFolder> folders) => [
        for (final f in folders)
          f.name == 'Archive'
              ? MailFolder(
                  id: f.id,
                  accountId: f.accountId,
                  name: f.name,
                  path: f.path,
                  role: FolderRole.archive,
                  capabilities: f.capabilities,
                  parentId: f.parentId,
                  unreadCount: f.unreadCount,
                  totalCount: f.totalCount,
                  sortIndex: f.sortIndex,
                )
              : f,
      ];

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async =>
      _marked(await super.loadFolders(accountId));

  @override
  Future<List<MailFolder>> cachedFolders(String accountId) async =>
      _marked(await super.cachedFolders(accountId));
}
