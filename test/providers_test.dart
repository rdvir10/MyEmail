import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/data/widget/widget_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/address_suggestions.dart';
import 'package:myemail/domain/mail_attachment.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/calendar_meeting.dart';
import 'package:myemail/domain/meeting.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/widget_providers.dart';

ProviderContainer _container({MailEngine? engine}) {
  final container = ProviderContainer(
    overrides: [
      if (engine != null) mailEngineProvider.overrideWithValue(engine),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// One account, with its folder list reversed so INBOX is *last*. Anything
/// that picks a default by list position instead of by role fails on this.
class _SingleAccountReversedEngine implements MailEngine {
  final _inner = SampleMailEngine();

  @override
  Future<List<Account>> loadAccounts() async =>
      (await _inner.loadAccounts()).take(1).toList();

  @override
  Future<void> reorderAccounts(List<String> accountIds) =>
      _inner.reorderAccounts(accountIds);

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
        secret: secret,
      );

  @override
  Future<Account> addOAuthAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required OAuthToken token,
    String? signedInAs,
  }) =>
      _inner.addOAuthAccount(
        displayName: displayName,
        emailAddress: emailAddress,
        provider: provider,
        token: token,
        signedInAs: signedInAs,
      );

  @override
  Future<Account> updateAccount({
    required String accountId,
    String? displayName,
    int? colorValue,
    String? senderName,
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
    String? signedInAs,
  }) =>
      _inner.updateOAuthToken(
        accountId: accountId,
        token: token,
        signedInAs: signedInAs,
      );

  @override
  Future<void> removeAccount(String accountId) =>
      _inner.removeAccount(accountId);

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async =>
      (await _inner.loadFolders(accountId)).reversed.toList();

  @override
  Future<List<MailFolder>> cachedFolders(String accountId) async =>
      (await _inner.cachedFolders(accountId)).reversed.toList();

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
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) =>
      _inner.cachedMessages(folderId, offset: offset, limit: limit);

  @override
  Future<MailMessage?> cachedMessage(String messageId) =>
      _inner.cachedMessage(messageId);

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
  Future<List<AddressSuggestion>> searchPeople(String query) =>
      _inner.searchPeople(query);

  @override
  Future<void> warmPeopleSearch() => _inner.warmPeopleSearch();

  @override
  Future<PeopleSearchAccess> peopleSearchAccess(String accountId) =>
      _inner.peopleSearchAccess(accountId);

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
  Future<CalendarMeeting?> meetingOnCalendar(
    String messageId,
    CalendarInvite invite,
  ) =>
      _inner.meetingOnCalendar(messageId, invite);

  @override
  Future<void> removeFromCalendar(CalendarMeeting meeting) =>
      _inner.removeFromCalendar(meeting);

  @override
  Future<void> moveMeeting(CalendarMeeting meeting, CalendarInvite proposal) =>
      _inner.moveMeeting(meeting, proposal);

  @override
  Future<PreparedMeeting?> prepareOnlineMeeting(MeetingDraft meeting) =>
      _inner.prepareOnlineMeeting(meeting);

  @override
  Future<bool> discardPreparedMeeting(PreparedMeeting prepared) =>
      _inner.discardPreparedMeeting(prepared);

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) =>
      _inner.createMeeting(meeting);

  @override
  Future<List<OnlineMeetingKind>> onlineMeetingsFor(String accountId) =>
      _inner.onlineMeetingsFor(accountId);

  @override
  Future<void> setRead(String messageId, bool isRead) =>
      _inner.setRead(messageId, isRead);

  @override
  Future<void> setFlagged(String messageId, bool isFlagged) =>
      _inner.setFlagged(messageId, isFlagged);

  @override
  Future<void> setMessagesRead(List<String> messageIds, bool isRead) =>
      _inner.setMessagesRead(messageIds, isRead);

  @override
  Future<void> setMessagesFlagged(List<String> messageIds, bool isFlagged) =>
      _inner.setMessagesFlagged(messageIds, isFlagged);

  @override
  Future<List<MessageMove>> moveMessages(
    List<String> messageIds,
    String toFolderId,
  ) =>
      _inner.moveMessages(messageIds, toFolderId);

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) =>
      _inner.deleteMessages(messageIds);

  @override
  Future<void> undoMoves(List<MessageMove> moves) => _inner.undoMoves(moves);

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  }) =>
      _inner.searchMessages(query, scope, limit: limit, field: field);

  @override
  Future<List<MailMessage>> filterMessages(
    String folderId,
    MessageFilter filter, {
    int limit = 100,
  }) =>
      _inner.filterMessages(folderId, filter, limit: limit);

  @override
  Future<OpenedHeaders> openedHeaders(String messageId) =>
      _inner.openedHeaders(messageId);

  @override
  bool answersReadReceipts(String accountId) =>
      _inner.answersReadReceipts(accountId);

  @override
  Future<void> sendReadReceipt(String messageId) =>
      _inner.sendReadReceipt(messageId);

  @override
  Future<void> declineReadReceipt(String messageId) =>
      _inner.declineReadReceipt(messageId);

  @override
  bool canRecoverDeleted(String accountId) =>
      _inner.canRecoverDeleted(accountId);

  @override
  Future<List<RecoverableMessage>> recoverableMessages(
    String accountId, {
    String query = '',
    int offset = 0,
    int limit = 50,
  }) =>
      _inner.recoverableMessages(
        accountId,
        query: query,
        offset: offset,
        limit: limit,
      );

  @override
  Future<int> recoverMessages(String accountId, List<String> ids) =>
      _inner.recoverMessages(accountId, ids);

  @override
  Future<void> sendDraft(Draft draft) => _inner.sendDraft(draft);

  @override
  Future<String?> saveDraft(Draft draft) => _inner.saveDraft(draft);

  @override
  Future<void> discardDraft(String savedAs) => _inner.discardDraft(savedAs);
}

void main() {
  group('default selection', () {
    test('several accounts default to the unified inbox', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      expect(c.read(effectiveSelectedFolderIdProvider), kUnifiedInboxId);
    });

    test('a single account defaults to its Inbox by role, not position',
        () async {
      final c = _container(engine: _SingleAccountReversedEngine());
      await c.read(foldersProvider.future);
      expect(c.read(effectiveSelectedFolderIdProvider), 'acct-personal:INBOX');
      expect(c.read(folderIndexProvider).containsKey(kUnifiedInboxId), isFalse,
          reason: 'no unified inbox for one account');
    });

    test('an explicit choice wins over the default', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      c.read(selectedFolderIdProvider.notifier).select('acct-personal:Travel');
      expect(c.read(effectiveSelectedFolderIdProvider), 'acct-personal:Travel');
    });
  });

  group('mutations reach the tree', () {
    test('rename shows up in the rows', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      await c.read(foldersProvider.notifier).rename(
            'acct-personal:Travel',
            'Trips',
          );
      final names = c
          .read(treeRowsProvider)
          .whereType<FolderRow>()
          .map((r) => r.folder.name);
      expect(names, contains('Trips'));
      expect(names, isNot(contains('Travel')));
    });

    test('create appears under an auto-expanded parent', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      await c.read(foldersProvider.notifier).create(
            accountId: 'acct-personal',
            name: 'Insurance',
            parentId: 'acct-personal:Finance',
          );
      expect(c.read(expandedFoldersProvider), contains('acct-personal:Finance'));
      final names = c
          .read(treeRowsProvider)
          .whereType<FolderRow>()
          .map((r) => r.folder.name);
      expect(names, contains('Insurance'));
    });

    test('a name conflict surfaces as FolderNameConflict', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      expect(
        () => c.read(foldersProvider.notifier).create(
              accountId: 'acct-personal',
              name: 'Travel',
            ),
        throwsA(isA<FolderNameConflict>()),
      );
    });
  });

  group("an account's folders listed again", () {
    // Marking forty messages read listed the work mailbox's folders forty
    // times at once, and whichever listing finished last had the last word.
    const account = 'acct-personal';
    const inbox = 'acct-personal:INBOX';

    Future<(ProviderContainer, _HeldListings)> settled() async {
      final engine = _HeldListings();
      final c = _container(engine: engine);
      await c.read(foldersProvider.future);
      // The listing on opening, let finish.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      engine.listed = 0;
      return (c, engine);
    }

    int unreadIn(ProviderContainer c) => c
        .read(foldersProvider)
        .value![account]!
        .firstWhere((f) => f.id == inbox)
        .unreadCount;

    test('one at a time, and one more for every ask made meanwhile',
        () async {
      final (c, engine) = await settled();
      final folders = c.read(foldersProvider.notifier);
      final hold = engine.holdNext = Completer<void>();

      final first = folders.refreshAccount(account);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final more = [
        for (var i = 0; i < 40; i++) folders.refreshAccount(account),
      ];
      hold.complete();
      await Future.wait([first, ...more]);

      expect(engine.listed, 2);
    });

    test('the listing asked for last has the last word', () async {
      final (c, engine) = await settled();
      final folders = c.read(foldersProvider.notifier);
      final unread = (await engine.loadMessages(inbox, limit: 200))
          .firstWhere((m) => !m.isRead);
      final hold = engine.holdNext = Completer<void>();

      // Listed before the message is read, and slow to answer.
      final early = folders.refreshAccount(account);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await engine.setRead(unread.id, true);
      final late = folders.refreshAccount(account);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      hold.complete();
      await Future.wait([early, late]);

      final server = (await engine.cachedFolders(account))
          .firstWhere((f) => f.id == inbox);
      expect(unreadIn(c), server.unreadCount);
    });

    test('marking ten messages read lists the folders twice, not ten times',
        () async {
      final (c, engine) = await settled();
      c.listen(messagesProvider(inbox), (_, _) {});
      final unread = [
        for (final m in await c.read(messagesProvider(inbox).future))
          if (!m.isRead) m,
      ].take(10);
      expect(unread, hasLength(10));
      final hold = engine.holdNext = Completer<void>();

      // One after another, as Mark read does with what is ticked.
      final list = c.read(messagesProvider(inbox).notifier);
      for (final m in unread) {
        await list.setRead(m.id, true);
      }
      hold.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(engine.listed, 2);
    });
  });

  group('id remapping across rename and delete', () {
    test('expand, favourite and selection follow a renamed subtree', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      c.read(expandedFoldersProvider.notifier).expand('acct-personal:Finance');
      c
          .read(favoriteFoldersProvider.notifier)
          .toggle('acct-personal:Finance/Receipts/2026');
      c
          .read(selectedFolderIdProvider.notifier)
          .select('acct-personal:Finance/Receipts');

      await c.read(foldersProvider.notifier).rename(
            'acct-personal:Finance',
            'Money',
          );

      expect(c.read(expandedFoldersProvider), contains('acct-personal:Money'));
      expect(
        c.read(favoriteFoldersProvider),
        contains('acct-personal:Money/Receipts/2026'),
      );
      expect(
        c.read(effectiveSelectedFolderIdProvider),
        'acct-personal:Money/Receipts',
      );
      // And the tree still shows Receipts under the expanded, renamed parent.
      final names = c
          .read(treeRowsProvider)
          .whereType<FolderRow>()
          .map((r) => r.folder.name);
      expect(names, contains('Receipts'));
    });

    test('a home-screen widget follows its folder when a parent is renamed',
        () async {
      // Left on the old id, the widget was written as unassigned on the
      // next refresh and stayed blank until it was set up again.
      final surface = FakeHomeScreenSurface();
      final store = MemoryWidgetStateStore()
        ..mailboxes['7'] = const WidgetMailbox(
          folderId: 'acct-personal:Finance/Receipts',
          label: 'Receipts',
        )
        ..mailboxes['8'] =
            const WidgetMailbox(folderId: 'acct-personal:Travel');
      final c = ProviderContainer(overrides: [
        homeScreenSurfaceProvider.overrideWithValue(surface),
        widgetStateStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      await c.read(foldersProvider.future);

      await c.read(foldersProvider.notifier).rename(
            'acct-personal:Finance',
            'Money',
          );
      for (var i = 0; i < 100 && surface.redraws == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(store.mailboxes['7']?.folderId, 'acct-personal:Money/Receipts');
      expect(store.mailboxes['7']?.label, 'Receipts',
          reason: 'only the folder changes');
      expect(store.mailboxes['8']?.folderId, 'acct-personal:Travel');
      expect(surface.values['widget.7.folder'], 'acct-personal:Money/Receipts',
          reason: 'and it is redrawn under the new id, not left blank');
    });

    test('deleting the selected subtree falls back to the default', () async {
      final c = _container();
      await c.read(foldersProvider.future);
      c
          .read(selectedFolderIdProvider.notifier)
          .select('acct-personal:Finance/Receipts');
      c
          .read(favoriteFoldersProvider.notifier)
          .toggle('acct-personal:Finance/Receipts/2026');

      await c.read(foldersProvider.notifier).delete('acct-personal:Finance');

      expect(c.read(effectiveSelectedFolderIdProvider), kUnifiedInboxId);
      expect(c.read(favoriteFoldersProvider), isEmpty,
          reason: 'a favourite inside the deleted subtree is dropped');
      expect(
        c.read(folderIndexProvider).containsKey('acct-personal:Finance'),
        isFalse,
      );
    });
  });
}

/// The sample accounts, counting how often the personal one's folders are
/// listed, and able to hold the next listing back after it has read them.
class _HeldListings extends SampleMailEngine {
  var listed = 0;
  Completer<void>? holdNext;

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    if (accountId != 'acct-personal') return super.loadFolders(accountId);
    listed++;
    final folders = await super.loadFolders(accountId);
    final hold = holdNext;
    holdNext = null;
    await hold?.future;
    return folders;
  }
}
