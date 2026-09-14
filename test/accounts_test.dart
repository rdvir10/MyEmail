import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailtree/data/mail_engine.dart';
import 'package:mailtree/data/sample/sample_mail_engine.dart';
import 'package:mailtree/domain/account.dart';
import 'package:mailtree/domain/folder_role.dart';
import 'package:mailtree/domain/mail_folder.dart';
import 'package:mailtree/domain/mail_message.dart';
import 'package:mailtree/state/providers.dart';
import 'package:mailtree/ui/accounts/add_account_screen.dart';
import 'package:mailtree/ui/shell/app_shell.dart';

/// An engine that starts with no accounts, as on first run.
class _EmptyEngine implements MailEngine {
  final _inner = SampleMailEngine();
  final List<Account> _accounts = [];

  @override
  Future<List<Account>> loadAccounts() async => List.of(_accounts);

  @override
  Future<Account> addAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  }) async {
    final a = await _inner.addAccount(
      displayName: displayName,
      emailAddress: emailAddress,
      provider: provider,
      secret: secret,
    );
    _accounts.add(a);
    return a;
  }

  @override
  Future<void> removeAccount(String accountId) async {
    _accounts.removeWhere((a) => a.id == accountId);
    await _inner.removeAccount(accountId);
  }

  @override
  Future<List<MailFolder>> loadFolders(String accountId) =>
      _inner.loadFolders(accountId);

  @override
  Future<FolderRename> renameFolder(String folderId, String newName) =>
      _inner.renameFolder(folderId, newName);

  @override
  Future<FolderRename> moveFolder(String folderId, String? newParentId) =>
      _inner.moveFolder(folderId, newParentId);

  @override
  Future<void> deleteFolder(String folderId) => _inner.deleteFolder(folderId);

  @override
  Future<MailFolder> createFolder({
    required String accountId,
    required String name,
    String? parentId,
  }) =>
      _inner.createFolder(accountId: accountId, name: name, parentId: parentId);

  @override
  Future<void> markAllRead(String folderId) => _inner.markAllRead(folderId);

  @override
  Future<void> emptyFolder(String folderId) => _inner.emptyFolder(folderId);

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) =>
      _inner.loadMessages(folderId, offset: offset, limit: limit);

  @override
  Future<MailBody> loadMessageBody(String messageId) =>
      _inner.loadMessageBody(messageId);

  @override
  Future<void> setRead(String messageId, bool isRead) =>
      _inner.setRead(messageId, isRead);

  @override
  Future<void> setFlagged(String messageId, bool isFlagged) =>
      _inner.setFlagged(messageId, isFlagged);
}

void main() {
  group('sample engine accounts', () {
    test('an empty password is refused like a server would', () async {
      final engine = SampleMailEngine();
      expect(
        () => engine.addAccount(
          displayName: 'x',
          emailAddress: 'x@example.com',
          provider: MailProvider.gmail,
          secret: '   ',
        ),
        throwsA(isA<AuthenticationFailed>()),
      );
    });

    test('a new account gets the standard Gmail folders, empty', () async {
      final engine = SampleMailEngine();
      final a = await engine.addAccount(
        displayName: 'Work',
        emailAddress: 'work@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      expect((await engine.loadAccounts()).map((x) => x.id), contains(a.id));
      final folders = await engine.loadFolders(a.id);
      expect(folders.map((f) => f.role).toSet(), {
        FolderRole.inbox,
        FolderRole.drafts,
        FolderRole.sent,
        FolderRole.deleted,
        FolderRole.junk,
        FolderRole.archive,
      });
      expect(folders.every((f) => f.totalCount == 0), isTrue);
    });

    test('the same address twice is refused', () async {
      final engine = SampleMailEngine();
      expect(
        () => engine.addAccount(
          displayName: 'dup',
          emailAddress: 'personal@example.com',
          provider: MailProvider.gmail,
          secret: 'abcd',
        ),
        throwsA(isA<AuthenticationFailed>()),
      );
    });

    test('removing an account drops its folders', () async {
      final engine = SampleMailEngine();
      await engine.removeAccount('acct-side');
      expect((await engine.loadAccounts()).map((a) => a.id),
          isNot(contains('acct-side')));
      expect(await engine.loadFolders('acct-side'), isEmpty);
    });
  });

  group('Accounts notifier', () {
    test('adding an account makes its folders appear', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(foldersProvider.future);
      expect(c.read(foldersProvider).value, hasLength(2));

      await c.read(accountsProvider.notifier).add(
            displayName: 'Work',
            emailAddress: 'work@example.com',
            provider: MailProvider.gmail,
            secret: 'abcdabcdabcdabcd',
          );
      // foldersProvider watches accounts, so it rebuilds.
      await c.read(foldersProvider.future);
      expect(c.read(foldersProvider).value, hasLength(3));
    });
  });

  group('add account screen', () {
    Widget app(MailEngine engine) => ProviderScope(
          overrides: [mailEngineProvider.overrideWithValue(engine)],
          child: const MaterialApp(home: AppShell()),
        );

    testWidgets('first run shows the welcome form instead of the tree',
        (tester) async {
      await tester.pumpWidget(app(_EmptyEngine()));
      await tester.pumpAndSettle();

      expect(find.text('Welcome to MailTree'), findsOneWidget);
      expect(find.text('Search folders'), findsNothing);
    });

    testWidgets('a refused password shows the server message inline',
        (tester) async {
      await tester.pumpWidget(app(_EmptyEngine()));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Gmail address'), 'me@example.com');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'App password'), '   ');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      // Local validation catches whitespace-only before the engine does.
      expect(find.text('Enter the app password.'), findsOneWidget);
    });

    testWidgets('signing in adds the account and lands in the tree',
        (tester) async {
      await tester.pumpWidget(app(_EmptyEngine()));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Gmail address'), 'me@example.com');
      await tester.enterText(find.widgetWithText(TextFormField, 'App password'),
          'abcd efgh ijkl mnop');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Welcome to MailTree'), findsNothing);
      expect(find.byType(AddAccountScreen), findsNothing);

      // Phone layout: the tree is in the drawer.
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.text('ME'), findsOneWidget,
          reason: 'display name defaults to the local part, shown uppercased');
      expect(find.text('Inbox'), findsWidgets);
    });

    testWidgets('the tree footer opens the add-account screen', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: AppShell())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add account'));
      await tester.pumpAndSettle();

      expect(find.byType(AddAccountScreen), findsOneWidget);
      expect(find.text('Add account'), findsWidgets);
    });
  });
}
