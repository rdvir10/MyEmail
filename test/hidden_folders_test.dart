import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/folder_tree/folder_tile.dart';
import 'package:myemail/ui/folder_tree/folder_tree_panel.dart';
import 'package:myemail/ui/shell/app_shell.dart';

const _account = Account(
  id: 'a',
  displayName: 'Personal',
  emailAddress: 'me@example.com',
  provider: MailProvider.gmail,
  authMethod: AuthMethod.appPassword,
  colorValue: 0xFF0F6CBD,
);

MailFolder _folder(String path, {FolderRole role = FolderRole.user, String? parent}) =>
    MailFolder.at(
      accountId: 'a',
      path: path,
      role: role,
      capabilities: FolderCapabilities.forGmail(role),
      parentId: parent,
    );

final _inbox = _folder('INBOX', role: FolderRole.inbox);
final _work = _folder('Work');
final _invoices = _folder('Work/Invoices', parent: _work.id);
final _archive = _folder('Archive', role: FolderRole.archive);

List<TreeRow> _rows({
  Set<String> hidden = const {},
  bool showHidden = false,
  Set<String> expanded = const {},
  Set<String> favorites = const {},
  String query = '',
}) =>
    buildTreeRows(
      FolderTreeInput(
        accounts: const [_account],
        foldersByAccount: {
          'a': [_inbox, _work, _invoices, _archive],
        },
        expandedIds: expanded,
        favoriteIds: favorites,
        hiddenIds: hidden,
        showHidden: showHidden,
        searchQuery: query,
      ),
    );

Iterable<String> _paths(List<TreeRow> rows) =>
    rows.whereType<FolderRow>().map((r) => r.folder.path);

void main() {
  group('what may be hidden', () {
    test('anything except an Inbox', () {
      expect(canHideFolder(_work), isTrue);
      expect(canHideFolder(_archive), isTrue);
      expect(canHideFolder(_inbox), isFalse,
          reason: 'hiding the folder the app opens on strands you');
    });

    test('not the unified Inbox, which is not a real folder', () {
      final unified = buildUnifiedInbox({'a': [_inbox]});
      expect(canHideFolder(unified), isFalse);
    });
  });

  group('the tree', () {
    test('a hidden folder is gone', () {
      expect(_paths(_rows()), contains('Archive'));
      expect(_paths(_rows(hidden: {_archive.id})), isNot(contains('Archive')));
    });

    test('hiding a parent takes its children with it', () {
      // Leaving them behind floats them to a depth they do not belong at,
      // which reads as the tree being broken rather than as a setting.
      final rows = _rows(hidden: {_work.id}, expanded: {_work.id});
      expect(_paths(rows), isNot(contains('Work')));
      expect(_paths(rows), isNot(contains('Work/Invoices')));
    });

    test('hiding a child leaves the parent alone', () {
      final rows = _rows(hidden: {_invoices.id}, expanded: {_work.id});
      expect(_paths(rows), contains('Work'));
      expect(_paths(rows), isNot(contains('Work/Invoices')));
    });

    test('showing them brings everything back, marked', () {
      final rows = _rows(
        hidden: {_work.id},
        showHidden: true,
        expanded: {_work.id},
      );
      final work = rows.whereType<FolderRow>().firstWhere(
            (r) => r.folder.path == 'Work',
          );
      final child = rows.whereType<FolderRow>().firstWhere(
            (r) => r.folder.path == 'Work/Invoices',
          );
      expect(work.isHidden, isTrue);
      expect(child.isHidden, isTrue,
          reason: 'it is hidden because its parent is, and says so');
    });

    test('an ordinary folder is never marked hidden', () {
      final rows = _rows(hidden: {_archive.id}, showHidden: true);
      final work = rows.whereType<FolderRow>().firstWhere(
            (r) => r.folder.path == 'Work',
          );
      expect(work.isHidden, isFalse);
    });

    test('hidden folders stay out of Favourites too', () {
      // One rule wherever a folder could appear is what makes it explainable.
      final rows = _rows(hidden: {_archive.id}, favorites: {_archive.id});
      expect(_paths(rows), isNot(contains('Archive')));
      expect(rows.whereType<SectionHeaderRow>().map((r) => r.title),
          isNot(contains('Favourites')));
    });

    test('and out of folder search', () {
      expect(_paths(_rows(query: 'arch')), contains('Archive'));
      expect(
        _paths(_rows(query: 'arch', hidden: {_archive.id})),
        isNot(contains('Archive')),
      );
      expect(
        _paths(_rows(query: 'arch', hidden: {_archive.id}, showHidden: true)),
        contains('Archive'),
      );
    });

    test('the count is what the user chose, not what disappeared', () {
      // A subtree of twenty under one hidden parent is one thing hidden, and
      // "21 hidden" would be a lie about what unhiding undoes.
      final folders = {
        'a': [_inbox, _work, _invoices, _archive],
      };
      expect(countHiddenFolders(folders, {_work.id}), 1);
      expect(countHiddenFolders(folders, {_work.id, _archive.id}), 2);
      expect(countHiddenFolders(folders, const {}), 0);
    });

    test('a parent chain that loops does not hang the tree', () {
      // Defensive: a cycle here would spin forever inside a build.
      final a = MailFolder.at(
        accountId: 'a',
        path: 'A',
        role: FolderRole.user,
        capabilities: FolderCapabilities.forGmail(FolderRole.user),
        parentId: 'a:B',
      );
      final b = MailFolder.at(
        accountId: 'a',
        path: 'B',
        role: FolderRole.user,
        capabilities: FolderCapabilities.forGmail(FolderRole.user),
        parentId: 'a:A',
      );
      expect(
        isFolderHidden(a, {'a:nothing'}, {a.id: a, b.id: b}),
        isFalse,
      );
    });
  });

  group('in the app', () {
    late MemoryUiStateStore store;

    setUp(() => store = MemoryUiStateStore());

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [uiStateStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<ProviderContainer> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('nothing hidden means no row about it', (tester) async {
      await pump(tester);
      expect(find.textContaining('hidden folder'), findsNothing,
          reason: 'a control for nothing is noise');
    });

    testWidgets('hiding one puts the way back at the bottom of the tree',
        (tester) async {
      final c = await pump(tester);
      final folders = c.read(foldersProvider).value!.values.first;
      final target = folders.firstWhere((f) => f.role == FolderRole.user);

      c.read(hiddenFoldersProvider.notifier).hide(target.id);
      await tester.pumpAndSettle();

      expect(find.text('1 hidden folder'), findsOneWidget);
      expect(find.text('Show'), findsOneWidget);
    });

    testWidgets('showing then hiding again is one tap each way',
        (tester) async {
      final c = await pump(tester);
      final folders = c.read(foldersProvider).value!.values.first;
      final target = folders.firstWhere((f) => f.role == FolderRole.user);
      c.read(hiddenFoldersProvider.notifier).hide(target.id);
      await tester.pumpAndSettle();

      final before = tester.widgetList(find.byType(FolderTile)).length;
      await tester.tap(find.text('1 hidden folder'));
      await tester.pumpAndSettle();

      expect(tester.widgetList(find.byType(FolderTile)).length, before + 1);
      expect(find.text('Hide again'), findsOneWidget);

      await tester.tap(find.text('1 hidden folder'));
      await tester.pumpAndSettle();
      expect(tester.widgetList(find.byType(FolderTile)).length, before);
    });

    testWidgets('hiding drops it from Favourites rather than stranding it',
        (tester) async {
      // A favourite you cannot see would either defeat the hiding or leave a
      // favourite that exists nowhere.
      final c = await pump(tester);
      final folders = c.read(foldersProvider).value!.values.first;
      final target = folders.firstWhere((f) => f.role == FolderRole.user);
      c.read(favoriteFoldersProvider.notifier).toggle(target.id);
      await tester.pumpAndSettle();
      // The tree renders its section headings uppercased.
      expect(find.text('FAVOURITES'), findsOneWidget);

      c.read(hiddenFoldersProvider.notifier).hide(target.id);
      await tester.pumpAndSettle();

      expect(c.read(favoriteFoldersProvider), isNot(contains(target.id)));
      expect(find.text('FAVOURITES'), findsNothing,
          reason: 'the section goes with its last member');
    });

    testWidgets('hiding the folder you are reading moves the selection',
        (tester) async {
      // Otherwise the message list belongs to a folder that is nowhere in the
      // tree, with no way to tell what you are looking at.
      final c = await pump(tester);
      final folders = c.read(foldersProvider).value!.values.first;
      final target = folders.firstWhere((f) => f.role == FolderRole.user);
      c.read(selectedFolderIdProvider.notifier).select(target.id);
      await tester.pumpAndSettle();
      expect(c.read(effectiveSelectedFolderIdProvider), target.id);

      c.read(hiddenFoldersProvider.notifier).hide(target.id);
      await tester.pumpAndSettle();

      expect(c.read(effectiveSelectedFolderIdProvider), isNot(target.id));
      expect(c.read(effectiveSelectedFolderIdProvider), isNotNull);
    });

    // A plain test, not a widget one: it awaits the engine, and inside
    // testWidgets the clock only advances on a pump, so a real delay never
    // resolves and the test hangs rather than failing.
    test('the choice survives a restart, the reveal does not', () async {
      final first = container();
      final folders = await first.read(foldersProvider.future);
      final target =
          folders.values.first.firstWhere((f) => f.role == FolderRole.user);
      first.read(hiddenFoldersProvider.notifier).hide(target.id);
      first.read(showHiddenFoldersProvider.notifier).set(true);

      final second = container();
      expect(second.read(hiddenFoldersProvider), contains(target.id),
          reason: 'hiding is a decision about the tree');
      expect(second.read(showHiddenFoldersProvider), isFalse,
          reason: 'revealing is a look behind the curtain, not a preference');
    });

    testWidgets('the tree panel is where the control lives, not Settings',
        (tester) async {
      final c = await pump(tester);
      final folders = c.read(foldersProvider).value!.values.first;
      c.read(hiddenFoldersProvider.notifier).hide(
            folders.firstWhere((f) => f.role == FolderRole.user).id,
          );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(FolderTreePanel),
          matching: find.text('1 hidden folder'),
        ),
        findsOneWidget,
      );
    });
  });
}
