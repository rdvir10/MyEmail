import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_sort.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/list_columns.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/date_format.dart';
import 'package:myemail/ui/messages/list_columns.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// Outlook's column headers over the list: Received and Size in columns of
/// their own, a tap on a header to sort, a drag on an edge to widen, and
/// "By Date" with its arrow where the list is too narrow for columns.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  MailMessage m(
    int uid, {
    String from = 'dana@example.com',
    int day = 1,
    int size = 0,
  }) =>
      MailMessage(
        id: 'a:INBOX#$uid',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: uid,
        subject: 'Numbers',
        preview: '',
        from: MailAddress(email: from),
        to: const [],
        date: DateTime(2026, 9, day),
        isRead: true,
        sizeBytes: size,
      );

  List<int> uids(List<MailMessage> list) => [for (final x in list) x.uid];

  group('the other way round', () {
    test('names run Z to A, and one sender\'s mail stays newest first', () {
      final sorted = sortMessages(
        [
          m(1, from: 'avi@x.com', day: 1),
          m(2, from: 'zoe@x.com', day: 2),
          m(3, from: 'avi@x.com', day: 3),
        ],
        MessageSort.sender,
        reversed: true,
      );
      expect(uids(sorted), [2, 3, 1]);
    });

    test('sizes run smallest first', () {
      final sorted = sortMessages(
        [m(1, size: 500), m(2, size: 90), m(3, size: 9000)],
        MessageSort.size,
        reversed: true,
      );
      expect(uids(sorted), [2, 1, 3]);
    });

    test('a header tapped twice turns its order round', () {
      final c = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        ],
      );
      addTearDown(c.dispose);
      final display = c.read(displayProvider.notifier);

      display.sortByColumn(MessageSort.size);
      expect(c.read(displayProvider).sort, MessageSort.size);
      expect(c.read(displayProvider).sortReversed, isFalse);
      display.sortByColumn(MessageSort.size);
      expect(c.read(displayProvider).sortReversed, isTrue);

      // Another column starts from its own way round.
      display.sortByColumn(MessageSort.subject);
      expect(c.read(displayProvider).sort, MessageSort.subject);
      expect(c.read(displayProvider).sortReversed, isFalse);

      // The dates are two choices of their own, and swap.
      display.sortByColumn(MessageSort.dateNewest);
      expect(c.read(displayProvider).sort, MessageSort.dateNewest);
      display.sortByColumn(MessageSort.dateNewest);
      expect(c.read(displayProvider).sort, MessageSort.dateOldest);
      expect(c.read(displayProvider).sortReversed, isFalse);
      display.reverseSort();
      expect(c.read(displayProvider).sort, MessageSort.dateNewest);
    });

    test('says which way it runs', () {
      expect(MessageSort.dateNewest.directionLabel(), 'Newest on top');
      expect(MessageSort.dateOldest.directionLabel(), 'Oldest on top');
      expect(MessageSort.sender.directionLabel(reversed: true), 'Z to A');
      expect(MessageSort.size.directionLabel(), 'Largest on top');
      expect(MessageSort.size.shortLabel, 'Size');
    });

    test('is kept, with Show in groups, and an older record has neither', () {
      const turned = DisplaySettings(
        sort: MessageSort.size,
        sortReversed: true,
        showGroups: false,
      );
      final back = DisplaySettings.fromJson(turned.toJson());
      expect(back.sortReversed, isTrue);
      expect(back.showGroups, isFalse);
      expect(back, turned);

      final old = DisplaySettings.fromJson(const {'sort': 'size'});
      expect(old.sortReversed, isFalse);
      expect(old.showGroups, isTrue);
      expect(old.listHasBars, isTrue);
      expect(back.listHasBars, isFalse);
    });
  });

  group('the Received column', () {
    final now = DateTime(2026, 10, 31, 12);

    test('says the day and the time on every row', () {
      expect(
        formatMessageDateColumn(
          DateTime(2026, 10, 31, 11, 20),
          now: now,
          use24h: false,
        ),
        'Sat 31 Oct 11:20 AM',
      );
      expect(
        formatMessageDateColumn(DateTime(2026, 10, 30, 19, 54), now: now),
        'Fri 30 Oct 19:54',
      );
    });

    test('and the year, when it is not this one', () {
      expect(
        formatMessageDateColumn(
          DateTime(2025, 12, 3, 9, 2),
          now: now,
          use24h: false,
        ),
        'Wed 3 Dec 2025 9:02 AM',
      );
    });
  });

  group('the columns\' widths', () {
    test('are kept, within bounds, and put back', () {
      final store = MemoryUiStateStore();
      final c = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final columns = c.read(listColumnsProvider.notifier);

      columns.setWidth(ListColumn.size, 70);
      columns.setWidth(ListColumn.from, 9000);
      columns.toggle(ListColumn.received);
      expect(c.read(listColumnsProvider).size, 70);
      expect(c.read(listColumnsProvider).from, 400);
      expect(c.read(listColumnsProvider).shows(ListColumn.received), isFalse);

      // Read again, as the next start of the app would.
      final again = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(store)],
      );
      addTearDown(again.dispose);
      expect(again.read(listColumnsProvider), c.read(listColumnsProvider));

      columns.resetWidth(ListColumn.size);
      expect(c.read(listColumnsProvider).size, isNull);
      expect(c.read(listColumnsProvider).from, 400);
      columns.resetWidths();
      expect(c.read(listColumnsProvider).from, isNull);
      expect(c.read(listColumnsProvider).shows(ListColumn.received), isFalse);

      // From and Subject are always there.
      columns.toggle(ListColumn.from);
      expect(c.read(listColumnsProvider).shows(ListColumn.from), isTrue);
    });
  });

  group('on the list', () {
    Future<ProviderContainer> pump(
      WidgetTester tester,
      Size size, {
      ReadingPanePosition pane = ReadingPanePosition.bottom,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        ],
      );
      addTearDown(c.dispose);
      c.read(displayProvider.notifier).setReadingPane(pane);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    final header = find.byType(ListColumnHeader);
    Finder heading(String label) =>
        find.descendant(of: header, matching: find.text(label));
    final bars = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('bar:'),
    );

    testWidgets('a wide tablet list has Outlook\'s headers', (tester) async {
      await pump(tester, const Size(1400, 900));

      expect(header, findsOneWidget);
      for (final label in ['From', 'Subject', 'Received', 'Size']) {
        expect(heading(label), findsOneWidget, reason: label);
      }
      // Each row has its date and size in those columns.
      expect(find.byKey(const ValueKey('row-received')), findsWidgets);
      expect(find.byKey(const ValueKey('row-size')), findsWidgets);
      // And the sort button over them, as Outlook has both.
      expect(find.text('By Date'), findsOneWidget);
    });

    testWidgets('beside the reading pane the list is too narrow for them',
        (tester) async {
      await pump(tester, const Size(1400, 900), pane: ReadingPanePosition.right);

      expect(header, findsNothing);
      expect(find.byKey(const ValueKey('row-received')), findsNothing);
      expect(find.text('By Date'), findsOneWidget);
    });

    testWidgets('a phone has none, and the sort button does their work',
        (tester) async {
      final c = await pump(tester, const Size(400, 900));
      expect(header, findsNothing);

      expect(find.byTooltip('Newest on top'), findsOneWidget);
      await tester.tap(find.byTooltip('Newest on top'));
      await tester.pumpAndSettle();
      expect(c.read(displayProvider).sort, MessageSort.dateOldest);
      expect(find.byTooltip('Oldest on top'), findsOneWidget);

      await tester.tap(find.text('By Date'));
      await tester.pumpAndSettle();
      expect(find.text('Show in groups'), findsOneWidget);
      // The columns' own entries are the headers' menu alone.
      expect(find.text('Size column'), findsNothing);
      await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, 'Size'));
      await tester.pumpAndSettle();
      expect(c.read(displayProvider).sort, MessageSort.size);
      expect(find.text('By Size'), findsOneWidget);
    });

    testWidgets('a tap on a header sorts by it, and a second turns it round',
        (tester) async {
      final c = await pump(tester, const Size(1400, 900));

      await tester.tap(heading('Size'));
      await tester.pumpAndSettle();
      expect(c.read(displayProvider).sort, MessageSort.size);
      expect(c.read(displayProvider).sortReversed, isFalse);
      expect(
        find.descendant(
          of: header,
          matching: find.byKey(const ValueKey('sort-arrow')),
        ),
        findsOneWidget,
      );
      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final largest = c.read(sortedMessagesProvider(folder));
      expect(largest.first.sizeBytes,
          largest.map((x) => x.sizeBytes).reduce((a, b) => a > b ? a : b));

      await tester.tap(heading('Size'));
      await tester.pumpAndSettle();
      expect(c.read(displayProvider).sortReversed, isTrue);
      final smallest = c.read(sortedMessagesProvider(folder));
      expect(smallest.first.sizeBytes,
          smallest.map((x) => x.sizeBytes).reduce((a, b) => a < b ? a : b));

      await tester.tap(heading('Received'));
      await tester.pumpAndSettle();
      expect(c.read(displayProvider).sort, MessageSort.dateNewest);
      await tester.tap(heading('Received'));
      await tester.pumpAndSettle();
      expect(c.read(displayProvider).sort, MessageSort.dateOldest);
    });

    Future<void> expectAligned(WidgetTester tester) async {
      final row = find.byType(MessageTile).first;
      final tile = tester.widget<MessageTile>(row);
      double leftOf(Finder f) => tester.getTopLeft(f).dx;
      // The sender's column, whose replied and forwarded marks come before
      // the name, as Outlook's icon column does.
      expect(
        leftOf(heading('From')),
        leftOf(find.descendant(
            of: row, matching: find.byKey(const ValueKey('row-from')))),
        reason: 'From over the sender',
      );
      expect(
        leftOf(heading('Subject')),
        leftOf(find
            .descendant(of: row, matching: find.text(tile.message.subject))
            .first),
        reason: 'Subject over the subject',
      );
      expect(
        leftOf(heading('Received')),
        leftOf(find.descendant(
            of: row, matching: find.byKey(const ValueKey('row-received')))),
        reason: 'Received over the date',
      );
      expect(
        leftOf(heading('Size')),
        leftOf(find.descendant(
            of: row, matching: find.byKey(const ValueKey('row-size')))),
        reason: 'Size over the size',
      );
    }

    testWidgets('every header sits over its column, selecting or not',
        (tester) async {
      final c = await pump(tester, const Size(1400, 900));
      await expectAligned(tester);

      final folder = c.read(effectiveSelectedFolderIdProvider)!;
      final first = c.read(sortedMessagesProvider(folder)).first;
      c.read(selectedMessageIdsProvider.notifier).toggle(first.id);
      await tester.pumpAndSettle();
      await expectAligned(tester);

      c.read(displayProvider.notifier).setDensity(ListDensity.compact);
      await tester.pumpAndSettle();
      await expectAligned(tester);
    });

    testWidgets('an edge dragged makes the column after it wider',
        (tester) async {
      final c = await pump(tester, const Size(1400, 900));
      final before = tester.getSize(find.byKey(const ValueKey('row-size')).first);

      await tester.drag(
        find.byKey(const ValueKey('column-edge:size')),
        const Offset(-30, 0),
      );
      await tester.pumpAndSettle();

      final after = tester.getSize(find.byKey(const ValueKey('row-size')).first);
      expect(after.width, closeTo(before.width + 30, 1));
      expect(c.read(listColumnsProvider).size, isNotNull);
      await expectAligned(tester);
    });

    testWidgets('a hold on the headers puts a column away', (tester) async {
      final c = await pump(tester, const Size(1400, 900));

      await tester.longPress(heading('Subject'));
      await tester.pumpAndSettle();
      expect(find.text('Reset column widths'), findsOneWidget);
      await tester.tap(find.widgetWithText(
          CheckedPopupMenuItem<String>, 'Size column'));
      await tester.pumpAndSettle();

      expect(c.read(listColumnsProvider).shows(ListColumn.size), isFalse);
      expect(heading('Size'), findsNothing);
      expect(find.byKey(const ValueKey('row-size')), findsNothing);
    });

    testWidgets('a right click on them opens the same menu', (tester) async {
      await pump(tester, const Size(1400, 900));

      await tester.tap(heading('Subject'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Received column'), findsOneWidget);
    });

    testWidgets('Show in groups off takes the bars away', (tester) async {
      final c = await pump(tester, const Size(1400, 900));
      expect(bars, findsWidgets);

      c.read(displayProvider.notifier).setShowGroups(false);
      await tester.pumpAndSettle();
      expect(bars, findsNothing);
    });
  });
}
