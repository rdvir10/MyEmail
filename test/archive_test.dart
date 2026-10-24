import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_actions.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/messages/selection_bar.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/ribbon.dart';

import 'fakes/fake_webview.dart';

/// Archive everywhere (#39): beside Delete on the message and in the
/// ribbon, on the ticked messages, from Backspace, and on Gmail too, where
/// it takes the folder's label off as Gmail's own Archive does.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  MailFolder folder(String id, FolderRole role, {bool takesMail = true}) =>
      MailFolder(
        id: 'a:$id',
        accountId: 'a',
        name: id,
        path: id,
        role: role,
        capabilities: takesMail
            ? const FolderCapabilities.userFolder()
            : const FolderCapabilities.systemFolder(canAcceptMessages: false),
      );

  test('where Archive puts mail: a folder that takes it, else All Mail', () {
    final allMail = folder('All Mail', FolderRole.archive, takesMail: false);
    final archive = folder('Archive', FolderRole.archive);
    final inbox = folder('INBOX', FolderRole.inbox);

    expect(
      archiveTargetFor({
        'a': [inbox, allMail],
      }, 'a'),
      'a:All Mail',
    );
    expect(
      archiveTargetFor({
        'a': [inbox, allMail, archive],
      }, 'a'),
      'a:Archive',
    );
    expect(
      archiveTargetFor({
        'a': [inbox],
      }, 'a'),
      isNull,
    );
    expect(archiveTargetFor(const {}, 'a'), isNull);
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    SampleMailEngine? engine,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      if (engine != null) mailEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: AppShell()),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  List<String> rows(ProviderContainer c) => [
        for (final m in c.read(sortedMessagesProvider(
            c.read(effectiveSelectedFolderIdProvider)!)))
          m.id,
      ];

  testWidgets('on a phone, beside Delete on the message, and the message '
      'screen goes with it', (tester) async {
    final c = await pump(tester, size: const Size(412, 915));
    final message =
        tester.widget<MessageTile>(find.byType(MessageTile).first).message;
    await tester.tap(find.byType(MessageTile).first);
    await tester.pumpAndSettle();

    final archive = find.byTooltip('Archive');
    expect(
      tester.getCenter(archive).dx,
      lessThan(tester.getCenter(find.byTooltip('Delete')).dx),
    );
    await tester.tap(archive);
    await tester.pumpAndSettle();

    expect(find.byType(MessageScreen), findsNothing);
    expect(find.text('Message archived'), findsOneWidget);
    expect(rows(c), isNot(contains(message.id)));
  });

  testWidgets('not offered on a message in the archive already',
      (tester) async {
    final c = await pump(tester);
    final allMail = c
        .read(foldersProvider)
        .value!['acct-personal']!
        .firstWhere((f) => f.role == FolderRole.archive);
    c.read(selectedFolderIdProvider.notifier).select(allMail.id);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MessageTile).first);
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('Archive'),
      ),
      findsNothing,
    );
  });

  testWidgets('in the ribbon, beside Delete', (tester) async {
    final c = await pump(tester);
    final before = rows(c);
    await tester.tap(find.byType(MessageTile).first);
    await tester.pumpAndSettle();
    final opened = c.read(selectedMessageIdProvider);

    await tester.tap(find.descendant(
      of: find.byType(Ribbon),
      matching: find.text('Archive'),
    ));
    await tester.pumpAndSettle();

    expect(rows(c), hasLength(before.length - 1));
    expect(rows(c), isNot(contains(opened)));
  });

  testWidgets('the ticked ones, from two accounts, each into its own, with '
      'one Undo for all', (tester) async {
    final engine = SampleMailEngine();
    final c = await pump(tester, engine: engine);
    c.read(selectedFolderIdProvider.notifier).select(kUnifiedInboxId);
    await tester.pumpAndSettle();
    final list = c.read(sortedMessagesProvider(kUnifiedInboxId));
    final personal = list.firstWhere((m) => m.accountId == 'acct-personal');
    final side = list.firstWhere((m) => m.accountId == 'acct-side');
    c.read(selectedMessageIdsProvider.notifier)
        .addAll([personal.id, side.id]);
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byType(SelectionBar),
      matching: find.byTooltip('Archive'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('2 messages archived'), findsOneWidget);
    final after = c.read(sortedMessagesProvider(kUnifiedInboxId));
    expect(after.map((m) => m.id), isNot(contains(personal.id)));
    expect(after.map((m) => m.id), isNot(contains(side.id)));
    expect(c.read(selectedMessageIdsProvider), isEmpty);
    for (final account in ['acct-personal', 'acct-side']) {
      final all = await tester.runAsync(
          () => engine.loadMessages('$account:[Gmail]/All Mail'));
      final subject = account == 'acct-personal'
          ? personal.subject
          : side.subject;
      expect(all!.any((m) => m.subject == subject), isTrue,
          reason: 'into $account\'s own');
    }

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    final back = await tester.runAsync(() async => [
          ...await engine.loadMessages('acct-personal:INBOX'),
          ...await engine.loadMessages('acct-side:INBOX'),
        ]);
    expect(back!.map((m) => m.subject),
        containsAll([personal.subject, side.subject]));
  });

  testWidgets('Backspace archives what is ticked', (tester) async {
    final c = await pump(tester);
    final ids = rows(c);
    await tester.tap(find.byType(MessageTile).first);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(c.read(selectedMessageIdsProvider), ids.take(2).toSet());

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(find.text('2 messages archived'), findsOneWidget);
    expect(rows(c).toSet().intersection(ids.take(2).toSet()), isEmpty);
  });
}
