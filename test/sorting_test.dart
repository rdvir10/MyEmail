import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_sort.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/conversations.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/settings/view_settings_screen.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'helpers/open_search.dart';

import 'fakes/fake_webview.dart';

/// What order the list is in, and the menu that changes it.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  MailMessage m(
    int uid, {
    String from = 'dana@example.com',
    String? name,
    String subject = 'Numbers',
    int day = 1,
  }) =>
      MailMessage(
        id: 'a:INBOX#$uid',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: uid,
        subject: subject,
        preview: '',
        from: MailAddress(email: from, name: name),
        to: const [],
        date: DateTime(2026, 9, day),
        isRead: true,
      );

  group('the order', () {
    test('by date, either way round', () {
      final newest = sortMessages(
        [m(1, day: 1), m(2, day: 9), m(3, day: 5)],
        MessageSort.dateNewest,
      );
      expect(newest.map((x) => x.uid), [2, 3, 1]);

      final oldest = sortMessages(
        [m(1, day: 1), m(2, day: 9)],
        MessageSort.dateOldest,
      );
      expect(oldest.map((x) => x.uid), [1, 2]);
    });

    test('by sender uses the name shown, not the address', () {
      final sorted = sortMessages(
        [
          m(1, from: 'aaron@example.com', name: 'Zoe Adams'),
          m(2, from: 'zed@example.com', name: 'Adam Zane'),
        ],
        MessageSort.sender,
      );
      expect(sorted.map((x) => x.uid), [2, 1], reason: 'A to Z, always');
    });

    test('by subject ignores Re: and Fwd:, so a reply sorts with its thread',
        () {
      final sorted = sortMessages(
        [
          m(1, subject: 'Zebra'),
          m(2, subject: 'Re: Apples'),
          m(3, subject: 'Apples'),
          m(4, subject: 'FW: Berries'),
        ],
        MessageSort.subject,
      );
      expect(sorted.map((x) => x.subject), [
        'Re: Apples',
        'Apples',
        'FW: Berries',
        'Zebra',
      ]);
    });

    test('equal keys still have one settled order', () {
      // Two from the same person on the same day: without a tie-break the
      // list would shuffle itself on every rebuild.
      final same = [m(2, day: 3), m(1, day: 3)];
      final once = sortMessages(same, MessageSort.sender);
      final twice = sortMessages(once.reversed.toList(), MessageSort.sender);
      expect(once.map((x) => x.uid), twice.map((x) => x.uid));
    });

    test('four choices, and only dates run backwards', () {
      expect(MessageSort.values.map((s) => s.label), [
        'Date (newest first)',
        'Date (oldest first)',
        'Sender',
        'Subject',
      ]);
      expect(MessageSort.dateNewest.ascending, isFalse);
      expect(MessageSort.dateOldest.ascending, isTrue);
      expect(MessageSort.sender.ascending, isTrue);
    });
  });

  group('the setting', () {
    test('defaults to newest first, and survives storage', () {
      expect(const DisplaySettings().sort, MessageSort.dateNewest);

      const changed = DisplaySettings(sort: MessageSort.sender);
      expect(DisplaySettings.fromJson(changed.toJson()).sort, MessageSort.sender);
    });

    test('a record written before sorting existed is newest first', () {
      final old = DisplaySettings.fromJson(const {'density': 'compact'});
      expect(old.sort, MessageSort.dateNewest);
    });

    test('a record from the build that kept a field and a direction', () {
      // 2.23.0 wrote those two keys; they name the same four orders.
      expect(
        DisplaySettings.fromJson(const {'sortField': 'date', 'sortAscending': true}).sort,
        MessageSort.dateOldest,
      );
      expect(
        DisplaySettings.fromJson(const {'sortField': 'subject', 'sortAscending': true}).sort,
        MessageSort.subject,
      );
      expect(
        DisplaySettings.fromJson(const {'sortField': 'date', 'sortAscending': false}).sort,
        MessageSort.dateNewest,
      );
    });

    test('a value from a newer build falls back rather than failing', () {
      expect(
        DisplaySettings.fromJson(const {'sort': 'byColour'}).sort,
        MessageSort.dateNewest,
      );
    });
  });

  group('on the list', () {
    Future<ProviderContainer> pump(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
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

    List<String> shownSenders(WidgetTester tester) => tester
        .widgetList<MessageTile>(find.byType(MessageTile))
        .map((t) => t.message.from.display.toLowerCase())
        .toList();

    testWidgets('the phone menu opens the sheet and sorts the rows',
        (tester) async {
      final c = await pump(tester, const Size(400, 900));

      await tester.tap(find.byTooltip('View and sort'));
      await tester.pumpAndSettle();
      expect(find.text('Sort by'), findsOneWidget);

      await tester.tap(find.text('Sender'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 40)); // close the sheet
      await tester.pumpAndSettle();

      expect(c.read(displayProvider).sort, MessageSort.sender);
      final senders = shownSenders(tester);
      final ordered = [...senders]..sort();
      expect(senders, ordered, reason: 'A to Z, as the sheet said');
    });

    testWidgets('the arrow keys walk the order on screen', (tester) async {
      // The list and the keyboard read one sorted list; sorting only where
      // the rows are built would leave the keys walking the old order.
      final c = await pump(tester, const Size(1400, 900));
      c.read(displayProvider.notifier).setSort(MessageSort.subject);
      await tester.pumpAndSettle();

      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final order = c.read(sortedMessagesProvider(folder));
      c.read(selectedMessageIdProvider.notifier).select(order.first.id);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(c.read(selectedMessageIdProvider), order[1].id);
    });

    testWidgets('with conversations on, the keys walk the threads as drawn',
        (tester) async {
      // Threads were drawn in the chosen order and walked newest first, so
      // with oldest first Home went to the bottom and Down went up.
      final c = await pump(tester, const Size(1400, 900));
      c.read(displayProvider.notifier)
        ..setConversations(true)
        ..setSort(MessageSort.dateOldest);
      await tester.pumpAndSettle();

      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final threads =
          groupIntoConversations(c.read(messagesProvider(folder)).value!)
            ..sort((a, b) => a.newest.date.compareTo(b.newest.date));
      c.read(selectedMessageIdProvider.notifier).select(threads[1].newest.id);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(c.read(selectedMessageIdProvider), threads.first.newest.id);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(c.read(selectedMessageIdProvider), threads[1].newest.id);
    });

    testWidgets('search results follow the same order', (tester) async {
      final c = await pump(tester, const Size(400, 900));
      c.read(displayProvider.notifier).setSort(MessageSort.sender);
      await tester.pumpAndSettle();

      await openSearch(tester);
      await tester.enterText(searchField, 'the');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      final senders = shownSenders(tester);
      expect(senders, isNotEmpty);
      expect(senders, [...senders]..sort());
      // And the menu is still reachable while searching.
      expect(find.byTooltip('View and sort'), findsOneWidget);
    });

    testWidgets('the tablet has the same menu where its list is titled',
        (tester) async {
      await pump(tester, const Size(1400, 900));

      expect(find.byTooltip('View and sort'), findsOneWidget);
      await tester.tap(find.byTooltip('View and sort'));
      await tester.pumpAndSettle();

      expect(find.text('Sort by'), findsOneWidget);
      expect(find.text('Conversations'), findsOneWidget);
    });

    testWidgets('the sheet leads to the whole View screen', (tester) async {
      await pump(tester, const Size(400, 900));
      await tester.tap(find.byTooltip('View and sort'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('All view settings…'));
      await tester.pumpAndSettle();

      expect(find.byType(ViewSettingsScreen), findsOneWidget);
    });
  });
}
