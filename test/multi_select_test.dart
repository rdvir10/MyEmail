import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/conversation_tile.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/selection_bar.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'helpers/open_search.dart';

import 'fakes/fake_webview.dart';

/// Picking several messages and doing one thing to all of them.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<ProviderContainer> pump(WidgetTester tester) async {
    useSize(tester, const Size(1400, 900));
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

  group('starting and stopping', () {
    testWidgets('no checkboxes until selecting starts', (tester) async {
      await pump(tester);

      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('ticking one message brings the checkboxes out', (
      tester,
    ) async {
      final c = await pump(tester);
      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);

      c.read(selectedMessageIdsProvider.notifier).start(first.message.id);
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsWidgets);
      expect(find.byType(SelectionBar), findsOneWidget);
    });

    testWidgets('unticking the last one ends it', (tester) async {
      // Emptiness is the mode, so there is no separate flag to fall out of
      // step with what is ticked.
      final c = await pump(tester);
      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);
      c.read(selectedMessageIdsProvider.notifier).start(first.message.id);
      await tester.pumpAndSettle();

      c.read(selectedMessageIdsProvider.notifier).toggle(first.message.id);
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(SelectionBar), findsNothing);
    });

    testWidgets('the bar says how many are ticked', (tester) async {
      final c = await pump(tester);
      final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
      final ids = tiles.take(3).map((t) => t.message.id).toList();

      c.read(selectedMessageIdsProvider.notifier).addAll(ids);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(SelectionBar),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
    });
  });

  group('while selecting', () {
    testWidgets('a tap ticks rather than opens', (tester) async {
      // Opening a message mid-selection would take the list off screen and
      // lose the ticks with it, which is not what a tap means once checkboxes
      // are up.
      final c = await pump(tester);
      final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
      final first = tiles.first.message.id;
      final second = tiles.elementAt(1).message.id;

      c.read(selectedMessageIdsProvider.notifier).start(first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('tile:$second')));
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageIdsProvider), {first, second});
    });

    testWidgets('the search bar gives way to the selection bar', (
      tester,
    ) async {
      // Both at once would be two rows of controls above a list that has
      // shrunk to make room, and searching is not what anyone is doing
      // mid-selection.
      final c = await pump(tester);
      await openSearch(tester);
      expect(find.text('Search mail'), findsOneWidget);

      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);
      c.read(selectedMessageIdsProvider.notifier).start(first.message.id);
      await tester.pumpAndSettle();

      expect(find.text('Search mail'), findsNothing);
    });
  });

  group('selecting what is on screen', () {
    /// The rows drawn inside the list's own box, which is what the button is
    /// meant to take.
    /// The message list, not the folder tree, which is a ListView too.
    Finder messageList() => find.ancestor(
          of: find.byType(MessageTile).first,
          matching: find.byType(ListView),
        );

    Set<String> onScreen(WidgetTester tester) {
      final list = tester.renderObject<RenderBox>(messageList());
      final shown = <String>{};
      for (final tile in find.byType(MessageTile).evaluate()) {
        final box = tile.renderObject! as RenderBox;
        final top = box.localToGlobal(Offset.zero, ancestor: list).dy;
        final height = box.size.height;
        final visible =
            math.min(top + height, list.size.height) - math.max(top, 0.0);
        if (visible > height / 2) {
          shown.add((tile.widget as MessageTile).message.id);
        }
      }
      return shown;
    }

    testWidgets('takes the screenful rather than the whole folder',
        (tester) async {
      // A folder holds thousands. A button that ticked all of them would put
      // a delete one press away from a mistake nobody can see the size of.
      final c = await pump(tester);
      final folderId = c.read(effectiveSelectedFolderIdProvider)!;
      final all = c.read(messagesProvider(folderId)).value!;
      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);

      c.read(selectedMessageIdsProvider.notifier).start(first.message.id);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select what is on screen'));
      await tester.pumpAndSettle();

      final ticked = c.read(selectedMessageIdsProvider);
      expect(ticked, onScreen(tester));
      expect(ticked.length, lessThan(all.length),
          reason: 'the folder is longer than the screen');
    });

    testWidgets('leaves out the rows scrolled past', (tester) async {
      final c = await pump(tester);
      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);

      c.read(selectedMessageIdsProvider.notifier).start(first.message.id);
      await tester.pumpAndSettle();
      await tester.drag(messageList(), const Offset(0, -600));
      await tester.pumpAndSettle();
      final showing = onScreen(tester);
      await tester.tap(find.byTooltip('Select what is on screen'));
      await tester.pumpAndSettle();

      // The one ticked to start with is above the fold now, and stays ticked:
      // the button adds to the selection rather than replacing it.
      expect(c.read(selectedMessageIdsProvider),
          {first.message.id, ...showing});
      expect(showing, isNot(contains(first.message.id)));
    });

    testWidgets('pressing it again after scrolling takes in the next lot',
        (tester) async {
      final c = await pump(tester);
      final first = tester.widget<MessageTile>(find.byType(MessageTile).first);

      c.read(selectedMessageIdsProvider.notifier).start(first.message.id);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select what is on screen'));
      await tester.pumpAndSettle();
      final firstScreenful = c.read(selectedMessageIdsProvider).length;

      await tester.drag(messageList(), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select what is on screen'));
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageIdsProvider).length,
          greaterThan(firstScreenful));
    });
  });

  testWidgets('a long press ticks the message, and one more', (tester) async {
    // The way selecting starts on a screen with no right button.
    final c = await pump(tester);
    final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
    final first = tiles.first.message.id;
    final second = tiles.elementAt(1).message.id;

    await tester.longPress(find.byType(MessageTile).first);
    await tester.pumpAndSettle();
    expect(c.read(selectedMessageIdsProvider), {first});
    expect(find.byType(Checkbox), findsWidgets);

    await tester.longPress(find.byKey(ValueKey('tile:$second')));
    await tester.pumpAndSettle();
    expect(c.read(selectedMessageIdsProvider), {first, second});
  });

  testWidgets('the right-click menu offers Select too', (tester) async {
    final c = await pump(tester);
    final first = tester.widget<MessageTile>(find.byType(MessageTile).first);

    await tester.tap(find.byType(MessageTile).first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Select'));
    await tester.pumpAndSettle();

    expect(c.read(selectedMessageIdsProvider), {first.message.id});
  });

  testWidgets('opening another folder lets the ticks go', (tester) async {
    // Carried over, the bar counted messages nobody could see, and Delete
    // found none of them in the new list and quietly cleared them.
    final c = await pump(tester);
    final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
    c.read(selectedMessageIdsProvider.notifier)
        .addAll(tiles.take(3).map((t) => t.message.id));
    await tester.pumpAndSettle();
    expect(find.byType(SelectionBar), findsOneWidget);

    final accounts = await tester.runAsync(
      () => c.read(accountsProvider.future),
    );
    final folders = c.read(foldersProvider).value![accounts!.first.id]!;
    final other = folders.firstWhere(
      (f) => f.id != c.read(effectiveSelectedFolderIdProvider),
    );
    c.read(selectedFolderIdProvider.notifier).select(other.id);
    await tester.pumpAndSettle();

    expect(c.read(selectedMessageIdsProvider), isEmpty);
    expect(find.byType(SelectionBar), findsNothing);
  });

  testWidgets('closing Move without a choice keeps the ticks',
      (tester) async {
    // Tick twenty-five, open Move, swipe the sheet away: all gone, and
    // nothing had been done to any of them.
    final c = await pump(tester);
    final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
    final account = tiles.first.message.accountId;
    final ids = {
      for (final t in tiles.where((t) => t.message.accountId == account).take(2))
        t.message.id,
    };
    c.read(selectedMessageIdsProvider.notifier).addAll(ids);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Move to…'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(c.read(selectedMessageIdsProvider), ids);
  });

  testWidgets('acting on the selection clears it', (tester) async {
    // Leaving the ticks behind after acting on them means the next action
    // lands on messages the person believes they have already dealt with.
    final c = await pump(tester);
    final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
    final unread = tiles.firstWhere((t) => !t.message.isRead).message.id;

    c.read(selectedMessageIdsProvider.notifier).start(unread);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Mark read'));
    await tester.pumpAndSettle();

    expect(c.read(selectedMessageIdsProvider), isEmpty);
  });

  group('a conversation row', () {
    /// The first closed thread on screen, with conversations turned on and
    /// selection started from an ordinary message.
    Future<(ProviderContainer, ConversationTile)> selecting(
      WidgetTester tester,
    ) async {
      final c = await pump(tester);
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpAndSettle();
      final loose = tester.widget<MessageTile>(find.byType(MessageTile).first);
      c.read(selectedMessageIdsProvider.notifier).start(loose.message.id);
      await tester.pumpAndSettle();
      final thread = tester.widget<ConversationTile>(
        find.byType(ConversationTile).first,
      );
      return (c, thread);
    }

    Finder box(ConversationTile thread) => find.descendant(
          of: find.byKey(ValueKey('thread:${thread.conversation.id}')),
          matching: find.byType(Checkbox),
        );

    testWidgets('gets a checkbox too, and it ticks the whole thread',
        (tester) async {
      final (c, thread) = await selecting(tester);
      final ids = thread.conversation.messages.map((m) => m.id).toSet();
      expect(ids.length, greaterThan(1));

      await tester.tap(box(thread));
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageIdsProvider), containsAll(ids));
      expect(tester.widget<Checkbox>(box(thread)).value, isTrue);
    });

    testWidgets('unticks all of them again, and only them', (tester) async {
      final (c, thread) = await selecting(tester);
      final before = c.read(selectedMessageIdsProvider);
      await tester.tap(box(thread));
      await tester.pumpAndSettle();

      await tester.tap(box(thread));
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageIdsProvider), before,
          reason: 'the message ticked by hand is still ticked');
    });

    testWidgets('shows a dash when only some of the thread is ticked',
        (tester) async {
      // Open the thread, tick one message inside it, close it.
      final (c, thread) = await selecting(tester);
      final one = thread.conversation.messages.first.id;

      c.read(selectedMessageIdsProvider.notifier).toggle(one);
      await tester.pumpAndSettle();

      expect(tester.widget<Checkbox>(box(thread)).value, isNull,
          reason: 'tristate: neither all nor none');
      await tester.tap(box(thread));
      await tester.pumpAndSettle();
      expect(
        c.read(selectedMessageIdsProvider),
        containsAll(thread.conversation.messages.map((m) => m.id)),
        reason: 'from some, the next press takes the rest',
      );
    });

    testWidgets('a long press ticks the whole thread', (tester) async {
      final c = await pump(tester);
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpAndSettle();
      final thread = tester.widget<ConversationTile>(
        find.byType(ConversationTile).first,
      );

      await tester.longPress(
        find.byKey(ValueKey('thread:${thread.conversation.id}')),
      );
      await tester.pumpAndSettle();

      expect(
        c.read(selectedMessageIdsProvider),
        thread.conversation.messages.map((m) => m.id).toSet(),
      );
      expect(find.byType(Checkbox), findsWidgets);
    });

    testWidgets('its right-click menu offers Select all', (tester) async {
      final c = await pump(tester);
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpAndSettle();
      final thread = tester.widget<ConversationTile>(
        find.byType(ConversationTile).first,
      );

      await tester.tap(
        find.byKey(ValueKey('thread:${thread.conversation.id}')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(
        PopupMenuItem<String>,
        'Select all ${thread.conversation.length}',
      ));
      await tester.pumpAndSettle();

      expect(
        c.read(selectedMessageIdsProvider),
        thread.conversation.messages.map((m) => m.id).toSet(),
      );
    });

    testWidgets('a tap on the row still opens it', (tester) async {
      // Unlike a message row, which ticks on tap while selecting: a thread
      // has to open so one message inside it can be picked out.
      final (c, thread) = await selecting(tester);

      await tester.tap(find.byKey(ValueKey('thread:${thread.conversation.id}')));
      await tester.pumpAndSettle();

      expect(
        c.read(expandedConversationsProvider),
        contains(thread.conversation.id),
      );
    });
  });
}
