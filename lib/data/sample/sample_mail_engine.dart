import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../domain/account.dart';
import '../../domain/account_colours.dart';
import '../../domain/draft.dart';
import '../../domain/folder_capabilities.dart';
import '../../domain/folder_role.dart';
import '../../domain/address_suggestions.dart';
import '../../domain/calendar_invite.dart';
import '../../domain/calendar_meeting.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_folder.dart';
import '../../domain/mail_message.dart';
import '../../domain/meeting.dart';
import '../../domain/message_move.dart';
import '../compose/quote_builder.dart';
import '../imap/imap_mapping.dart';
import '../auth/oauth_token.dart';
import '../contacts/account_people.dart' show AccountPeople;
import '../mail_engine.dart';
import 'sample_messages.dart';

/// In-memory stand-in for the real IMAP engine, used for layout work and tests.
///
/// The shape deliberately mirrors real Gmail rather than being convenient:
/// system folders live under `[Gmail]` and refuse structural edits, user labels
/// nest several levels deep, and counts are uneven. Sample data that is tidier
/// than reality hides exactly the layout bugs this is meant to catch.
///
/// Behaviour also mirrors IMAP where it matters for the UI: renaming or moving
/// a folder rewrites the path (and therefore the id) of its whole subtree, and
/// a name that collides with a sibling is refused.
class SampleMailEngine implements MailEngine {
  SampleMailEngine() {
    for (final account in _accounts) {
      _folders[account.id] = _buildFolders(account.id, _specsFor(account.id));
    }
  }

  final List<Account> _accounts = List.of(_seedAccounts);

  @override
  Future<Account> addAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  }) async {
    await _latency();
    // The sample engine cannot check a password, but it can behave like a
    // server that refuses an empty one, so the screen's error path is real.
    if (secret.trim().isEmpty) {
      throw const AuthenticationFailed('The server refused the password.');
    }
    return _remember(
      displayName: displayName,
      emailAddress: emailAddress,
      provider: provider,
      authMethod: AuthMethod.appPassword,
    );
  }

  @override
  Future<Account> addOAuthAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required OAuthToken token,
    String? signedInAs,
  }) async {
    await _latency();
    if (signedInAs != null &&
        signedInAs.toLowerCase() != emailAddress.trim().toLowerCase()) {
      throw AuthenticationFailed(
        'That sign-in is for $signedInAs, not ${emailAddress.trim()}.',
      );
    }
    return _remember(
      displayName: displayName,
      emailAddress: emailAddress,
      provider: provider,
      authMethod: AuthMethod.oauth,
    );
  }

  @override
  Future<Account> updateAccount({
    required String accountId,
    String? displayName,
    int? colorValue,
    String? senderName,
  }) async {
    await _latency();
    final i = _accounts.indexWhere((a) => a.id == accountId);
    if (i < 0) throw StateError('Unknown account $accountId');
    final trimmed = displayName?.trim();
    final updated = _accounts[i].copyWith(
      displayName: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      colorValue: colorValue,
      senderName: senderName?.trim(),
    );
    _accounts[i] = updated;
    return updated;
  }

  @override
  Future<void> reorderAccounts(List<String> accountIds) async {
    await _latency();
    final ordered = accountsInOrder(_accounts, accountIds);
    _accounts
      ..clear()
      ..addAll(ordered);
  }

  @override
  Future<void> updateAppPassword({
    required String accountId,
    required String secret,
  }) async {
    await _latency();
    // The sample engine cannot check a password, but it can behave like a
    // server that refuses an empty one, so the screen's error path is real.
    if (secret.trim().isEmpty) {
      throw const AuthenticationFailed('The server refused the password.');
    }
    _requireAccount(accountId);
  }

  @override
  Future<void> updateOAuthToken({
    required String accountId,
    required OAuthToken token,
    String? signedInAs,
  }) async {
    await _latency();
    _requireAccount(accountId);
    final i = _accounts.indexWhere((a) => a.id == accountId);
    if (signedInAs != null &&
        signedInAs.toLowerCase() != _accounts[i].emailAddress.toLowerCase()) {
      throw AuthenticationFailed(
        'That sign-in is for $signedInAs, not ${_accounts[i].emailAddress}.',
      );
    }
    // As the real engine does: a password account signs in with the token
    // from here on.
    _accounts[i] = _accounts[i].copyWith(authMethod: AuthMethod.oauth);
  }

  void _requireAccount(String accountId) {
    if (!_accounts.any((a) => a.id == accountId)) {
      throw StateError('Unknown account $accountId');
    }
  }

  Future<Account> _remember({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required AuthMethod authMethod,
  }) async {
    if (_accounts.any((a) => a.emailAddress == emailAddress)) {
      throw AuthenticationFailed('$emailAddress is already set up.');
    }
    final account = Account(
      id: 'acct-${_accounts.length + 1}',
      displayName: displayName,
      emailAddress: emailAddress,
      provider: provider,
      authMethod: authMethod,
      colorValue: newAccountColours[_accounts.length % newAccountColours.length],
    );
    _accounts.add(account);
    _folders[account.id] = _buildFolders(account.id, _freshAccountSpecs);
    return account;
  }

  @override
  Future<void> removeAccount(String accountId) async {
    await _latency();
    _accounts.removeWhere((a) => a.id == accountId);
    _folders.remove(accountId);
    _messages.removeWhere((key, _) => key.startsWith('$accountId:'));
  }

  static const _seedAccounts = <Account>[
    Account(
      id: 'acct-personal',
      displayName: 'Personal',
      emailAddress: 'personal@example.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF0F6CBD,
    ),
    Account(
      id: 'acct-side',
      displayName: 'Projects',
      emailAddress: 'projects@example.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF107C41,
    ),
  ];

  final Map<String, List<MailFolder>> _folders = {};

  /// Generated lazily per folder and then held, so flags changed later
  /// (milestone 4) stick for the rest of the run.
  final Map<String, List<MailMessage>> _messages = {};

  /// Bodies of messages this engine was given rather than generated, which
  /// today means saved drafts. Reopening one must show what was written.
  final Map<String, MailBody> _savedBodies = {};

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    await _latency();
    final all = _messages.putIfAbsent(
      folderId,
      () => generateSampleMessages(_require(folderId)),
    );
    if (offset >= all.length) return const [];
    return List.unmodifiable(all.sublist(offset, min(all.length, offset + limit)));
  }

  /// Nothing is stored until the folders have been listed once, which is
  /// what a real account does before its first sync too.
  @override
  Future<List<MailFolder>> cachedFolders(String accountId) async =>
      _folders[accountId] ?? const [];

  /// Nothing is cached until a folder has been asked for once, which is
  /// what a real cache does on the first visit to a folder too.
  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final all = _messages[folderId];
    if (all == null || offset >= all.length) return const [];
    return List.unmodifiable(all.sublist(offset, min(all.length, offset + limit)));
  }

  @override
  Future<MailMessage?> cachedMessage(String messageId) async {
    final folderId = messageId.substring(0, messageId.lastIndexOf('#'));
    for (final m in _messages[folderId] ?? const <MailMessage>[]) {
      if (m.id == messageId) return m;
    }
    return null;
  }

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    await _latency();
    final folderId = messageId.substring(0, messageId.lastIndexOf('#'));
    final message = _messages[folderId]?.firstWhere(
      (m) => m.id == messageId,
      orElse: () => throw StateError('No such message: $messageId'),
    );
    if (message == null) throw StateError('No such message: $messageId');
    // A saved draft has a real body. Everything else is generated, which is
    // the whole point of the sample engine.
    return _savedBodies[messageId] ?? generateSampleBody(message);
  }

  @override
  Future<List<MessageMove>> moveMessages(
    List<String> messageIds,
    String toFolderId,
  ) async {
    await _latency();
    final target = _require(toFolderId);
    final landed = <String, List<String>>{};
    for (final id in messageIds) {
      final fromId = id.substring(0, id.lastIndexOf('#'));
      if (fromId == toFolderId) continue;
      // Into another account as into another folder: sample mail is only
      // ever here, and has no Trash copy to leave behind.
      final source = _require(fromId);
      final list = _messages[fromId];
      final i = list?.indexWhere((m) => m.id == id) ?? -1;
      if (list == null || i < 0) continue;
      final message = list.removeAt(i);

      final destination = _messages.putIfAbsent(
        toFolderId,
        () => generateSampleMessages(target),
      );
      final uid = destination.isEmpty
          ? 1
          : destination.map((m) => m.uid).reduce(max) + 1;
      destination.insert(
        0,
        MailMessage(
          id: MailMessage.idFor(toFolderId, uid),
          accountId: target.accountId,
          folderId: toFolderId,
          uid: uid,
          subject: message.subject,
          from: message.from,
          to: message.to,
          date: message.date,
          preview: message.preview,
          isRead: message.isRead,
          isFlagged: message.isFlagged,
          hasAttachments: message.hasAttachments,
        ),
      );
      (landed[fromId] ??= []).add(MailMessage.idFor(toFolderId, uid));
      _adjustCounts(source, removed: message);
      _adjustCounts(target, added: message);
    }
    return [
      for (final entry in landed.entries)
        MessageMove(
          fromFolderId: entry.key,
          toFolderId: toFolderId,
          movedIds: entry.value,
        ),
    ];
  }

  @override
  Future<void> undoMoves(List<MessageMove> moves) async {
    for (final move in moves) {
      if (move.movedIds.isEmpty) continue;
      await moveMessages(move.movedIds, move.fromFolderId);
    }
  }

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    // Gmail's convention: into Trash from anywhere else, gone from Trash.
    final byFolder = <String, List<String>>{};
    for (final id in messageIds) {
      (byFolder[id.substring(0, id.lastIndexOf('#'))] ??= []).add(id);
    }
    final moves = <MessageMove>[];
    for (final entry in byFolder.entries) {
      final source = _require(entry.key);
      final trash = _folders[source.accountId]!
          .where((f) => f.role == FolderRole.deleted)
          .firstOrNull;
      if (trash == null || trash.id == source.id) {
        await _latency();
        final list = _messages[entry.key];
        if (list == null) continue;
        for (final id in entry.value) {
          final i = list.indexWhere((m) => m.id == id);
          if (i >= 0) _adjustCounts(_require(entry.key), removed: list.removeAt(i));
        }
        moves.add(MessageMove(
          fromFolderId: entry.key,
          toFolderId: entry.key,
          movedIds: const [],
        ));
      } else {
        moves.addAll(await moveMessages(entry.value, trash.id));
      }
    }
    return moves;
  }

  void _adjustCounts(
    MailFolder folder, {
    MailMessage? added,
    MailMessage? removed,
  }) {
    var unread = folder.unreadCount;
    var total = folder.totalCount;
    if (added != null) {
      total += 1;
      if (!added.isRead) unread += 1;
    }
    if (removed != null) {
      total = max(0, total - 1);
      if (!removed.isRead) unread = max(0, unread - 1);
    }
    _replace(folder.copyWith(unreadCount: unread, totalCount: total));
  }

  @override
  Future<List<MailMessage>> filterMessages(
    String folderId,
    MessageFilter filter, {
    int limit = 100,
  }) async {
    await _latency();
    if (filter == MessageFilter.all) return const [];
    final list = _messages.putIfAbsent(
      folderId,
      () => generateSampleMessages(_require(folderId)),
    );
    // The sample mail is all to me@example.com, whichever account it is in.
    final own = {
      'me@example.com',
      for (final a in _accounts) a.emailAddress.toLowerCase(),
    };
    return [
      for (final m in list)
        if (filter.matches(m, own)) m,
    ].take(limit).toList();
  }

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  }) async {
    await _latency();
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final words = needle.split(RegExp(r'\s+'));

    final folders = <MailFolder>[];
    if (scope.folderId != null) {
      folders.add(_require(scope.folderId!));
    } else {
      final accountIds = scope.accountId != null
          ? [scope.accountId!]
          : _accounts.map((a) => a.id);
      for (final accountId in accountIds) {
        for (final f in _folders[accountId] ?? const <MailFolder>[]) {
          // Spam and Trash are not what "search my mail" means. All Mail
          // is searched, as the real engine searches it for the mail
          // archived with no label. Here its mail is made up on its own
          // and is no copy of another folder's, so there is none to drop.
          if (f.role == FolderRole.junk || f.role == FolderRole.deleted) {
            continue;
          }
          folders.add(f);
        }
      }
    }

    final hits = <MailMessage>[];
    for (final folder in folders) {
      final list = _messages.putIfAbsent(
        folder.id,
        () => generateSampleMessages(folder),
      );
      for (final m in list) {
        final haystack = switch (field) {
          SearchField.all =>
            '${m.subject} ${m.from.display} ${m.from.email} ${m.preview}',
          SearchField.from => '${m.from.display} ${m.from.email}',
          SearchField.subject => m.subject,
          SearchField.body => m.preview,
          SearchField.attachment =>
            _sampleAttachments(m).map((a) => a.name).join(' '),
        }
            .toLowerCase();
        if (words.every(haystack.contains)) hits.add(m);
      }
    }
    hits.sort((a, b) => b.date.compareTo(a.date));
    return hits.take(limit).toList();
  }

  @override
  Future<void> discardDraft(String savedAs) async {
    await _latency();
    final folderId = savedAs.substring(0, savedAs.lastIndexOf('#'));
    _messages[folderId]?.removeWhere((m) => m.id == savedAs);
  }

  @override
  Future<String?> saveDraft(Draft draft) async {
    await _latency();
    final drafts = (_folders[draft.accountId] ?? const <MailFolder>[])
        .where((f) => f.role == FolderRole.drafts)
        .firstOrNull;
    if (drafts == null) {
      throw const SendFailed(
        'The app cannot find a Drafts folder for this account, so the '
        'message was not saved.',
      );
    }

    final list = _messages.putIfAbsent(drafts.id, () => []);
    // Replace the copy this was opened from, rather than piling up a version
    // per save, which is what the real engine does with \Deleted and EXPUNGE.
    final previous = draft.savedAs;
    if (previous != null) list.removeWhere((m) => m.id == previous);

    final uid = list.isEmpty ? 1 : list.map((m) => m.uid).reduce(max) + 1;
    final account = _accounts.firstWhere((a) => a.id == draft.accountId);
    final id = MailMessage.idFor(drafts.id, uid);
    list.insert(
      0,
      MailMessage(
        id: id,
        accountId: draft.accountId,
        folderId: drafts.id,
        uid: uid,
        subject: draft.subject.trim().isEmpty
            ? '(No subject)'
            : draft.subject.trim(),
        from: MailAddress(
          email: account.emailAddress,
          name: account.displayName,
        ),
        to: draft.to,
        date: DateTime.now(),
        preview: previewFromText(plainTextFromHtml(draft.htmlBody)),
        isRead: true,
        hasAttachments: draft.attachments.isNotEmpty,
      ),
    );
    _savedBodies[id] = MailBody(
      text: plainTextFromHtml(draft.htmlBody),
      html: draft.htmlBody,
    );
    _replace(drafts.copyWith(totalCount: list.length));
    return id;
  }

  @override
  Future<void> sendDraft(Draft draft) async {
    await _latency();
    if (!draft.hasRecipients) {
      throw const SendFailed('Add at least one recipient.');
    }
    _markOriginals(draft);
    final sent = (_folders[draft.accountId] ?? const <MailFolder>[])
        .where((f) => f.role == FolderRole.sent)
        .firstOrNull;
    if (sent == null) return;

    final list = _messages.putIfAbsent(
      sent.id,
      () => generateSampleMessages(sent),
    );
    final uid = list.isEmpty ? 1 : list.map((m) => m.uid).reduce(max) + 1;
    final account =
        _accounts.firstWhere((a) => a.id == draft.accountId);
    list.insert(
      0,
      MailMessage(
        id: MailMessage.idFor(sent.id, uid),
        accountId: draft.accountId,
        folderId: sent.id,
        uid: uid,
        subject: draft.subject.trim().isEmpty
            ? '(No subject)'
            : draft.subject.trim(),
        from: MailAddress(
          email: account.emailAddress,
          name: account.displayName,
        ),
        to: draft.to,
        date: DateTime.now(),
        preview: previewFromText(plainTextFromHtml(draft.htmlBody)),
        isRead: true,
        hasAttachments: draft.attachments.isNotEmpty,
      ),
    );
    _replace(sent.copyWith(totalCount: sent.totalCount + 1));

    // Away, so the copy in Drafts is now a duplicate of sent mail.
    final previous = draft.savedAs;
    if (previous != null) {
      for (final folderMessages in _messages.values) {
        folderMessages.removeWhere((m) => m.id == previous);
      }
    }
  }

  /// What the real engine does once a message is away: the message it
  /// replied to or forwarded is marked so, and so is each it carried as an
  /// attachment. The Gmail way, as this engine is: a message can be both.
  void _markOriginals(Draft draft) {
    void mark(String messageId, {required bool forwarded}) {
      final folderId = messageId.substring(0, messageId.lastIndexOf('#'));
      final list = _messages[folderId];
      final i = list?.indexWhere((m) => m.id == messageId) ?? -1;
      if (list == null || i < 0) return;
      list[i] = forwarded
          ? list[i].copyWith(isForwarded: true)
          : list[i].copyWith(isAnswered: true);
    }

    final original = draft.originalMessageId;
    if (original != null && draft.kind != ComposeKind.newMessage) {
      mark(original, forwarded: draft.kind == ComposeKind.forward);
    }
    for (final a in draft.attachments) {
      final forwarded = a.forwardedMessageId;
      if (forwarded != null) mark(forwarded, forwarded: true);
    }
  }

  @override
  Future<List<AddressSuggestion>> recentAddresses() async {
    await _latency();
    // Every message the sample data has generated so far, so the people in
    // the inbox are the people suggested. What is in a Sent folder counts
    // as written from here whoever the sample data made its sender.
    final mine = {for (final a in _accounts) a.emailAddress.toLowerCase()};
    final sentFolders = {
      for (final folders in _folders.values)
        for (final f in folders)
          if (f.role == FolderRole.sent) f.id,
    };
    return historyFrom(
      [
        for (final MapEntry(key: folderId, value: messages)
            in _messages.entries)
          for (final m in messages)
            for (final (i, a) in [m.from, ...m.to, ...m.cc].indexed)
              (
                address: a,
                date: m.date,
                sent: i > 0 &&
                    (sentFolders.contains(folderId) ||
                        mine.contains(m.from.email.toLowerCase())),
              ),
      ],
      now: DateTime.now(),
    );
  }

  @override
  Future<List<AddressSuggestion>> searchPeople(String query) async =>
      const [];

  @override
  Future<void> warmPeopleSearch() async {}

  @override
  Future<PeopleSearchAccess> peopleSearchAccess(String accountId) async {
    final account = _accounts.where((a) => a.id == accountId).firstOrNull;
    return PeopleSearchAccess(
      account != null && AccountPeople.canSearch(account)
          ? PeopleSearchState.on
          : PeopleSearchState.notPossible,
    );
  }

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async {
    await _latency();
    final folderId = messageId.substring(0, messageId.lastIndexOf('#'));
    final message = _messages[folderId]
        ?.where((m) => m.id == messageId)
        .firstOrNull;
    if (message == null) return const [];
    return _sampleAttachments(message);
  }

  /// The files on a sample message: made up from its number, so the same
  /// message always has the same files and a widget test can count on
  /// them. None on a message without attachments.
  static List<MailAttachment> _sampleAttachments(MailMessage message) {
    if (!message.hasAttachments) return const [];
    return [
      MailAttachment(
        id: '2',
        name: 'Quote ${message.uid}.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 184320,
      ),
      MailAttachment(
        id: '3',
        name: 'Photo ${message.uid}.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 1048576,
      ),
    ];
  }

  /// How each sample message's list says to leave it, by message id, for
  /// a test to fill: none says anything otherwise.
  final Map<String, UnsubscribeOptions> unsubscribe = {};

  /// Who each sample message asks a read receipt to go to, by message id,
  /// for a test to fill; and the receipts sent and declined.
  final Map<String, String> receiptRequests = {};
  final List<String> receiptsSent = [];
  final List<String> receiptsDeclined = [];

  @override
  Future<OpenedHeaders> openedHeaders(String messageId) async {
    await _latency();
    return OpenedHeaders(
      unsubscribe: unsubscribe[messageId],
      receiptTo: receiptRequests[messageId],
    );
  }

  /// Gmail accounts, as the real engine has it: every sample account.
  @override
  bool answersReadReceipts(String accountId) => _accounts.any(
        (a) => a.id == accountId && a.provider == MailProvider.gmail,
      );

  @override
  Future<void> sendReadReceipt(String messageId) async {
    await _latency();
    receiptsSent.add(messageId);
  }

  @override
  Future<void> declineReadReceipt(String messageId) async {
    receiptsDeclined.add(messageId);
  }

  /// What Recover Deleted Items lists, by account id, for a test to fill.
  final Map<String, List<RecoverableMessage>> recoverable = {};

  /// Microsoft accounts, as the real engine has it.
  @override
  bool canRecoverDeleted(String accountId) => _accounts.any(
        (a) => a.id == accountId && a.provider == MailProvider.outlook,
      );

  @override
  Future<List<RecoverableMessage>> recoverableMessages(
    String accountId, {
    String query = '',
    int offset = 0,
    int limit = 50,
  }) async {
    await _latency();
    if (!canRecoverDeleted(accountId)) {
      throw FolderOperationNotSupported(accountId, 'recover deleted items');
    }
    final words = query.trim().toLowerCase();
    final all = [
      for (final m in recoverable[accountId] ?? const <RecoverableMessage>[])
        if (words.isEmpty ||
            m.subject.toLowerCase().contains(words) ||
            m.from.display.toLowerCase().contains(words))
          m,
    ]..sort((a, b) => b.received.compareTo(a.received));
    return all.skip(words.isEmpty ? offset : 0).take(limit).toList();
  }

  /// Into the account's Inbox, at the top, as the server would.
  @override
  Future<int> recoverMessages(String accountId, List<String> ids) async {
    await _latency();
    final kept = recoverable[accountId] ?? const <RecoverableMessage>[];
    final going = [
      for (final m in kept)
        if (ids.contains(m.id)) m,
    ];
    recoverable[accountId] = [
      for (final m in kept)
        if (!ids.contains(m.id)) m,
    ];
    final inbox = (_folders[accountId] ?? const <MailFolder>[])
        .where((f) => f.role == FolderRole.inbox)
        .firstOrNull;
    if (inbox != null) {
      final list =
          _messages.putIfAbsent(inbox.id, () => generateSampleMessages(inbox));
      for (final m in going) {
        final uid = list.isEmpty ? 1 : list.map((x) => x.uid).reduce(max) + 1;
        list.insert(
          0,
          MailMessage(
            id: MailMessage.idFor(inbox.id, uid),
            accountId: accountId,
            folderId: inbox.id,
            uid: uid,
            subject: m.subject,
            from: m.from,
            to: const [],
            date: m.received,
            preview: m.preview,
            isRead: true,
            hasAttachments: m.hasAttachments,
          ),
        );
      }
      _replace(inbox.copyWith(totalCount: list.length));
    }
    return going.length;
  }

  /// Every answer given, for tests to look at.
  final List<({String messageId, InviteResponse response})> inviteResponses = [];

  @override
  Future<void> respondToInvite(
    String messageId,
    CalendarInvite invite,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
  }) async {
    await _latency();
    inviteResponses.add((messageId: messageId, response: response));
    inviteAnswers.add((
      messageId: messageId,
      response: response,
      note: note,
      send: send,
      proposal: proposal,
    ));
  }

  /// Every answer, with what went with it, for tests to look at.
  final List<
      ({
        String messageId,
        InviteResponse response,
        String note,
        bool send,
        TimeSpan? proposal,
      })> inviteAnswers = [];

  /// Which accounts can propose a new time, as a Microsoft one can; none of
  /// the sample's, unless a test says so.
  final Set<String> proposesNewTimes = {};

  @override
  bool canProposeNewTime(String accountId) =>
      proposesNewTimes.contains(accountId);

  /// What [mailTips] answers, by address, for a test to fill.
  final Map<String, MailTip> tips = {};

  @override
  Future<List<MailTip>> mailTips(String accountId, List<String> emails) async {
    await _latency();
    return [
      for (final e in emails) ?tips[e.toLowerCase()],
    ];
  }

  /// The sample calendars' busy times, by address in lower case, for a test
  /// to fill; an address not in it is one the calendar cannot see.
  final Map<String, List<TimeSpan>> busy = {};

  @override
  Future<List<TimeSpan>> busyTimes(
    String accountId,
    DateTime start,
    DateTime end,
  ) async {
    // The accounts as loaded, which a test's engine may have changed.
    final account =
        (await loadAccounts()).firstWhere((a) => a.id == accountId);
    return busy[account.emailAddress.toLowerCase()] ?? const [];
  }

  @override
  Future<Map<String, List<TimeSpan>?>> schedules(
    String accountId,
    List<String> emails,
    DateTime start,
    DateTime end,
  ) async {
    await _latency();
    return {for (final e in emails) e.toLowerCase(): busy[e.toLowerCase()]};
  }

  /// The sample calendar, by invitation UID: what [meetingOnCalendar]
  /// finds, for tests to fill. Empty, so no meeting is on it.
  final Map<String, CalendarMeeting> calendar = {};

  /// Every meeting taken off the calendar, and every one moved with the
  /// time proposed, for tests to look at.
  final List<CalendarMeeting> removedFromCalendar = [];
  final List<({CalendarMeeting meeting, CalendarInvite proposal})> moved = [];

  @override
  Future<CalendarMeeting?> meetingOnCalendar(
    String messageId,
    CalendarInvite invite,
  ) async {
    await _latency();
    return calendar[invite.uid];
  }

  @override
  Future<void> removeFromCalendar(CalendarMeeting meeting) async {
    await _latency();
    removedFromCalendar.add(meeting);
    calendar.removeWhere((_, m) => m.eventId == meeting.eventId);
  }

  /// Moves it on the sample calendar too, as a real one would.
  @override
  Future<void> moveMeeting(
    CalendarMeeting meeting,
    CalendarInvite proposal,
  ) async {
    await _latency();
    moved.add((meeting: meeting, proposal: proposal));
    for (final entry in calendar.entries.toList()) {
      if (entry.value.eventId != meeting.eventId) continue;
      calendar[entry.key] = CalendarMeeting(
        accountId: meeting.accountId,
        eventId: meeting.eventId,
        start: proposal.start.toUtc(),
        end: proposal.end?.toUtc(),
        isAllDay: proposal.isAllDay,
        isOrganizer: meeting.isOrganizer,
      );
    }
  }

  /// Every meeting created, for tests to look at.
  final List<MeetingDraft> meetings = [];

  /// Kept, whatever the account: the sample engine has no calendar to be
  /// without, and the screen's other ways out are tried with fakes that
  /// throw. Held online, it answers with a link of the kind the account
  /// would have got.
  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) async {
    await _latency();
    final problem = meeting.problem;
    if (problem != null) throw ArgumentError(problem);
    meetings.add(meeting);
    return CreatedMeeting(
      // The event made ahead is the meeting now, as the real calendars
      // answer.
      id: meeting.preparedHere?.eventId ?? 'sample-meeting-${meetings.length}',
      joinUrl: meeting.preparedHere?.joinUrl ??
          switch (meeting.online) {
            null => null,
            OnlineMeetingKind.googleMeet =>
              'https://meet.google.com/abc-defg-hij',
            _ => 'https://teams.microsoft.com/l/meetup-join/sample',
          },
    );
  }

  /// Every online meeting made ahead of Send, and every one undone, for
  /// tests to look at.
  final List<PreparedMeeting> preparedMeetings = [];
  final List<PreparedMeeting> discardedMeetings = [];

  /// A meeting made ahead with the text the real calendars show: a Teams
  /// block for Teams, the Meet link for Meet. An event with nobody on it,
  /// except for Meet on a Microsoft account, which is a link alone.
  @override
  Future<PreparedMeeting?> prepareOnlineMeeting(MeetingDraft meeting) async {
    await _latency();
    final kind = meeting.online;
    if (kind == null) {
      throw ArgumentError('A meeting held in the room alone has no link.');
    }
    final account = (await loadAccounts())
        .where((a) => a.id == meeting.accountId)
        .firstOrNull;
    final linkAlone = kind == OnlineMeetingKind.googleMeet &&
        account?.provider == MailProvider.outlook;
    final n = preparedMeetings.length + 1;
    final made = kind == OnlineMeetingKind.googleMeet
        ? PreparedMeeting(
            accountId: meeting.accountId,
            kind: kind,
            eventId: linkAlone ? null : 'sample-shell-$n',
            joinUrl: 'https://meet.google.com/abc-defg-hij',
            inviteText: linkAlone
                ? 'Join with Google Meet: https://meet.google.com/abc-defg-hij'
                : 'Join with Google Meet\nhttps://meet.google.com/abc-defg-hij',
          )
        : PreparedMeeting(
            accountId: meeting.accountId,
            kind: kind,
            eventId: 'sample-shell-$n',
            joinUrl: 'https://teams.microsoft.com/l/meetup-join/sample',
            inviteText: 'Microsoft Teams meeting\n'
                'Join the meeting now\n'
                'Meeting ID: 244 810 212 347\n'
                'Passcode: 7aP9Rv',
            bodyHtml: '<html><body>Microsoft Teams meeting</body></html>',
          );
    preparedMeetings.add(made);
    return made;
  }

  @override
  Future<bool> discardPreparedMeeting(PreparedMeeting prepared) async {
    discardedMeetings.add(prepared);
    return true;
  }

  /// As the real engine answers: Teams for a Microsoft account, and Google
  /// Meet after it while a Google account is in the app; Meet for a Google
  /// one; nowhere for an app password. By the accounts as loaded, so a
  /// test's fake with accounts of its own is answered for them.
  @override
  Future<List<OnlineMeetingKind>> onlineMeetingsFor(String accountId) async {
    final accounts = await loadAccounts();
    final account = accounts.where((a) => a.id == accountId).firstOrNull;
    final meetMaker = accounts.any((a) =>
        a.provider == MailProvider.gmail && a.authMethod == AuthMethod.oauth);
    return switch (account) {
      null => const [],
      Account(provider: MailProvider.outlook) => [
          OnlineMeetingKind.teams,
          if (meetMaker) OnlineMeetingKind.googleMeet,
        ],
      Account(authMethod: AuthMethod.oauth) => const [OnlineMeetingKind.googleMeet],
      _ => const [],
    };
  }

  @override
  Future<String> rawMessage(String messageId) async {
    await _latency();
    final folderId = messageId.substring(0, messageId.lastIndexOf('#'));
    final message = _messages[folderId]?.firstWhere(
      (m) => m.id == messageId,
      orElse: () => throw StateError('No such message: $messageId'),
    );
    if (message == null) throw StateError('No such message: $messageId');
    final body = await loadMessageBody(messageId);
    // A plain message in the form every client reads: the sample data has
    // no wire form to hand back, so one is written from what it has.
    String address(MailAddress a) =>
        a.name == null ? a.email : '${a.name} <${a.email}>';
    // One character per byte of the UTF-8 it declares, as a server's is.
    return latin1.decode(utf8.encode([
      'From: ${address(message.from)}',
      'To: ${message.to.map(address).join(', ')}',
      'Subject: ${message.subject}',
      'Date: ${message.date.toUtc().toIso8601String()}',
      'Message-ID: <${message.uid}@sample.example.com>',
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=utf-8',
      'Content-Transfer-Encoding: 8bit',
      '',
      body.text,
    ].join('\r\n')));
  }

  @override
  Future<Uint8List> fetchAttachment(
    String messageId,
    String attachmentId,
  ) async {
    await _latency();
    final known = await listAttachments(messageId);
    if (!known.any((a) => a.id == attachmentId)) {
      throw StateError('No attachment $attachmentId on $messageId');
    }
    // Enough bytes to write a file and open it with something; not a real
    // PDF, because the sample engine has never pretended to be a server.
    return Uint8List.fromList(
      utf8.encode('MyEmail sample attachment $messageId/$attachmentId'),
    );
  }

  @override
  Future<void> setRead(String messageId, bool isRead) =>
      _setFlags(messageId, isRead: isRead);

  @override
  Future<void> setFlagged(String messageId, bool isFlagged) =>
      _setFlags(messageId, isFlagged: isFlagged);

  @override
  Future<void> setMessagesRead(List<String> messageIds, bool isRead) =>
      _each(messageIds, (id) => setRead(id, isRead));

  @override
  Future<void> setMessagesFlagged(List<String> messageIds, bool isFlagged) =>
      _each(messageIds, (id) => setFlagged(id, isFlagged));

  /// What is snoozed, by message id where it waits, for tests to look at.
  final Map<String, ({String fromFolderId, DateTime until})> snoozed = {};

  @override
  Future<List<MessageMove>> snooze(
    List<String> messageIds,
    DateTime until,
  ) async {
    final moves = <MessageMove>[];
    for (final accountId in {
      for (final id in messageIds) id.substring(0, id.indexOf(':')),
    }) {
      final mine = [
        for (final id in messageIds)
          if (id.startsWith('$accountId:')) id,
      ];
      final waiting = '$accountId:Snoozed';
      if (!(await loadFolders(accountId)).any((f) => f.id == waiting)) {
        await createFolder(accountId: accountId, name: 'Snoozed');
      }
      final went = await moveMessages(mine, waiting);
      for (final m in went) {
        for (final id in m.movedIds) {
          snoozed[id] = (fromFolderId: m.fromFolderId, until: until);
        }
      }
      moves.addAll(went);
    }
    return moves;
  }

  @override
  Future<int> wakeSnoozed({DateTime? now}) async {
    final at = now ?? DateTime.now();
    var woken = 0;
    for (final MapEntry(key: id, value: s) in [...snoozed.entries]) {
      if (s.until.isAfter(at)) continue;
      snoozed.remove(id);
      final moves = await moveMessages([id], s.fromFolderId);
      await setMessagesRead([for (final m in moves) ...m.movedIds], false);
      woken++;
    }
    return woken;
  }

  @override
  Future<DateTime?> nextSnoozeWake() async => snoozed.isEmpty
      ? null
      : snoozed.values
          .map((s) => s.until)
          .reduce((a, b) => a.isBefore(b) ? a : b);

  /// Everything flagged in the account's folders, as they have been loaded
  /// so far, with the days set here.
  @override
  Future<List<MailMessage>> flaggedMessages(
    String accountId, {
    int limit = 100,
  }) async {
    await _latency();
    return cachedFlagged(accountId, limit: limit);
  }

  /// The days [setFollowUp] set, by message id.
  final Map<String, DateTime?> flagDues = {};

  @override
  Future<List<MailMessage>> cachedFlagged(
    String accountId, {
    int limit = 100,
  }) async {
    final rows = [
      for (final MapEntry(:key, :value) in _messages.entries)
        if (key.startsWith('$accountId:'))
          for (final m in value)
            if (m.isFlagged)
              flagDues.containsKey(m.id)
                  ? m.copyWith(flagDue: flagDues[m.id])
                  : m,
    ]..sort((a, b) => b.date.compareTo(a.date));
    return rows.take(limit).toList();
  }

  /// Every follow-up set, for tests to look at.
  final List<({List<String> ids, DateTime? due, bool complete})> followUps =
      [];

  @override
  Future<void> setFollowUp(
    List<String> messageIds, {
    DateTime? due,
    bool complete = false,
  }) async {
    followUps.add((ids: messageIds, due: due, complete: complete));
    for (final id in messageIds) {
      complete ? flagDues.remove(id) : flagDues[id] = due;
    }
    await setMessagesFlagged(messageIds, !complete);
  }

  /// [change] on each message in turn, through the one-message form so a
  /// test that refuses one message refuses it here too, and failures
  /// reported as [MailEngine.setMessagesRead] reports them.
  Future<void> _each(
    List<String> messageIds,
    Future<void> Function(String messageId) change,
  ) async {
    final failed = <String>[];
    (Object, StackTrace)? first;
    for (final id in messageIds) {
      try {
        await change(id);
      } catch (e, stack) {
        failed.add(id);
        first ??= (e, stack);
      }
    }
    if (first == null) return;
    if (failed.length == messageIds.length) {
      Error.throwWithStackTrace(first.$1, first.$2);
    }
    throw PartialFlagChange(failed: failed, cause: first.$1);
  }

  Future<void> _setFlags(String messageId, {bool? isRead, bool? isFlagged}) async {
    await _latency();
    final folderId = messageId.substring(0, messageId.lastIndexOf('#'));
    final list = _messages[folderId];
    final i = list?.indexWhere((m) => m.id == messageId) ?? -1;
    if (list == null || i < 0) throw StateError('No such message: $messageId');
    final before = list[i];
    final after = before.copyWith(isRead: isRead, isFlagged: isFlagged);
    list[i] = after;
    if (after.isRead != before.isRead) {
      final folder = _require(folderId);
      _replace(folder.copyWith(
        unreadCount: max(0, folder.unreadCount + (after.isRead ? -1 : 1)),
      ));
    }
  }

  @override
  Future<List<Account>> loadAccounts() async {
    await _latency();
    return List.unmodifiable(_accounts);
  }

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    await _latency();
    return List.unmodifiable(_folders[accountId] ?? const []);
  }

  @override
  Future<FolderRename> renameFolder(String folderId, String newName) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canRename) {
      throw FolderOperationNotSupported(folderId, 'rename');
    }
    final segments = folder.path.split('/')..removeLast();
    // As the real engine: a slash in a name is a stand-in in the path.
    final newPath = [...segments, safePathSegment(newName)].join('/');
    return _relocate(folder, newPath: newPath, newParentId: folder.parentId);
  }

  @override
  Future<FolderRename> moveFolder(String folderId, String? newParentId) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canMove) {
      throw FolderOperationNotSupported(folderId, 'move');
    }
    if (newParentId != null && _isDescendant(newParentId, folderId)) {
      throw FolderOperationNotSupported(folderId, 'move into own descendant');
    }
    if (newParentId != null &&
        !_require(newParentId).capabilities.canCreateChild) {
      throw FolderOperationNotSupported(newParentId, 'nest under');
    }
    final parentPath = newParentId == null ? null : _require(newParentId).path;
    final newPath =
        parentPath == null ? folder.name : '$parentPath/${folder.name}';
    return _relocate(folder, newPath: newPath, newParentId: newParentId);
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canDelete) {
      throw FolderOperationNotSupported(folderId, 'delete');
    }
    // Deleting a folder takes its subtree with it.
    final prefix = '${folder.path}/';
    _folders[folder.accountId]!
        .removeWhere((f) => f.id == folderId || f.path.startsWith(prefix));
  }

  @override
  Future<MailFolder> createFolder({
    required String accountId,
    required String name,
    String? parentId,
  }) async {
    await _latency();
    if (parentId != null && !_require(parentId).capabilities.canCreateChild) {
      throw FolderOperationNotSupported(parentId, 'create child in');
    }
    final parentPath = parentId == null ? null : _require(parentId).path;
    final segment = safePathSegment(name);
    final path = parentPath == null ? segment : '$parentPath/$segment';
    _assertNoConflict(accountId, path);
    final folder = MailFolder.at(
      accountId: accountId,
      path: path,
      role: FolderRole.user,
      capabilities: const FolderCapabilities.userFolder(),
      parentId: parentId,
      sortIndex: _folders[accountId]!.length,
    );
    _folders[accountId]!.add(folder);
    return folder;
  }

  @override
  Future<void> markAllRead(String folderId) async {
    await _latency();
    _replace(_require(folderId).copyWith(unreadCount: 0));
  }

  @override
  Future<void> emptyFolder(String folderId) async {
    await _latency();
    final folder = _require(folderId);
    if (!folder.capabilities.canEmpty) {
      throw FolderOperationNotSupported(folderId, 'empty');
    }
    _replace(folder.copyWith(unreadCount: 0, totalCount: 0));
  }

  // ---------------------------------------------------------------------------

  /// Move [folder] to [newPath], carrying every descendant along and rewriting
  /// their paths, ids and parent links. This is what RENAME does on IMAP.
  FolderRename _relocate(
    MailFolder folder, {
    required String newPath,
    required String? newParentId,
  }) {
    final accountId = folder.accountId;
    final oldPath = folder.path;
    final oldId = folder.id;
    final newId = MailFolder.idFor(accountId, newPath);

    if (newPath == oldPath) {
      return FolderRename(folder: folder, oldId: oldId, newId: newId);
    }
    _assertNoConflict(accountId, newPath, excludingId: oldId);

    final mapping = FolderRename(folder: folder, oldId: oldId, newId: newId);
    final childPrefix = '$oldPath/';
    late MailFolder moved;

    _folders[accountId] = [
      for (final f in _folders[accountId]!)
        if (f.id == oldId)
          moved = f.withPath(newPath, parentId: newParentId)
        else if (f.path.startsWith(childPrefix))
          f.withPath(
            newPath + f.path.substring(oldPath.length),
            parentId: f.parentId == null ? null : mapping.remap(f.parentId!),
          )
        else
          f,
    ];

    return FolderRename(folder: moved, oldId: oldId, newId: newId);
  }

  /// Gmail label names are case-insensitive, so "travel" and "Travel" would
  /// collide on the server. Match the stricter rule locally.
  void _assertNoConflict(String accountId, String path, {String? excludingId}) {
    final wanted = path.toLowerCase();
    for (final f in _folders[accountId] ?? const <MailFolder>[]) {
      if (f.id != excludingId && f.path.toLowerCase() == wanted) {
        throw FolderNameConflict(accountId, path);
      }
    }
  }

  MailFolder _require(String folderId) {
    for (final list in _folders.values) {
      for (final f in list) {
        if (f.id == folderId) return f;
      }
    }
    throw StateError('No such folder: $folderId');
  }

  MailFolder _replace(MailFolder updated) {
    final list = _folders[updated.accountId]!;
    final i = list.indexWhere((f) => f.id == updated.id);
    list[i] = updated;
    return updated;
  }

  bool _isDescendant(String candidateId, String ancestorId) {
    String? cursor = candidateId;
    while (cursor != null) {
      if (cursor == ancestorId) return true;
      cursor = _require(cursor).parentId;
    }
    return false;
  }

  /// A small delay so the UI meets the same async edges it will hit against a
  /// real server, rather than resolving synchronously and hiding loading state.
  Future<void> _latency() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  static List<_Spec> _specsFor(String accountId) => switch (accountId) {
        'acct-personal' => _personalSpecs,
        'acct-side' => _projectsSpecs,
        _ => _freshAccountSpecs,
      };

  static List<MailFolder> _buildFolders(String accountId, List<_Spec> specs) {
    return [
      for (final (i, s) in specs.indexed)
        MailFolder.at(
          accountId: accountId,
          path: s.path,
          role: s.role,
          capabilities: FolderCapabilities.forGmail(s.role),
          parentId:
              s.parent == null ? null : MailFolder.idFor(accountId, s.parent!),
          unreadCount: s.unread,
          totalCount: s.total,
          sortIndex: i,
        ),
    ];
  }

  static const _personalSpecs = <_Spec>[
    _Spec('INBOX', FolderRole.inbox, unread: 14, total: 2310),
    _Spec('[Gmail]/Drafts', FolderRole.drafts, unread: 0, total: 3),
    _Spec('[Gmail]/Sent Mail', FolderRole.sent, unread: 0, total: 1876),
    _Spec('[Gmail]/Trash', FolderRole.deleted, unread: 0, total: 41),
    _Spec('[Gmail]/Spam', FolderRole.junk, unread: 0, total: 128),
    _Spec('[Gmail]/All Mail', FolderRole.archive, unread: 0, total: 9422),
    _Spec('Family', FolderRole.user, unread: 2, total: 311),
    _Spec('Family/Photos', FolderRole.user, parent: 'Family', total: 88),
    _Spec('Family/School', FolderRole.user, parent: 'Family', unread: 1, total: 46),
    _Spec('Finance', FolderRole.user, unread: 5, total: 640),
    _Spec('Finance/Banking', FolderRole.user, parent: 'Finance', total: 209),
    _Spec('Finance/Receipts', FolderRole.user, parent: 'Finance', unread: 5, total: 402),
    _Spec('Finance/Receipts/2026', FolderRole.user,
        parent: 'Finance/Receipts', unread: 5, total: 96),
    _Spec('Travel', FolderRole.user, total: 74),
    _Spec('Newsletters', FolderRole.user, unread: 231, total: 4180),
  ];

  /// What a just-added Gmail account looks like before anything arrives.
  static const _freshAccountSpecs = <_Spec>[
    _Spec('INBOX', FolderRole.inbox),
    _Spec('[Gmail]/Drafts', FolderRole.drafts),
    _Spec('[Gmail]/Sent Mail', FolderRole.sent),
    _Spec('[Gmail]/Trash', FolderRole.deleted),
    _Spec('[Gmail]/Spam', FolderRole.junk),
    _Spec('[Gmail]/All Mail', FolderRole.archive),
  ];

  static const _projectsSpecs = <_Spec>[
    _Spec('INBOX', FolderRole.inbox, unread: 3, total: 412),
    _Spec('[Gmail]/Drafts', FolderRole.drafts, unread: 0, total: 1),
    _Spec('[Gmail]/Sent Mail', FolderRole.sent, unread: 0, total: 233),
    _Spec('[Gmail]/Trash', FolderRole.deleted, unread: 0, total: 8),
    _Spec('[Gmail]/Spam', FolderRole.junk, unread: 0, total: 19),
    _Spec('[Gmail]/All Mail', FolderRole.archive, unread: 0, total: 1104),
    _Spec('Clients', FolderRole.user, unread: 1, total: 180),
    _Spec('Clients/Acme', FolderRole.user, parent: 'Clients', unread: 1, total: 92),
    _Spec('Clients/Globex', FolderRole.user, parent: 'Clients', total: 88),
    _Spec('Invoices', FolderRole.user, total: 57),
  ];
}

class _Spec {
  const _Spec(
    this.path,
    this.role, {
    this.parent,
    this.unread = 0,
    this.total = 0,
  });

  final String path;
  final FolderRole role;
  final String? parent;
  final int unread;
  final int total;
}
