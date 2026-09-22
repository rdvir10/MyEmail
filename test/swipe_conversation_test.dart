import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/conversations.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/conversation_tile.dart';
import 'package:myemail/ui/messages/message_list_pane.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Swiping a conversation acts on the whole thread, the way its menu does.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  MailMessage m(int uid, {bool isRead = true, bool isFlagged = false}) =>
      MailMessage(
        id: 'a:INBOX#$uid',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: uid,
        subject: 'Numbers',
        preview: '',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime(2026, 9, 20, uid),
        isRead: isRead,
        isFlagged: isFlagged,
      );

  group('what the label says', () {
    test('one message reads as it always did', () {
      expect(swipeActionShortLabel(SwipeAction.delete, [m(1)]), 'Delete');
      expect(swipeActionShortLabel(SwipeAction.toggleRead, [m(1)]), 'Unread');
      expect(
        swipeActionShortLabel(SwipeAction.toggleRead, [m(1, isRead: false)]),
        'Read',
      );
      expect(swipeActionShortLabel(SwipeAction.none, [m(1)]), '');
    });

    test('a thread says how many are about to go', () {
      final thread = [m(1), m(2), m(3)];
      expect(swipeActionShortLabel(SwipeAction.delete, thread), 'Delete 3');
      expect(swipeActionShortLabel(SwipeAction.archive, thread), 'Archive 3');
    });

    test('read and flag speak for the thread, not for one of it', () {
      // Mixed: anything unread means the swipe marks everything read, and
      // the label has to say the thing it will do.
      final mixed = [m(1, isRead: false), m(2)];
      expect(swipeActionShortLabel(SwipeAction.toggleRead, mixed), 'Read 2');
      expect(
        swipeActionShortLabel(SwipeAction.toggleRead, [m(1), m(2)]),
        'Unread 2',
      );
      final someFlagged = [m(1, isFlagged: true), m(2)];
      expect(
        swipeActionShortLabel(SwipeAction.toggleFlag, someFlagged),
        'Unflag 2',
      );
      expect(swipeActionShortLabel(SwipeAction.toggleFlag, [m(1)]), 'Flag');
    });
  });

  group('on the list', () {
    Future<(ProviderContainer, Conversation)> open(
      WidgetTester tester, {
      SwipeAction left = SwipeAction.delete,
    }) async {
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
      c.read(displayProvider.notifier)
        ..setConversations(true)
        ..setSwipeLeft(left);
      await tester.pumpAndSettle();

      final tile = tester.widget<ConversationTile>(
        find.byType(ConversationTile).first,
      );
      return (c, tile.conversation);
    }

    List<MailMessage> listOf(ProviderContainer c) =>
        c.read(messagesProvider(c.read(effectiveSelectedFolderIdProvider)!)).value!;

    testWidgets('swiping it takes every message in it', (tester) async {
      final (c, thread) = await open(tester);
      final ids = thread.messages.map((m) => m.id).toSet();
      expect(ids.length, greaterThan(1));

      await tester.drag(
        find.byKey(ValueKey('thread:${thread.id}')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();

      final after = listOf(c).map((m) => m.id).toSet();
      expect(after.intersection(ids), isEmpty, reason: 'the whole thread went');
      expect(find.textContaining('deleted'), findsOneWidget);
    });

    testWidgets('a half-finished swipe says how many it is about to take',
        (tester) async {
      final (_, thread) = await open(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('thread:${thread.id}'))),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-160, 0));
      await tester.pump();

      expect(find.text('Delete ${thread.length}'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('read marks the whole thread read in one go', (tester) async {
      final (c, thread) = await open(tester, left: SwipeAction.toggleRead);
      final ids = thread.messages.map((m) => m.id).toSet();
      expect(thread.hasUnread, isTrue,
          reason: 'the sample inbox has unread mail in its threads');

      await tester.drag(
        find.byKey(ValueKey('thread:${thread.id}')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();

      final after = [for (final m in listOf(c)) if (ids.contains(m.id)) m];
      expect(after, hasLength(ids.length), reason: 'nothing left the list');
      expect(after.every((m) => m.isRead), isTrue);
    });

    testWidgets('a message row still swipes on its own', (tester) async {
      final (c, _) = await open(tester);
      // A conversation of one is drawn as a plain row.
      final loose = listOf(c).firstWhere((x) =>
          groupIntoConversations(listOf(c))
              .firstWhere((g) => g.messages.any((y) => y.id == x.id))
              .length ==
          1);

      // Rows carry a sender address and the list carries date bars now,
      // so the row this picks may be below the fold.
      final row = find.byKey(ValueKey('tile:${loose.id}'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.drag(row, const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(listOf(c).any((x) => x.id == loose.id), isFalse);
    });
  });
}
