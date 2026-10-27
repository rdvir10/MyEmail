import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/conversations.dart';
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

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    MailEngine? engine,
  }) async {
    useSize(tester, const Size(1400, 900));
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
      // The bar's buttons scroll on a phone, Move, Archive and Delete
      // showing first.
      await tester.ensureVisible(find.byTooltip('Select what is on screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select what is on screen'));
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageIdsProvider).length,
          greaterThan(firstScreenful));
    });
  });

  testWidgets('a hold opens the menu, whose Select starts ticking',
      (tester) async {
    // A finger's right click (3.7.0): a hold ticked before, and the menu
    // was a mouse's alone.
    final c = await pump(tester);
    final tiles = tester.widgetList<MessageTile>(find.byType(MessageTile));
    final first = tiles.first.message.id;
    final second = tiles.elementAt(1).message.id;

    await tester.longPress(find.byKey(ValueKey('tile:$first')));
    await tester.pumpAndSettle();
    expect(c.read(selectedMessageIdsProvider), isEmpty,
        reason: 'the hold ticks nothing by itself');
    expect(find.byKey(const ValueKey('menu-reply')), findsOneWidget);
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Select'));
    await tester.pumpAndSettle();
    expect(c.read(selectedMessageIdsProvider), {first});
    expect(find.byType(Checkbox), findsWidgets);

    await tester.tap(find.byKey(ValueKey('tile:$second')));
    await tester.pumpAndSettle();
    expect(c.read(selectedMessageIdsProvider), {first, second},
        reason: 'and from there a tap ticks one more');
  });

  group('with several ticked', () {
    Future<(ProviderContainer, List<MailMessage>)> twoTicked(
      WidgetTester tester,
    ) async {
      final c = await pump(tester);
      final unread = [
        for (final t in tester.widgetList<MessageTile>(find.byType(MessageTile)))
          if (!t.message.isRead) t.message,
      ];
      expect(unread.length, greaterThan(2));
      c.read(selectedMessageIdsProvider.notifier)
          .addAll([unread[0].id, unread[1].id]);
      await tester.pumpAndSettle();
      return (c, unread);
    }

    MailMessage now(ProviderContainer c, String id) => c
        .read(messagesProvider(c.read(effectiveSelectedFolderIdProvider)!))
        .value!
        .firstWhere((m) => m.id == id);

    testWidgets('the menu on a ticked one acts on all of them', (tester) async {
      final (c, unread) = await twoTicked(tester);

      await tester.tap(find.byKey(ValueKey('tile:${unread[1].id}')),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-reply')), findsNothing,
          reason: 'nothing that is for one message alone');
      await tester.tap(
          find.widgetWithText(PopupMenuItem<String>, 'Mark 2 as read'));
      await tester.pumpAndSettle();

      expect(now(c, unread[0].id).isRead, isTrue);
      expect(now(c, unread[1].id).isRead, isTrue);
      expect(now(c, unread[2].id).isRead, isFalse);
      expect(c.read(selectedMessageIdsProvider), isEmpty,
          reason: 'let go once done, as the bar lets them go');
    });

    testWidgets('and so does a hold on one', (tester) async {
      final (_, unread) = await twoTicked(tester);

      await tester.longPress(find.byKey(ValueKey('tile:${unread[0].id}')));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(PopupMenuItem<String>, 'Delete 2'),
          findsOneWidget);
    });

    testWidgets('the menu on one not ticked is its own', (tester) async {
      final (c, unread) = await twoTicked(tester);

      await tester.tap(find.byKey(ValueKey('tile:${unread[2].id}')),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('menu-reply')), findsOneWidget);
      await tester.tap(
          find.widgetWithText(PopupMenuItem<String>, 'Mark as read'));
      await tester.pumpAndSettle();

      expect(now(c, unread[2].id).isRead, isTrue);
      expect(now(c, unread[0].id).isRead, isFalse);
      expect(c.read(selectedMessageIdsProvider),
          {unread[0].id, unread[1].id});
    });
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

  testWidgets('marking or flagging the selection asks the engine once',
      (tester) async {
    // One message at a time, sixty flagged on a Microsoft account were
    // sixty requests end to end. Together, they go twenty to a request.
    final engine = _Together();
    final c = await pump(tester, engine: engine);
    final unread = [
      for (final t in tester.widgetList<MessageTile>(find.byType(MessageTile)))
        if (!t.message.isRead && !t.message.isFlagged) t.message.id,
    ].take(3).toList();
    expect(unread, hasLength(3));

    Finder inBar(String tooltip) => find.descendant(
          of: find.byType(SelectionBar),
          matching: find.byTooltip(tooltip),
        );
    c.read(selectedMessageIdsProvider.notifier).addAll(unread);
    await tester.pumpAndSettle();
    await tester.tap(inBar('Mark read'));
    await tester.pumpAndSettle();
    c.read(selectedMessageIdsProvider.notifier).addAll(unread);
    await tester.pumpAndSettle();
    await tester.tap(inBar('Flag'));
    await tester.pumpAndSettle();

    expect(engine.read, [unorderedEquals(unread)]);
    expect(engine.flagged, [unorderedEquals(unread)]);
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

    testWidgets('a hold opens its menu, whose Select all ticks the thread',
        (tester) async {
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
      expect(c.read(selectedMessageIdsProvider), isEmpty);
      await tester.tap(find.widgetWithText(
        PopupMenuItem<String>,
        'Select all ${thread.conversation.length}',
      ));
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

    // From its right-click menu, with one message the server will not
    // change. The menu stopped at that one, left the rest as they were, and
    // the error went nowhere anyone could see.
    Future<(ProviderContainer, _Refuses, Conversation)> withOneRefused(
      WidgetTester tester,
      bool Function(Conversation) which,
    ) async {
      final engine = _Refuses();
      final c = await pump(tester, engine: engine);
      c.read(displayProvider.notifier).setConversations(true);
      await tester.pumpAndSettle();
      final thread = tester
          .widgetList<ConversationTile>(find.byType(ConversationTile))
          .map((t) => t.conversation)
          .firstWhere(which);
      return (c, engine, thread);
    }

    Future<void> fromMenu(
      WidgetTester tester,
      Conversation thread,
      String item,
    ) async {
      await tester.tap(
        find.byKey(ValueKey('thread:${thread.id}')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, item));
      await tester.pumpAndSettle();
    }

    Map<String, MailMessage> listed(ProviderContainer c) => {
          for (final m in c
              .read(messagesProvider(c.read(effectiveSelectedFolderIdProvider)!))
              .value!)
            m.id: m,
        };

    testWidgets('its Mark all as read goes on past one that fails, and says so',
        (tester) async {
      final (c, engine, thread) = await withOneRefused(
        tester,
        (t) => t.unreadCount > 1,
      );
      final refused = thread.messages.firstWhere((m) => !m.isRead);
      engine.refused = refused.id;

      await fromMenu(tester, thread, 'Mark all ${thread.length} as read');

      final now = listed(c);
      for (final m in thread.messages) {
        expect(now[m.id]!.isRead, m.id != refused.id, reason: m.id);
      }
      expect(find.textContaining('Could not mark read 1 of ${thread.length}'),
          findsOneWidget);
    });

    testWidgets('its Flag all goes on past one that fails, and says so',
        (tester) async {
      final (c, engine, thread) = await withOneRefused(
        tester,
        (t) => t.isThread && !t.isFlagged,
      );
      engine.refused = thread.messages.first.id;

      await fromMenu(tester, thread, 'Flag all ${thread.length}');

      final now = listed(c);
      for (final m in thread.messages) {
        expect(now[m.id]!.isFlagged, m.id != engine.refused, reason: m.id);
      }
      expect(find.textContaining('Could not flag 1 of ${thread.length}'),
          findsOneWidget);
    });
  });

  testWidgets('a tap on an unread message the server will not mark leaves '
      'it unread, quietly', (tester) async {
    // As the reading pane does: nobody asked to be told. The error went
    // unhandled instead.
    final engine = _Refuses();
    final c = await pump(tester, engine: engine);
    final unread = tester
        .widgetList<MessageTile>(find.byType(MessageTile))
        .map((t) => t.message)
        .where((m) => !m.isRead)
        .elementAt(1);
    engine.refused = unread.id;

    await tester.tap(find.byKey(ValueKey('tile:${unread.id}')));
    await tester.pumpAndSettle();

    final folder = c.read(effectiveSelectedFolderIdProvider)!;
    final after = c
        .read(messagesProvider(folder))
        .value!
        .firstWhere((m) => m.id == unread.id);
    expect(after.isRead, isFalse);
  });
}

/// The sample engine, saying what it was asked to change several at a time.
class _Together extends SampleMailEngine {
  final read = <List<String>>[];
  final flagged = <List<String>>[];

  @override
  Future<void> setMessagesRead(List<String> messageIds, bool isRead) {
    read.add(messageIds);
    return super.setMessagesRead(messageIds, isRead);
  }

  @override
  Future<void> setMessagesFlagged(List<String> messageIds, bool isFlagged) {
    flagged.add(messageIds);
    return super.setMessagesFlagged(messageIds, isFlagged);
  }
}

/// The sample engine with one message the server will not change, as with
/// an expired token or a connection that dropped.
class _Refuses extends SampleMailEngine {
  String? refused;

  @override
  Future<void> setRead(String messageId, bool isRead) async {
    if (messageId == refused) throw StateError('the server said no');
    await super.setRead(messageId, isRead);
  }

  @override
  Future<void> setFlagged(String messageId, bool isFlagged) async {
    if (messageId == refused) throw StateError('the server said no');
    await super.setFlagged(messageId, isFlagged);
  }
}
