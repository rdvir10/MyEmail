import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/graph/graph_mail_api.dart';
import 'package:myemail/data/imap/imap_mapping.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/search_providers.dart';
import 'package:myemail/ui/folder_tree/folder_tree_panel.dart';
import 'package:myemail/ui/messages/search_bar.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';
import 'helpers/open_search.dart';

/// Search filters and recent searches (#43), and search folders (#42).
void main() {
  setUpAll(FakeWebViewPlatform.install);

  MailMessage message(
    int uid, {
    bool read = true,
    bool flagged = false,
    bool files = false,
    Importance importance = Importance.normal,
    DateTime? date,
    int size = 0,
  }) =>
      MailMessage(
        id: 'a:INBOX#$uid',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: uid,
        subject: 'Message $uid',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [],
        date: date ?? DateTime(2026, 10, 28, 9),
        preview: '',
        isRead: read,
        isFlagged: flagged,
        hasAttachments: files,
        importance: importance,
        sizeBytes: size,
      );

  group('the filters', () {
    // Wednesday 28 October 2026.
    final now = DateTime(2026, 10, 28, 15);
    final hits = [
      message(1, read: false),
      message(2, flagged: true),
      message(3, files: true, size: 3 * 1024 * 1024),
      message(4, importance: Importance.high),
      message(5, date: DateTime(2026, 10, 20)),
    ];
    List<int> uids(Set<SearchRefinement> r) => [
          for (final m in refineSearch(hits, r, now: now)) m.uid,
        ];

    test('each keeps only what it says, and together all of them', () {
      expect(uids({}), [1, 2, 3, 4, 5]);
      expect(uids({SearchRefinement.unread}), [1]);
      expect(uids({SearchRefinement.flagged}), [2]);
      expect(uids({SearchRefinement.attachments}), [3]);
      expect(uids({SearchRefinement.important}), [4]);
      expect(uids({SearchRefinement.large}), [3]);
      expect(uids({SearchRefinement.thisWeek}), [1, 2, 3, 4],
          reason: 'the 20th was last week');
      expect(
          uids({SearchRefinement.attachments, SearchRefinement.unread}), isEmpty);
    });

    test('this week starts where the week worked starts', () {
      expect(weekStartFor(now), DateTime(2026, 10, 26), reason: 'Monday');
      expect(weekStartFor(DateTime(2026, 10, 31, 10)), DateTime(2026, 10, 26),
          reason: 'on the Saturday after it');
      expect(weekStartFor(DateTime(2026, 11, 1, 10)), DateTime(2026, 10, 26),
          reason: 'and the Sunday');
      expect(
        weekStartFor(now, workWeek: const {
          DateTime.sunday,
          DateTime.monday,
          DateTime.tuesday,
          DateTime.wednesday,
          DateTime.thursday,
        }),
        DateTime(2026, 10, 25),
        reason: 'a week worked from Sunday',
      );
    });
  });

  test('To is asked of the servers as they ask it', () {
    expect(buildSearchCriteria('dana', field: SearchField.to),
        contains('TO "dana"'));
    expect(GraphMailApi.searchString('dana levi', SearchField.to),
        'to:dana to:levi');
  });

  test('a search folder kept reads back as it was', () {
    const saved = SavedSearch(
      id: 's1',
      name: 'Quotes from Hadco',
      query: 'quote',
      field: SearchField.from,
      refinements: {SearchRefinement.attachments, SearchRefinement.unread},
      accountId: 'acct-1',
    );
    final back = SavedSearch.listFromJson(
        '[${'{"id":"s1","name":"Quotes from Hadco","query":"quote",'
            '"field":"from","refinements":["attachments","unread","nonsense"],'
            '"accountId":"acct-1"}'}, 42]');
    expect(back.single, saved);
    expect(SavedSearch.fromJson(saved.toJson()), saved);
    expect(savedSearchIdOf(savedSearchRowId('s1')), 's1');
    expect(savedSearchIdOf('acct-1:INBOX'), isNull);
  });

  group('on screen', () {
    Future<ProviderContainer> pump(WidgetTester tester,
        {SampleMailEngine? engine}) async {
      tester.view.physicalSize = const Size(1400, 1000);
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

    Future<void> search(WidgetTester tester, String words) async {
      await openSearch(tester);
      await tester.enterText(searchField, words);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }

    testWidgets('a filter narrows the hits without asking the server again',
        (tester) async {
      final engine = _Counting();
      final c = await pump(tester, engine: engine);
      await search(tester, 'the');
      final all = c.read(searchResultsProvider).value!;
      expect(all.where((m) => m.isRead), isNotEmpty);
      final asked = engine.searches;

      await tester.tap(find.byKey(const ValueKey('search-refine-unread')));
      await tester.pumpAndSettle();

      final unread = c.read(searchResultsProvider).value!;
      expect(unread, isNotEmpty);
      expect(unread.every((m) => !m.isRead), isTrue);
      expect(unread.length, lessThan(all.length));
      expect(engine.searches, asked, reason: 'nothing asked again');
    });

    testWidgets('a search closed is offered again when the box opens empty',
        (tester) async {
      final c = await pump(tester);
      await search(tester, 'invoice');
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(c.read(recentSearchesProvider), ['invoice']);

      await openSearch(tester);
      final recent = find.descendant(
        of: find.byKey(const ValueKey('search-recent')),
        matching: find.text('invoice'),
      );
      expect(recent, findsOneWidget);
      await tester.tap(recent);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(c.read(searchQueryProvider), 'invoice');
    });

    testWidgets('saved, it is in the tree, and a tap runs it again',
        (tester) async {
      final c = await pump(tester);
      await search(tester, 'invoice');
      await tester.tap(find.byKey(const ValueKey('search-refine-unread')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('search-save')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('search-folder-name')), 'Unpaid');
      await tester.tap(find.byKey(const ValueKey('search-folder-save')));
      await tester.pumpAndSettle();

      final saved = c.read(savedSearchesProvider).single;
      expect(saved.name, 'Unpaid');
      expect(saved.query, 'invoice');
      expect(saved.refinements, {SearchRefinement.unread});

      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(c.read(searchQueryProvider), isEmpty);
      final row = find.descendant(
        of: find.byType(FolderTreePanel),
        matching: find.text('Unpaid'),
      );
      expect(find.text('SAVED SEARCHES'), findsOneWidget,
          reason: 'the heading, as the tree writes headings');

      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(c.read(searchQueryProvider), 'invoice');
      expect(c.read(searchRefinementsProvider), {SearchRefinement.unread});
      expect(find.byType(MessageSearchBar), findsOneWidget);
    });

    testWidgets('a saved search is renamed and deleted from its own menu',
        (tester) async {
      final c = await pump(tester);
      c.read(savedSearchesProvider.notifier).add(const SavedSearch(
            id: 's1',
            name: 'Quotes',
            query: 'quote',
          ));
      await tester.pumpAndSettle();
      final row = find.descendant(
        of: find.byType(FolderTreePanel),
        matching: find.text('Quotes'),
      );

      await tester.longPress(row);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('search-folder-name')), 'Hadco quotes');
      await tester.tap(find.byKey(const ValueKey('search-folder-save')));
      await tester.pumpAndSettle();
      expect(c.read(savedSearchesProvider).single.name, 'Hadco quotes');

      await tester.longPress(find.descendant(
        of: find.byType(FolderTreePanel),
        matching: find.text('Hadco quotes'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete saved search'));
      await tester.pumpAndSettle();
      expect(c.read(savedSearchesProvider), isEmpty);
      expect(find.text('SAVED SEARCHES'), findsNothing);
    });
  });
}

/// The sample engine, counting the searches asked of it.
class _Counting extends SampleMailEngine {
  int searches = 0;

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  }) {
    searches++;
    return super.searchMessages(query, scope, limit: limit, field: field);
  }
}
