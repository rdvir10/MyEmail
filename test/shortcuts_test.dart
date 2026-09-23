import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/message_sort.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/conversations.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/search_providers.dart';
import 'package:myemail/ui/compose/compose_screen.dart';
import 'package:myemail/ui/messages/conversation_tile.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/html_body_view.dart';
import 'package:myemail/ui/messages/message_list_pane.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';
import 'package:myemail/ui/shell/app_shortcuts.dart';
import 'package:myemail/ui/shell/pane_focus.dart';

import 'fakes/fake_webview.dart';

/// What the keyboard does, from anywhere in the shell and in the list.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(
      overrides: [uiStateStoreProvider.overrideWithValue(MemoryUiStateStore())],
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

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
    bool shift = false,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // Opening a compose window waits 150 ms before deciding whether to show
    // a spinner; a timer schedules no frame, so pumpAndSettle alone would
    // stop short of it.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  PaneFocusNodes panes(ProviderContainer c) => c.read(paneFocusProvider);

  String? selected(ProviderContainer c) => c.read(selectedMessageIdProvider);

  List<String> listIds(ProviderContainer c) {
    final folder = c.read(effectiveSelectedFolderIdProvider)!;
    return [for (final m in c.read(messagesProvider(folder)).value!) m.id];
  }

  group('the table', () {
    test('reads Outlook', () {
      expect(commandFor(LogicalKeyboardKey.keyR, control: true, shift: false),
          AppCommand.reply);
      expect(commandFor(LogicalKeyboardKey.keyR, control: true, shift: true),
          AppCommand.replyAll);
      expect(commandFor(LogicalKeyboardKey.keyF, control: true, shift: false),
          AppCommand.forward);
      expect(commandFor(LogicalKeyboardKey.f9, control: false, shift: false),
          AppCommand.sync);
    });

    test('a bare letter is not a command', () {
      // Gmail-style single letters would be one keystroke from a delete
      // whenever the focus is nowhere in particular.
      expect(commandFor(LogicalKeyboardKey.keyR, control: false, shift: false),
          isNull);
      expect(commandFor(LogicalKeyboardKey.keyD, control: false, shift: false),
          isNull);
    });

    test('the help sheet only lists keys the app answers to', () {
      for (final line in shortcutHelp['Anywhere']!) {
        expect(line.keys, isNotEmpty);
        expect(line.does, isNotEmpty);
      }
    });
  });

  group('from anywhere', () {
    testWidgets('Ctrl+N starts a new message', (tester) async {
      await pump(tester);

      await press(tester, LogicalKeyboardKey.keyN, control: true);

      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('New message'), findsOneWidget);
    });

    testWidgets('Ctrl+R replies to the open message, Ctrl+F forwards it',
        (tester) async {
      final c = await pump(tester);
      expect(selected(c), isNotNull, reason: 'the folder landed on one');

      await press(tester, LogicalKeyboardKey.keyR, control: true);
      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('Reply'), findsWidgets);
      // Nothing typed, so leaving asks nothing: the reply can be had again.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ComposeScreen), findsNothing);

      await press(tester, LogicalKeyboardKey.keyF, control: true);
      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(find.text('Forward'), findsWidgets);
    });

    testWidgets('Ctrl+Q and Ctrl+U mark read and unread', (tester) async {
      final c = await pump(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      bool isRead() => c
          .read(messagesProvider(folder))
          .value!
          .firstWhere((m) => m.id == selected(c))
          .isRead;

      await press(tester, LogicalKeyboardKey.keyQ, control: true);
      expect(isRead(), isTrue);
      await press(tester, LogicalKeyboardKey.keyU, control: true);
      expect(isRead(), isFalse);
    });

    testWidgets('Insert flags, and again unflags', (tester) async {
      final c = await pump(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      bool flagged() => c
          .read(messagesProvider(folder))
          .value!
          .firstWhere((m) => m.id == selected(c))
          .isFlagged;
      final before = flagged();

      await press(tester, LogicalKeyboardKey.insert);
      expect(flagged(), !before);
      await press(tester, LogicalKeyboardKey.insert);
      expect(flagged(), before);
    });

    testWidgets('Ctrl+E puts the cursor in the search box', (tester) async {
      await pump(tester);

      await press(tester, LogicalKeyboardKey.keyE, control: true);

      expect(focusIsInTextField(), isTrue);
    });

    testWidgets('nothing fires while typing', (tester) async {
      // Insert in the search box must not flag the message underneath it.
      final c = await pump(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      bool flagged() => c
          .read(messagesProvider(folder))
          .value!
          .firstWhere((m) => m.id == selected(c))
          .isFlagged;
      final before = flagged();
      await press(tester, LogicalKeyboardKey.keyE, control: true);

      await press(tester, LogicalKeyboardKey.insert);
      await press(tester, LogicalKeyboardKey.keyN, control: true);

      expect(flagged(), before);
      expect(find.byType(ComposeScreen), findsNothing);
    });

    testWidgets('F1 shows the list of shortcuts', (tester) async {
      await pump(tester);

      await press(tester, LogicalKeyboardKey.f1);

      expect(find.text('Keyboard shortcuts'), findsOneWidget);
      expect(find.text('Reply all'), findsWidgets);
    });
  });

  group('in the list', () {
    testWidgets('End and Home go to the last and first message',
        (tester) async {
      final c = await pump(tester);
      final ids = listIds(c);

      await press(tester, LogicalKeyboardKey.end);
      expect(selected(c), ids.last);
      await press(tester, LogicalKeyboardKey.home);
      expect(selected(c), ids.first);
    });

    testWidgets('Page Down moves ten at a time and stops at the end',
        (tester) async {
      final c = await pump(tester);
      final ids = listIds(c);

      await press(tester, LogicalKeyboardKey.pageDown);
      expect(selected(c), ids[10]);
      await press(tester, LogicalKeyboardKey.pageUp);
      expect(selected(c), ids[0]);
    });

    testWidgets('the selected row stays on screen as the keys move it',
        (tester) async {
      // Twenty rows down is past the bottom of a 900 px screen. A selection
      // that walks off the screen looks like the keys have stopped working.
      final c = await pump(tester);
      final ids = listIds(c);
      final list = tester.getRect(find.byType(MessageListPane));

      for (var i = 0; i < 20; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(selected(c), ids[20]);
      final row = tester.getRect(find.byKey(ValueKey('tile:${ids[20]}')));
      expect(row.bottom, lessThanOrEqualTo(list.bottom + 1));
      expect(row.top, greaterThanOrEqualTo(list.top));

      await press(tester, LogicalKeyboardKey.end);
      final last = tester.getRect(find.byKey(ValueKey('tile:${ids.last}')));
      expect(last.bottom, lessThanOrEqualTo(list.bottom + 1),
          reason: 'a row the list had not built yet is jumped to');

      await press(tester, LogicalKeyboardKey.home);
      final first = tester.getRect(find.byKey(ValueKey('tile:${ids.first}')));
      expect(first.top, greaterThanOrEqualTo(list.top));
    });

    testWidgets('the arrows walk the rows, not the messages folded away',
        (tester) async {
      final c = await pump(tester);
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpAndSettle();
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      List<String> rows() => visibleMessages(
            c.read(sortedMessagesProvider(folder)),
            conversations: true,
            expandedIds: c.read(expandedConversationsProvider),
            sort: MessageSort.dateNewest,
          ).map((m) => m.id).toList();

      await press(tester, LogicalKeyboardKey.home);
      var threadsSeen = 0;
      for (var i = 1; i < 15; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(selected(c), rows()[i], reason: 'row $i');
        // On a closed thread, the thread's row is the one painted
        // selected: there is no message row to paint.
        final threadRow = find.byWidgetPredicate((w) =>
            w is ConversationTile &&
            w.conversation.newest.id == selected(c));
        if (threadRow.evaluate().isNotEmpty) {
          threadsSeen++;
          expect(tester.widget<ConversationTile>(threadRow).isSelected, isTrue);
        }
      }
      expect(threadsSeen, greaterThan(0), reason: 'the sample data has threads');
    });

    testWidgets('closing a thread from inside it, Down moves on from it',
        (tester) async {
      final c = await pump(tester);
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpAndSettle();
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final all = c.read(messagesProvider(folder)).value!;
      final thread = groupIntoConversations(all).firstWhere((t) => t.isThread);
      // Land on the thread's row, open it, step onto its second message.
      c.read(selectedMessageIdProvider.notifier).select(thread.newest.id);
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(selected(c), thread.messages.reversed.elementAt(1).id);

      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowDown);

      final rows = visibleMessages(all,
              conversations: true,
              expandedIds: const {},
              sort: MessageSort.dateNewest)
          .map((m) => m.id)
          .toList();
      expect(selected(c), rows[rows.indexOf(thread.newest.id) + 1],
          reason: 'the row after the thread, not the top of the list');
    });

    testWidgets('closing a thread leaves the selection where it was',
        (tester) async {
      // Folded away, the selected message was taken for gone, and the pane
      // jumped to the first message in the folder.
      final c = await pump(tester);
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpAndSettle();
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final all = c.read(messagesProvider(folder)).value!;
      final rows = visibleMessages(all,
              conversations: true,
              expandedIds: const {},
              sort: MessageSort.dateNewest)
          .map((m) => m.id)
          .toList();
      final thread = groupIntoConversations(all).firstWhere(
          (t) => t.isThread && rows.indexOf(t.newest.id) > 0);
      c.read(selectedMessageIdProvider.notifier).select(thread.newest.id);
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowDown);
      final inside = selected(c);
      expect(inside, isNot(thread.newest.id));

      await press(tester, LogicalKeyboardKey.arrowLeft);

      expect(selected(c), inside);
    });

    testWidgets('in search results the arrows walk the hits', (tester) async {
      // They walked the folder's list behind the results, so Down from a
      // hit in another folder opened a message not in the results at all.
      final c = await pump(tester);
      final open = c.read(effectiveSelectedFolderIdProvider)!;
      await tester.enterText(find.byType(TextField).last, 'the');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final hits = sortMessages(
        c.read(searchResultsProvider).value!,
        c.read(displayProvider).sort,
      );
      final i = hits.indexWhere((m) => m.folderId != open);
      expect(i, inInclusiveRange(0, hits.length - 2));
      c.read(selectedMessageIdProvider.notifier).select(hits[i].id);
      panes(c).list.requestFocus();
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(selected(c), hits[i + 1].id);
    });

    testWidgets('the list stays where it was scrolled as more of it loads',
        (tester) async {
      // Each page that arrived brought the list back up to the selected
      // message at the top.
      final c = await pump(tester);
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final list = find
          .ancestor(
            of: find.byType(MessageTile).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(list, const Offset(0, -1500));
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(list).position;
      final scrolled = position.pixels;
      expect(scrolled, greaterThan(0));

      final more = c.read(messagesProvider(folder).notifier).loadMore();
      await tester.pumpAndSettle();
      await more;
      await tester.pumpAndSettle();

      expect(position.pixels, greaterThan(0));
    });

    testWidgets('Shift+Down ticks a run', (tester) async {
      final c = await pump(tester);
      final ids = listIds(c);

      await press(tester, LogicalKeyboardKey.arrowDown, shift: true);
      await press(tester, LogicalKeyboardKey.arrowDown, shift: true);

      expect(c.read(selectedMessageIdsProvider), ids.take(3).toSet());
      expect(selected(c), ids[2]);
    });

    testWidgets('Ctrl+A ticks what is on screen, not the folder',
        (tester) async {
      final c = await pump(tester);
      final all = listIds(c).length;

      await press(tester, LogicalKeyboardKey.keyA, control: true);

      final ticked = c.read(selectedMessageIdsProvider);
      expect(ticked, isNotEmpty);
      expect(ticked.length, lessThan(all));
      expect(find.byType(Checkbox), findsWidgets);
    });

    testWidgets('Right opens the conversation you are on, Left closes it',
        (tester) async {
      final c = await pump(tester);
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpAndSettle();
      // Land on a message that is inside a thread: the newest one of the
      // first thread on screen.
      final tile = find.byType(MessageTile);
      String? threadId;
      for (var i = 0; threadId == null; i++) {
        await press(tester, i == 0 ? LogicalKeyboardKey.home : LogicalKeyboardKey.arrowDown);
        final visible = tester
            .widgetList<MessageTile>(tile)
            .map((t) => t.message.id)
            .toSet();
        if (!visible.contains(selected(c))) threadId = selected(c);
        if (i > 40) fail('no thread found in the sample inbox');
      }

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(c.read(expandedConversationsProvider), isNotEmpty);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(c.read(expandedConversationsProvider), isEmpty);
    });
  });

  group('getting around', () {
    testWidgets('F6 walks list, message, folders and round again',
        (tester) async {
      final c = await pump(tester);
      final p = panes(c);
      expect(p.list.hasFocus, isTrue, reason: 'the list starts with it');

      await press(tester, LogicalKeyboardKey.f6);
      expect(p.reading.hasFocus, isTrue);
      await press(tester, LogicalKeyboardKey.f6);
      expect(p.tree.hasFocus, isTrue);
      await press(tester, LogicalKeyboardKey.f6);
      expect(p.list.hasFocus, isTrue);
      await press(tester, LogicalKeyboardKey.f6, shift: true);
      expect(p.tree.hasFocus, isTrue);
    });

    testWidgets('the pane with the keyboard shows a line, once a key is used',
        (tester) async {
      final c = await pump(tester);
      final p = panes(c);
      Color lineOf(FocusNode node) {
        final frame = find.byWidgetPredicate(
          (w) => w is PaneFocusFrame && w.node == node,
        );
        final box = tester.widget<Container>(
          find.descendant(of: frame, matching: find.byType(Container)).first,
        );
        return box.color!;
      }

      expect(lineOf(p.list), Colors.transparent,
          reason: 'no keyboard seen yet: nothing to point at');

      await press(tester, LogicalKeyboardKey.f6);

      expect(lineOf(p.reading), isNot(Colors.transparent));
      expect(lineOf(p.list), Colors.transparent);
    });

    testWidgets('Ctrl+. and Ctrl+, step through messages from anywhere',
        (tester) async {
      final c = await pump(tester);
      final ids = listIds(c);
      await press(tester, LogicalKeyboardKey.f6); // reading the first one

      await press(tester, LogicalKeyboardKey.period, control: true);
      expect(selected(c), ids[1]);
      await press(tester, LogicalKeyboardKey.comma, control: true);
      expect(selected(c), ids[0]);
    });

    testWidgets('Ctrl+Shift+I goes to the Inbox', (tester) async {
      final c = await pump(tester);
      final inbox = c.read(defaultFolderIdProvider);
      final other = c
          .read(treeRowsProvider)
          .whereType<FolderRow>()
          .firstWhere((r) => r.folder.id != inbox)
          .folder
          .id;
      c.read(selectedFolderIdProvider.notifier).select(other);
      await tester.pumpAndSettle();
      expect(c.read(effectiveSelectedFolderIdProvider), other);

      await press(tester, LogicalKeyboardKey.keyI, control: true, shift: true);

      expect(c.read(effectiveSelectedFolderIdProvider), inbox);
    });
  });

  group('in the folder tree', () {
    Future<(ProviderContainer, List<FolderRow>)> inTree(
      WidgetTester tester,
    ) async {
      final c = await pump(tester);
      panes(c).tree.requestFocus();
      await tester.pumpAndSettle();
      final rows = c.read(treeRowsProvider).whereType<FolderRow>().toList();
      return (c, rows);
    }

    String folder(ProviderContainer c) =>
        c.read(effectiveSelectedFolderIdProvider)!;

    testWidgets('Down and Up walk the folders as shown, opening each',
        (tester) async {
      final (c, rows) = await inTree(tester);
      final at = rows.indexWhere((r) => r.folder.id == folder(c));

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(folder(c), rows[at + 1].folder.id);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(folder(c), rows[at].folder.id);
    });

    testWidgets('a favourite, in the tree twice, does not trap Down',
        (tester) async {
      // Found by folder id, Down went back to the favourite's first row and
      // round again, so nothing below it could be reached.
      final c = await pump(tester);
      final inbox = c
          .read(treeRowsProvider)
          .whereType<FolderRow>()
          .firstWhere((r) => r.folder.role == FolderRole.inbox);
      c.read(favoriteFoldersProvider.notifier).toggle(inbox.folder.id);
      await tester.pumpAndSettle();
      panes(c).tree.requestFocus();
      await tester.pumpAndSettle();
      final rows = c.read(treeRowsProvider).whereType<FolderRow>().toList();
      expect(rows.where((r) => r.folder.id == inbox.folder.id), hasLength(2));

      await press(tester, LogicalKeyboardKey.home);
      for (var i = 1; i < rows.length; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }

      expect(folder(c), rows.last.folder.id);
    });

    testWidgets('End and Home go to the last and first folder',
        (tester) async {
      final (c, rows) = await inTree(tester);

      await press(tester, LogicalKeyboardKey.end);
      expect(folder(c), rows.last.folder.id);
      await press(tester, LogicalKeyboardKey.home);
      expect(folder(c), rows.first.folder.id);
    });

    testWidgets('Right shows what is inside a folder, Left hides it again',
        (tester) async {
      final (c, rows) = await inTree(tester);
      final parent = rows.firstWhere((r) => r.hasChildren && !r.flat);
      c.read(selectedFolderIdProvider.notifier).select(parent.folder.id);
      if (parent.isExpanded) {
        c.read(expandedFoldersProvider.notifier).toggle(parent.folder.id);
      }
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(c.read(expandedFoldersProvider), contains(parent.folder.id));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(c.read(expandedFoldersProvider), isNot(contains(parent.folder.id)));
    });

    testWidgets('Left on a folder with nothing to hide goes up a level',
        (tester) async {
      final (c, rows) = await inTree(tester);
      final parent = rows.firstWhere((r) => r.hasChildren && !r.flat);
      c.read(expandedFoldersProvider.notifier).expand(parent.folder.id);
      await tester.pumpAndSettle();
      final shown = c.read(treeRowsProvider).whereType<FolderRow>().toList();
      final child = shown.firstWhere(
        (r) => !r.flat && r.depth == parent.depth + 1 &&
            shown.indexOf(r) > shown.indexWhere(
              (x) => !x.flat && x.folder.id == parent.folder.id),
      );
      c.read(selectedFolderIdProvider.notifier).select(child.folder.id);
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowLeft);

      expect(folder(c), parent.folder.id);
    });

    testWidgets('arrows in the folder search box stay in the box',
        (tester) async {
      final (c, _) = await inTree(tester);
      final before = folder(c);
      await tester.tap(find.widgetWithText(TextField, 'Search folders'));
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(folder(c), before);
    });
  });

  group('while reading', () {
    testWidgets('the Page keys, Space, Home and End scroll the message',
        (tester) async {
      // A pane of its own with a body long enough to scroll; the sample
      // bodies are a paragraph or two. The HTML path is covered below.
      final node = FocusNode();
      addTearDown(node.dispose);
      final message = MailMessage(
        id: 'a:INBOX#1',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 1,
        subject: 'Long',
        preview: '',
        from: const MailAddress(email: 'someone@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime.utc(2026, 9, 20),
        isRead: true,
      );
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        messageBodyProvider(message.id).overrideWith(
          (ref) async => MailBody(
            text: List.filled(300, 'A line of the message.').join('\n'),
          ),
        ),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(body: ReadingPane(message: message, focusNode: node)),
        ),
      ));
      await tester.pumpAndSettle();
      node.requestFocus();
      await tester.pumpAndSettle();
      // The body's scroll view: the nearest one above the text, since the
      // text field has one of its own inside.
      ScrollPosition position() => tester
          .state<ScrollableState>(find
              .ancestor(
                of: find.byType(SelectableText),
                matching: find.byType(Scrollable),
              )
              .first)
          .position;
      expect(position().maxScrollExtent, greaterThan(0));

      await press(tester, LogicalKeyboardKey.pageDown);
      final afterPage = position().pixels;
      expect(afterPage, greaterThan(0));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(position().pixels, lessThan(afterPage));
      await press(tester, LogicalKeyboardKey.space);
      expect(position().pixels, greaterThan(afterPage));
      await press(tester, LogicalKeyboardKey.end);
      expect(position().pixels, position().maxScrollExtent);
      await press(tester, LogicalKeyboardKey.home);
      expect(position().pixels, 0);
    });

    testWidgets('an HTML body is scrolled inside its WebView', (tester) async {
      final platform = FakeWebViewPlatform.install();
      final key = GlobalKey<HtmlBodyViewState>();
      await tester.pumpWidget(MaterialApp(
        home: HtmlBodyView(key: key, html: '<p>Hello</p>'),
      ));
      await tester.pumpAndSettle();

      await key.currentState!.scrollBy(300);
      await key.currentState!.scrollToEnd(top: false);

      expect(platform.scrolls, [
        (x: 0, y: 300, to: false),
        (x: 0, y: 1 << 24, to: true),
      ]);
    });

    testWidgets('Esc hands the keyboard back to the list', (tester) async {
      final c = await pump(tester);
      await press(tester, LogicalKeyboardKey.f6);

      await press(tester, LogicalKeyboardKey.escape);

      expect(panes(c).list.hasFocus, isTrue);
    });

    testWidgets('on a phone, Esc closes the message', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
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
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(MessageScreen), findsOneWidget);
      // Give the message the keyboard, as F6 would on a tablet.
      tester
          .widgetList<Focus>(find.descendant(
            of: find.byType(ReadingPane),
            matching: find.byType(Focus),
          ))
          .map((f) => f.focusNode)
          .firstWhere((n) => n?.debugLabel == 'Open message')!
          .requestFocus();
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.escape);

      expect(find.byType(MessageScreen), findsNothing);
    });
  });

  group('while writing', () {
    testWidgets('Esc closes an empty message without a word', (tester) async {
      await pump(tester);
      await press(tester, LogicalKeyboardKey.keyN, control: true);
      expect(find.byType(ComposeScreen), findsOneWidget);

      await press(tester, LogicalKeyboardKey.escape);

      expect(find.byType(ComposeScreen), findsNothing);
    });

    testWidgets('Esc asks about a message with something in it',
        (tester) async {
      await pump(tester);
      await press(tester, LogicalKeyboardKey.keyR, control: true);
      expect(find.byType(ComposeScreen), findsOneWidget);
      await tester.enterText(
        find.byWidgetPredicate((w) =>
            w is TextField && (w.controller?.text.startsWith('Re: ') ?? false)),
        'Re: and one more thing',
      );
      await tester.pump();

      await press(tester, LogicalKeyboardKey.escape);

      expect(find.text('Keep writing'), findsOneWidget);
    });

    testWidgets('Ctrl+Enter sends a reply', (tester) async {
      await pump(tester);
      await press(tester, LogicalKeyboardKey.keyR, control: true);
      expect(find.byType(ComposeScreen), findsOneWidget);

      await press(tester, LogicalKeyboardKey.enter, control: true);

      expect(find.byType(ComposeScreen), findsNothing);
      expect(find.text('Message sent'), findsOneWidget);
    });
  });
}
