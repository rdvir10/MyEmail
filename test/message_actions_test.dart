import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/address_suggestions.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

/// Refuses every flag change, as a server that is unreachable would.
class _RefusingEngine implements MailEngine {
  final _inner = SampleMailEngine();

  @override
  Future<void> setRead(String messageId, bool isRead) async =>
      throw const ConnectionFailed('offline');

  @override
  Future<void> setFlagged(String messageId, bool isFlagged) async =>
      throw const ConnectionFailed('offline');

  @override
  Future<List<Account>> loadAccounts() => _inner.loadAccounts();
  @override
  Future<Account> addAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  }) =>
      _inner.addAccount(
          displayName: displayName,
          emailAddress: emailAddress,
          provider: provider,
          secret: secret);
  @override
  Future<Account> addOAuthAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required OAuthToken token,
  }) =>
      _inner.addOAuthAccount(
          displayName: displayName,
          emailAddress: emailAddress,
          provider: provider,
          token: token);
  @override
  Future<Account> updateAccount({
    required String accountId,
    String? displayName,
    int? colorValue,
  }) =>
      _inner.updateAccount(
        accountId: accountId,
        displayName: displayName,
        colorValue: colorValue,
      );

  @override
  Future<void> updateAppPassword({
    required String accountId,
    required String secret,
  }) =>
      _inner.updateAppPassword(accountId: accountId, secret: secret);

  @override
  Future<void> updateOAuthToken({
    required String accountId,
    required OAuthToken token,
  }) =>
      _inner.updateOAuthToken(accountId: accountId, token: token);

  @override
  Future<void> removeAccount(String accountId) => _inner.removeAccount(accountId);
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
  Future<List<MailMessage>> loadMessages(String folderId,
          {int offset = 0, int limit = 50}) =>
      _inner.loadMessages(folderId, offset: offset, limit: limit);

  @override
  Future<List<MailMessage>> cachedMessages(String folderId,
          {int offset = 0, int limit = 50}) =>
      _inner.cachedMessages(folderId, offset: offset, limit: limit);
  @override
  Future<MailBody> loadMessageBody(String messageId) =>
      _inner.loadMessageBody(messageId);

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) =>
      _inner.listAttachments(messageId);

  @override
  Future<List<AddressSuggestion>> recentAddresses() =>
      _inner.recentAddresses();

  @override
  Future<Uint8List> fetchAttachment(String messageId, String attachmentId) =>
      _inner.fetchAttachment(messageId, attachmentId);

  @override
  Future<String> rawMessage(String messageId) => _inner.rawMessage(messageId);

  @override
  Future<void> respondToInvite(
    String messageId,
    CalendarInvite invite,
    InviteResponse response,
  ) =>
      _inner.respondToInvite(messageId, invite, response);
  @override
  Future<void> moveMessages(List<String> messageIds, String toFolderId) =>
      _inner.moveMessages(messageIds, toFolderId);
  @override
  Future<void> deleteMessages(List<String> messageIds) =>
      _inner.deleteMessages(messageIds);

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
  }) =>
      _inner.searchMessages(query, scope, limit: limit);

  @override
  Future<void> sendDraft(Draft draft) => _inner.sendDraft(draft);

  @override
  Future<String?> saveDraft(Draft draft) => _inner.saveDraft(draft);
}

void main() {
  group('Messages notifier', () {
    ProviderContainer container({MailEngine? engine}) {
      final c = ProviderContainer(overrides: [
        if (engine != null) mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('setRead updates the list and the folder unread count', () async {
      final c = container();
      await c.read(foldersProvider.future);
      const folderId = 'acct-personal:INBOX';
      final list = await c.read(messagesProvider(folderId).future);
      final target = list.firstWhere((m) => !m.isRead);
      final unreadBefore = c.read(folderIndexProvider)[folderId]!.unreadCount;

      await c.read(messagesProvider(folderId).notifier).setRead(target.id, true);

      final after = c.read(messagesProvider(folderId)).value!;
      expect(after.firstWhere((m) => m.id == target.id).isRead, isTrue);
      expect(
        c.read(folderIndexProvider)[folderId]!.unreadCount,
        unreadBefore - 1,
      );
    });

    test('a refused change is rolled back and rethrown', () async {
      final c = container(engine: _RefusingEngine());
      await c.read(foldersProvider.future);
      const folderId = 'acct-personal:INBOX';
      final list = await c.read(messagesProvider(folderId).future);
      final target = list.firstWhere((m) => !m.isRead);

      await expectLater(
        c.read(messagesProvider(folderId).notifier).setRead(target.id, true),
        throwsA(isA<ConnectionFailed>()),
      );
      final after = c.read(messagesProvider(folderId)).value!;
      expect(after.firstWhere((m) => m.id == target.id).isRead, isFalse);
    });

    test('a change made through the unified inbox reaches the real folder',
        () async {
      final c = container();
      await c.read(foldersProvider.future);
      final unified = await c.read(messagesProvider(kUnifiedInboxId).future);
      final target = unified.firstWhere((m) => !m.isFlagged);

      await c
          .read(messagesProvider(kUnifiedInboxId).notifier)
          .setFlagged(target.id, true);

      final real = await c.read(messagesProvider(target.folderId).future);
      expect(real.firstWhere((m) => m.id == target.id).isFlagged, isTrue);
    });

    test('a no-op change does not touch the engine', () async {
      final c = container(engine: _RefusingEngine());
      await c.read(foldersProvider.future);
      const folderId = 'acct-personal:INBOX';
      final list = await c.read(messagesProvider(folderId).future);
      final alreadyRead = list.firstWhere((m) => m.isRead);
      // Would throw if it reached the refusing engine.
      await c
          .read(messagesProvider(folderId).notifier)
          .setRead(alreadyRead.id, true);
    });
  });

  group('reading pane', () {
    Widget app() => const ProviderScope(child: MaterialApp(home: AppShell()));

    void wide(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('opening an unread message marks it read', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final tiles = find.byType(MessageTile);
      final unreadTile = tiles.evaluate().firstWhere(
          (e) => !(e.widget as MessageTile).message.isRead);
      final id = (unreadTile.widget as MessageTile).message.id;

      await tester.tap(find.byWidget(unreadTile.widget));
      await tester.pumpAndSettle();

      final refreshed = tester
          .widgetList<MessageTile>(tiles)
          .firstWhere((t) => t.message.id == id);
      expect(refreshed.message.isRead, isTrue);
      expect(find.byTooltip('Mark as unread'), findsOneWidget);
    });

    testWidgets('mark as unread and flag toggle from the pane', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Mark as unread'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Mark as read'), findsOneWidget);

      final wasFlagged = find.byTooltip('Remove flag').evaluate().isNotEmpty;
      await tester.tap(find.byTooltip(wasFlagged ? 'Remove flag' : 'Flag'));
      await tester.pumpAndSettle();
      expect(find.byTooltip(wasFlagged ? 'Flag' : 'Remove flag'), findsOneWidget);
    });
  });

  test('sample data has unread mail to exercise this with', () async {
    final engine = SampleMailEngine();
    await engine.loadAccounts();
    await engine.loadFolders('acct-personal');
    final inbox = await engine.loadMessages('acct-personal:INBOX');
    expect(inbox.any((m) => !m.isRead), isTrue);
    final folders = await engine.loadFolders('acct-personal');
    expect(folders.firstWhere((f) => f.role == FolderRole.inbox).unreadCount,
        greaterThan(0));
  });
}
