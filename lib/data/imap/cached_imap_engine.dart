import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:collection/collection.dart';
import 'package:enough_mail/enough_mail.dart' as em;

import '../../domain/account.dart';
import '../../domain/account_colours.dart';
import '../../domain/folder_role.dart';
import '../../domain/mail_credentials.dart';
import '../../domain/mail_folder.dart';
import '../../domain/address_suggestions.dart';
import '../../domain/calendar_invite.dart';
import '../../domain/calendar_meeting.dart';
import '../../domain/mail_attachment.dart';
import '../../domain/mail_message.dart';
import '../../domain/sender_blocks.dart';
import '../../domain/meeting.dart';
import '../../domain/message_move.dart';
import '../../domain/draft.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../account_store.dart';
import '../auth/google_oauth.dart';
import '../auth/google_oauth_config.dart';
import '../auth/microsoft_oauth.dart';
import '../auth/oauth_config.dart';
import '../auth/oauth_token.dart';
import '../auth/oauth_token_repository.dart';
import '../cache/cache_store.dart';
import '../cache/folder_sync.dart';
import '../calendar/account_calendar.dart';
import '../contacts/account_people.dart';
import '../compose/graph_sender.dart';
import '../compose/smtp_sender.dart';
import '../compose/thread_index.dart';
import '../compose/reply_draft.dart' show escapeHtml;
import '../auth/token_identity.dart';
import '../credential_store.dart';
import '../folder_list_store.dart';
import '../graph/graph_id_map.dart';
import '../graph/graph_mail_api.dart';
import '../graph/graph_settings_api.dart';
import '../graph/graph_transport.dart';
import '../mailbox_settings/gmail_settings_api.dart';
import '../mailbox_settings/server_settings.dart';
import '../mail_engine.dart';
import 'enough_mail_transport.dart';
import 'imap_mapping.dart';
import 'imap_transport.dart';

/// The engine that ships: an [ImapTransport] per account, a [FolderSync] per
/// account keeping the [CacheStore] current, and reads served from the cache.
///
/// If the server cannot be reached, the folder list, message lists and
/// bodies still come from whatever was cached, so the app opens and is
/// readable offline.
class CachedImapEngine implements MailEngine {
  CachedImapEngine({
    required this.accountStore,
    required this.credentialStore,
    required this.cache,
    FolderListStore? folderLists,
    OAuthTokenRepository? oauthTokens,
    this.graphIdMap,
    ImapTransport Function(Account account, MailCredentials credentials)?
        transportFactory,
    this.senderFactory,
    this.graphSenderFactory,
    this.onMessagesHandled,
    this.senderBlocks,
  })  : folderLists = folderLists ?? MemoryFolderListStore(),
        _injectedOAuthTokens = oauthTokens,
        _injectedTransportFactory = transportFactory;

  final AccountStore accountStore;
  final CredentialStore credentialStore;
  final CacheStore cache;
  final FolderListStore folderLists;

  /// The blocked senders as they stand, read as each Inbox syncs: new mail
  /// from one of them goes to Junk as it arrives. Null where nothing is
  /// blocked, as in most tests.
  final SenderBlocks Function()? senderBlocks;
  /// Supplied by tests, which hand back an in-memory server. Null in the app,
  /// where [_buildTransport] chooses by provider.
  final ImapTransport Function(Account account, MailCredentials credentials)?
      _injectedTransportFactory;

  ImapTransport _transportFactory(
    Account account,
    MailCredentials credentials,
  ) =>
      _injectedTransportFactory?.call(account, credentials) ??
      _buildTransport(account, credentials);

  /// How to build the SMTP sender. Public and named, so a test can supply one
  /// that sends nothing: it was private, which made the seam unreachable from
  /// outside this library and left the send path opening a real socket in any
  /// test that touched it.
  final SmtpSender Function(Account account, MailCredentials credentials)?
      senderFactory;

  /// The same seam for the Graph route, so a test can prove a Microsoft
  /// account sends that way without a network.
  final GraphSender Function(Account account, MailCredentials credentials)?
      graphSenderFactory;

  final OAuthTokenRepository? _injectedOAuthTokens;

  /// Told when messages are read, moved or deleted through this engine, so
  /// the app can take their new-mail notifications down. A notification
  /// left up for mail already dealt with has buttons that no longer work:
  /// Delete says it failed, and a tap opens a message that has gone.
  ///
  /// Given a test rather than a list, because marking a folder read or
  /// emptying it names no messages.
  final void Function(bool Function(String messageId) handled)?
      onMessagesHandled;

  void _handled(bool Function(String messageId) which) {
    try {
      onMessagesHandled?.call(which);
    } catch (e) {
      debugPrint('[myemail] could not take notifications down: $e');
    }
  }

  static bool Function(String messageId) _inFolder(String folderId) =>
      (messageId) => messageId.startsWith('$folderId#') &&
          !messageId.substring(folderId.length + 1).contains('#');

  static bool Function(String messageId) _uidsIn(
    String folderId,
    Iterable<int> uids,
  ) {
    final ids = {for (final uid in uids) MailMessage.idFor(folderId, uid)};
    return ids.contains;
  }

  /// Where Graph message numbering is remembered. Null on a build with no
  /// database behind it — the browser preview, and the tests that do not
  /// exercise a Microsoft account — in which case an in-memory one is used
  /// and the numbering lasts as long as the process.
  final GraphIdMap? graphIdMap;

  /// Late so the default can see [credentialStore], which an initializer list
  /// cannot.
  late final OAuthTokenRepository oauthTokens = _injectedOAuthTokens ??
      OAuthTokenRepository(
        credentialStore: credentialStore,
        oauthClient: (accountId) => switch (_providerFor(accountId)) {
          MailProvider.gmail => GoogleOAuth(
              clientId: googleClientId,
              clientSecret: googleClientSecret,
            ),
          MailProvider.outlook => MicrosoftOAuth(clientId: microsoftClientId),
        },
      );

  final Map<String, ImapTransport> _transports = {};

  /// Connections being made, for [_transport] to hand to a second caller.
  final Map<String, Future<ImapTransport>> _opening = {};
  final Map<String, FolderSync> _syncs = {};

  late final GraphIdMap _graphIds = graphIdMap ?? MemoryGraphIdMap();

  /// Which wire to use for an account.
  ///
  /// Microsoft accounts go over Graph. IMAP would be the smaller change, and
  /// it is not an option: Microsoft counts IMAP as legacy authentication,
  /// switches it off by default on new tenants, and blocks it outright
  /// wherever security defaults are on — which is every new tenant. A work
  /// mailbox often cannot be reached over IMAP at all, and no amount of
  /// client-side care changes that.
  ///
  /// Gmail stays on IMAP, where an app password works and IDLE gives real
  /// push that Graph has no equivalent of on a device with no public address.
  ImapTransport _buildTransport(Account account, MailCredentials credentials) {
    if (account.provider == MailProvider.outlook &&
        credentials is OAuthCredentials) {
      return GraphTransport(
        accountId: account.id,
        idMap: _graphIds,
        api: GraphMailApi(
          accessToken: ({bool force = false}) =>
              _tokenFor(account, force: force),
          mailbox: account.isShared ? account.emailAddress : null,
        ),
      );
    }
    return EnoughMailTransport(
      host: imapHostFor(account.provider),
      user: account.emailAddress,
      credentials: credentials,
    );
  }

  static String imapHostFor(MailProvider provider) => switch (provider) {
        MailProvider.gmail => 'imap.gmail.com',
        MailProvider.outlook => 'outlook.office365.com',
      };

  /// An id no existing account holds.
  ///
  /// The clock alone is not enough. Two accounts added in the same
  /// millisecond get the same id, and everything downstream is keyed on it:
  /// the secret in the Keystore, the cached folders and messages, the
  /// notification watermarks. Adding a second mailbox immediately after the
  /// first would have silently shared all of it with the first.
  static String _newAccountId(Set<String> taken) {
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36);
    var id = 'acct-$stamp';
    var suffix = 1;
    while (taken.contains(id)) {
      id = 'acct-$stamp-$suffix';
      suffix++;
    }
    return id;
  }

  // --- accounts --------------------------------------------------------------

  @override
  Future<List<Account>> loadAccounts() async => accountStore.read();

  @override
  Future<Account> addAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required String secret,
  }) =>
      _add(
        displayName: displayName,
        emailAddress: emailAddress,
        provider: provider,
        authMethod: AuthMethod.appPassword,
        credentials: PasswordCredentials(secret),
        storedSecret: secret,
      );

  @override
  /// Finish an OAuth sign-in by turning its token into an account.
  ///
  /// [emailAddress] is what the person typed, and nothing on the way to
  /// Graph checks it: every request goes to /me, which is whoever signed in.
  /// (Over IMAP the XOAUTH2 handshake sent the address with the token and
  /// the server refused a mismatch; that is gone.) So the token is read
  /// instead: see [TokenIdentity]. Without it, picking the wrong account on
  /// the sign-in page made an account that showed one mailbox under
  /// another's address.
  Future<Account> addOAuthAccount({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required OAuthToken token,
    String? signedInAs,
  }) async {
    final typed = emailAddress.trim();
    final signedIn = TokenIdentity.of(token.accessToken);
    // Google names the account in its ID token, which the caller passes
    // on; a Microsoft work account names itself inside the access token.
    final address = signedInAs ?? signedIn?.address;
    if (address != null && address.toLowerCase() != typed.toLowerCase()) {
      throw AuthenticationFailed(
        'That sign-in is for $address, not $typed. Add the account as '
        '$address, or sign in as $typed.',
      );
    }
    if (signedIn != null) {
      for (final a in accountStore.read()) {
        if (a.authMethod != AuthMethod.oauth) continue;
        final theirs = OAuthToken.fromStoredJson(
          await credentialStore.readSecret(a.id),
        );
        if (theirs == null) continue;
        if (TokenIdentity.of(theirs.accessToken)?.user == signedIn.user) {
          throw AuthenticationFailed(
            'That mailbox is already set up, as ${a.emailAddress}.',
          );
        }
      }
    }
    return _add(
        displayName: displayName,
        emailAddress: emailAddress,
        provider: provider,
        authMethod: AuthMethod.oauth,
        // The probe runs before anything is stored, so the token cannot come
        // from the repository yet; it is handed over directly and only
        // written once the server has accepted it.
        credentials:
            OAuthCredentials(({bool force = false}) async => token.accessToken),
        storedSecret: token.toStoredJson(),
      );
  }

  @override
  Future<Account> addSharedMailbox({
    required String viaAccountId,
    required String emailAddress,
    required String displayName,
  }) async {
    final email = emailAddress.trim();
    final existing = accountStore.read();
    final via = existing.where((a) => a.id == viaAccountId).firstOrNull;
    if (via == null ||
        via.provider != MailProvider.outlook ||
        via.authMethod != AuthMethod.oauth ||
        via.isShared) {
      throw const AuthenticationFailed(
        'A shared mailbox is reached through a Microsoft account it is '
        'shared with.',
      );
    }
    if (existing.any((a) => a.emailAddress.toLowerCase() == email.toLowerCase())) {
      throw AuthenticationFailed('$email is already set up.');
    }
    final name = displayName.trim();
    final account = Account(
      id: _newAccountId(existing.map((a) => a.id).toSet()),
      displayName: name.isEmpty ? email.split('@').first : name,
      emailAddress: email,
      provider: MailProvider.outlook,
      authMethod: AuthMethod.oauth,
      colorValue: newAccountColours[existing.length % newAccountColours.length],
      sharedVia: via.id,
    );
    // Nothing to store first: the token is the other account's, asked for
    // with the shared-mailbox permissions by name.
    final transport = _transportFactory(account, await _credentialsFor(account));
    final List<RemoteFolder> folders;
    try {
      folders = await transport.listFolders();
    } on GraphUnavailable {
      await transport.close();
      rethrow;
    } on AuthenticationFailed {
      await transport.close();
      throw _notShared(email, via);
    } on ConnectionFailed catch (e) {
      await transport.close();
      // Graph's own refusal: no such mailbox, or not this account's to open.
      if (e.message.startsWith('Microsoft refused the request')) {
        throw _notShared(email, via);
      }
      rethrow;
    } catch (_) {
      await transport.close();
      rethrow;
    }
    await folderLists.write(account.id, folders);
    await accountStore.write([...existing, account]);
    // Kept: it asks for its token per request, as one built later would.
    _transports[account.id] = transport;
    return account;
  }

  static AuthenticationFailed _notShared(String email, Account via) =>
      AuthenticationFailed(
        '${via.emailAddress} could not open $email. Check the address, and '
        'that whoever runs that mailbox has given ${via.emailAddress} Full '
        'Access to it.',
      );

  Future<Account> _add({
    required String displayName,
    required String emailAddress,
    required MailProvider provider,
    required AuthMethod authMethod,
    required MailCredentials credentials,
    required String storedSecret,
  }) async {
    final email = emailAddress.trim();
    final existing = accountStore.read();
    if (existing.any((a) => a.emailAddress.toLowerCase() == email.toLowerCase())) {
      throw AuthenticationFailed('$email is already set up.');
    }
    final account = Account(
      id: _newAccountId(existing.map((a) => a.id).toSet()),
      displayName: displayName,
      emailAddress: email,
      provider: provider,
      authMethod: authMethod,
      colorValue: newAccountColours[existing.length % newAccountColours.length],
    );
    // The secret goes in before the probe, not after.
    //
    // A Microsoft account's transport does not take its token as a parameter:
    // it reads the stored one, because the token it needs is fetched per
    // request and refreshed as it goes. Probing before the write therefore
    // found nothing and reported a sign-in that had just succeeded as "this
    // account is not signed in" — the check failing, not the sign-in.
    //
    // Anything written here is removed again if the probe fails, so a refused
    // credential leaves nothing behind.
    await credentialStore.writeSecret(account.id, storedSecret);

    final transport = _transportFactory(account, credentials);
    final List<RemoteFolder> folders;
    try {
      folders = await transport.listFolders();
    } catch (_) {
      await credentialStore.deleteSecret(account.id);
      await transport.close();
      rethrow;
    }
    // Keep what the probe already fetched: the tree can then render, and a
    // search can pick its targets, without a second round trip.
    await folderLists.write(account.id, folders);
    await accountStore.write([...existing, account]);
    // Only now, with the secret stored, is the cached transport safe to keep:
    // the OAuth one built above closes over a token that will expire, whereas
    // one built from _credentialsFor can refresh itself.
    if (authMethod == AuthMethod.oauth) {
      await transport.close();
    } else {
      _transports[account.id] = transport;
    }
    return account;
  }

  @override
  Future<Account> updateAccount({
    required String accountId,
    String? displayName,
    int? colorValue,
    String? senderName,
  }) async {
    final accounts = accountStore.read();
    final existing = accounts.where((a) => a.id == accountId).firstOrNull;
    if (existing == null) throw StateError('Unknown account $accountId');

    final trimmed = displayName?.trim();
    final updated = existing.copyWith(
      // An empty name would leave a blank heading in the tree with no way to
      // tell which mailbox it is, so it falls back rather than being stored.
      displayName: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      colorValue: colorValue,
      // Empty is a choice here rather than a mistake: it means "send under
      // the name above", which is what the field says and what every
      // account did before it existed.
      senderName: senderName?.trim(),
    );
    await accountStore.write([
      for (final a in accounts) a.id == accountId ? updated : a,
    ]);
    // No transport is rebuilt: nothing here changes how the account connects.
    return updated;
  }

  @override
  Future<void> reorderAccounts(List<String> accountIds) =>
      accountStore.write(accountsInOrder(accountStore.read(), accountIds));

  @override
  Future<void> updateAppPassword({
    required String accountId,
    required String secret,
  }) =>
      _replaceSecret(
        accountId: accountId,
        credentials: PasswordCredentials(secret),
        storedSecret: secret,
      );

  @override
  Future<void> updateOAuthToken({
    required String accountId,
    required OAuthToken token,
    String? signedInAs,
  }) async {
    final account =
        accountStore.read().where((a) => a.id == accountId).firstOrNull;
    // The same person as before, as far as the tokens can tell. Signing in
    // again as someone else was accepted, and the account went on showing
    // the other mailbox under its own name, mixed into its own cache.
    final stored =
        OAuthToken.fromStoredJson(await credentialStore.readSecret(accountId));
    if (stored != null &&
        !TokenIdentity.sameUser(
          TokenIdentity.of(stored.accessToken),
          TokenIdentity.of(token.accessToken),
        )) {
      throw AuthenticationFailed(
        'That sign-in is for a different Microsoft account. Sign in as '
        '${account?.emailAddress ?? 'the account being repaired'}.',
      );
    }
    // Where the sign-in names its address, it has to be this account's.
    if (signedInAs != null &&
        account != null &&
        signedInAs.trim().toLowerCase() !=
            account.emailAddress.trim().toLowerCase()) {
      throw AuthenticationFailed(
        'That sign-in is for $signedInAs, not ${account.emailAddress}. '
        'Sign in as ${account.emailAddress}.',
      );
    }
    await _replaceSecret(
      accountId: accountId,
      // As in addOAuthAccount: the probe runs before anything is stored, so
      // the token cannot come from the repository yet.
      credentials:
          OAuthCredentials(({bool force = false}) async => token.accessToken),
      storedSecret: token.toStoredJson(),
    );
    // An account that signed in with an app password until now signs in
    // with the token from here on. Written after the probe: a refused
    // sign-in leaves the account as it was, password and all.
    if (account != null && account.authMethod != AuthMethod.oauth) {
      await accountStore.write([
        for (final a in accountStore.read())
          a.id == accountId ? a.copyWith(authMethod: AuthMethod.oauth) : a,
      ]);
    }
    // What this account would not allow before, it may have allowed now.
    _people.forget(accountId);
  }

  Future<void> _replaceSecret({
    required String accountId,
    required MailCredentials credentials,
    required String storedSecret,
  }) async {
    final account = accountStore
        .read()
        .where((a) => a.id == accountId)
        .firstOrNull;
    if (account == null) throw StateError('Unknown account $accountId');

    // In place first, then proved. A Microsoft account's transport reads the
    // stored secret rather than taking one, so probing before the write would
    // test the credential being replaced instead of the new one — and report
    // the new sign-in as stale, which is exactly what it was meant to fix.
    final previous = await credentialStore.readSecret(accountId);
    await credentialStore.writeSecret(accountId, storedSecret);
    // And let go of the copy held in memory, which is what the probe would
    // otherwise be handed: the old token, the very one being replaced. Its
    // refresh failed again, the probe failed, and the good new sign-in was
    // rolled back and reported as failed.
    oauthTokens.forget(accountId);

    final probe = _transportFactory(account, credentials);
    try {
      await probe.listFolders();
    } catch (_) {
      // Put back what worked, or at least what was there. Replacing a
      // credential the server refused would swap one broken sign-in for
      // another and lose the last known-good one on the way.
      oauthTokens.forget(accountId);
      if (previous == null) {
        await credentialStore.deleteSecret(accountId);
      } else {
        await credentialStore.writeSecret(accountId, previous);
      }
      rethrow;
    } finally {
      await probe.close();
    }

    // Drop the cached transport and the sync built on it. A password
    // transport closes over the secret it was built with, so keeping it would
    // mean the account carried on failing with the old password until the app
    // was restarted, which looks exactly like the fix not having worked.
    await _transports.remove(accountId)?.close();
    _syncs.remove(accountId);
  }

  /// Whether new mail for [account] is heard as it arrives. Microsoft goes
  /// over Graph, which has no IDLE: waiting on it is a plain sleep.
  static bool hearsNewMail(Account account) =>
      !(account.provider == MailProvider.outlook &&
          account.authMethod == AuthMethod.oauth);

  /// Let go of every account that is no longer in the account list.
  ///
  /// For an engine in another isolate than the app's, which is where an
  /// account is removed: the push worker runs for most of an hour, and went
  /// on syncing a removed account and announcing its mail, able to write its
  /// sign-in back as it refreshed.
  Future<void> releaseRemovedAccounts() async {
    final current = {for (final a in accountStore.read()) a.id};
    for (final id in {..._transports.keys, ..._syncs.keys}) {
      if (current.contains(id)) continue;
      await _transports.remove(id)?.close();
      _syncs.remove(id);
      oauthTokens.forget(id);
    }
  }

  @override
  Future<void> removeAccount(String accountId) async {
    // A shared mailbox goes with the account it is reached through: nothing
    // else here can open it.
    for (final shared in [
      for (final a in accountStore.read())
        if (a.sharedVia == accountId) a,
    ]) {
      await removeAccount(shared.id);
    }
    await _transports.remove(accountId)?.close();
    _syncs.remove(accountId);
    oauthTokens.forget(accountId);
    await credentialStore.deleteSecret(accountId);
    await cache.deleteAccount(accountId);
    // The numbering goes with the cache it keyed. Leaving it would hand the
    // same numbers to a different mailbox if this address were added again.
    await _graphIds.forgetAccount(accountId);
    await folderLists.delete(accountId);
    await accountStore.write([
      for (final a in accountStore.read())
        if (a.id != accountId) a,
    ]);
  }

  /// Wait until any of [folderIds] has something new, or [timeout] passes.
  ///
  /// One IDLE per account, raced. When one ends, the others are called off.
  /// An IDLE holds its account's connection, and every command for that
  /// account queues behind it, so a loser left to run out its own timeout
  /// held the next pass up for as long as twenty-four minutes.
  ///
  /// A watch that fails leaves the race rather than ending it. It used to
  /// end it: an account that could not connect made every wait return at
  /// once, and push mode ran pass after pass with no pause for as long as
  /// the network was out. Only when every watch has failed does the wait
  /// end, and then after [failureBackoff], not straight away.
  ///
  /// Returns true if a server spoke. False means the timeout was reached, or
  /// no folder could be watched at all, and the caller should treat both the
  /// same way: it is simply time to sync again.
  Future<bool> awaitNewMail(
    List<String> folderIds, {
    required Duration timeout,
    Duration failureBackoff = const Duration(minutes: 1),
  }) async {
    if (folderIds.isEmpty) {
      // Nothing to watch, with push still on: after the last account is
      // removed, say. Returning at once had the live loop run pass after
      // pass with nothing to do, for as long as the worker was allowed.
      await Future<void>.delayed(timeout);
      return false;
    }
    final over = Completer<void>();
    final watches = <Future<bool>>[];
    for (final folderId in folderIds) {
      final (accountId, path) = splitFolderId(folderId);
      try {
        final t = await _transport(accountId);
        watches.add(
          t.awaitChanges(path, timeout: timeout, cancel: over.future),
        );
      } catch (_) {
        // This account cannot be watched right now. The others still can, and
        // the next ordinary pass will pick this one up.
      }
    }
    if (watches.isEmpty) {
      await Future<void>.delayed(timeout);
      return false;
    }

    final backoff = timeout < failureBackoff ? timeout : failureBackoff;
    final allFailed = Completer<bool>();
    var failed = 0;
    Future<bool> stayInRaceUnlessAllFail(Future<bool> watch) =>
        watch.catchError((Object e) {
          debugPrint('[myemail] watch failed: $e');
          if (++failed == watches.length && !allFailed.isCompleted) {
            allFailed.complete(Future<bool>.delayed(backoff, () => false));
          }
          // Never completes: this watch no longer has a say.
          return Completer<bool>().future;
        });

    // Any of them waking is reason enough to sync every account: the pass is
    // cheap against the cache and sorting out which one spoke is not.
    debugPrint('[myemail] watching ${watches.length} of ${folderIds.length} inboxes');
    final woke = await Future.any([
      for (final w in watches) stayInRaceUnlessAllFail(w),
      allFailed.future,
    ]);
    if (!over.isCompleted) over.complete();
    debugPrint('[myemail] watch ended, woke=$woke');
    return woke;
  }

  /// Drop every open connection. Not part of [MailEngine]: the app holds one
  /// engine for its whole life and has nothing to close it for. The background
  /// pass does — it runs in an isolate Android tears down afterwards, and a
  /// socket left open there is a wakelock nobody asked for.
  Future<void> close() async {
    final open = _transports.values.toList();
    _transports.clear();
    _syncs.clear();
    for (final t in open) {
      try {
        await t.close();
      } catch (_) {
        // Already gone. Closing is best-effort by definition.
      }
    }
  }

  // --- folders ---------------------------------------------------------------

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    List<RemoteFolder> remote;
    try {
      final t = await _transport(accountId);
      remote = await t.listFolders();
      await folderLists.write(accountId, remote);
      // A full listing from the server: whatever is cached for a folder not
      // in it is for one deleted or renamed elsewhere, and would sit here
      // for good. Never on an empty one, which is more likely a server
      // having a bad moment than an account with no Inbox.
      if (remote.isNotEmpty) {
        await cache.pruneFolders(accountId, {for (final r in remote) r.path});
      }
    } on ConnectionFailed {
      final cached = folderLists.read(accountId);
      if (cached == null) rethrow;
      remote = cached;
    }
    return _foldersFrom(accountId, remote);
  }

  @override
  Future<List<MailFolder>> cachedFolders(String accountId) async {
    final stored = folderLists.read(accountId);
    if (stored == null) return const [];
    return _foldersFrom(accountId, stored);
  }

  List<MailFolder> _foldersFrom(String accountId, List<RemoteFolder> remote) {
    final paths = {for (final r in remote) r.path};
    return [
      for (final (i, r) in remote.indexed)
        folderFromRemote(
          accountId: accountId,
          provider: _providerFor(accountId),
          remote: r,
          allPaths: paths,
          sortIndex: i,
        ),
    ];
  }

  @override
  Future<FolderRename> renameFolder(String folderId, String newName) {
    final (accountId, path) = splitFolderId(folderId);
    final cut = path.lastIndexOf('/');
    // A slash reaches here only from a Microsoft account, whose names may
    // have one; in the path it becomes a stand-in, as the listing does.
    final segment = safePathSegment(newName);
    final newPath = cut < 0 ? segment : '${path.substring(0, cut)}/$segment';
    return _relocate(accountId, path, newPath);
  }

  @override
  Future<FolderRename> moveFolder(String folderId, String? newParentId) {
    final (accountId, path) = splitFolderId(folderId);
    final name = MailFolder.nameFor(path);
    final newPath =
        newParentId == null ? name : '${splitFolderId(newParentId).$2}/$name';
    return _relocate(accountId, path, newPath);
  }

  Future<FolderRename> _relocate(
    String accountId,
    String path,
    String newPath,
  ) async {
    if (newPath == path) {
      final folders = await loadFolders(accountId);
      final same = folders.firstWhere((f) => f.path == path);
      return FolderRename(folder: same, oldId: same.id, newId: same.id);
    }
    final t = await _transport(accountId);
    final before = await t.listFolders();
    // The folder itself is left out: a change of capitals alone would find
    // it, and "receipts" could never become "Receipts".
    if (before.any((r) =>
        r.path != path && r.path.toLowerCase() == newPath.toLowerCase())) {
      throw FolderNameConflict(accountId, newPath);
    }
    await t.renameFolder(path, newPath);
    await cache.renameFolder(accountId, path, newPath);
    final folders = await loadFolders(accountId);
    final moved = folders.firstWhere(
      (f) => f.path == newPath,
      orElse: () => throw StateError('Renamed folder not listed: $newPath'),
    );
    return FolderRename(
      folder: moved,
      oldId: MailFolder.idFor(accountId, path),
      newId: moved.id,
    );
  }

  @override
  Future<void> deleteFolder(String folderId) async {
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    if (!t.deleteTakesSubfolders) {
      // IMAP's DELETE leaves every folder under the one it names, while the
      // dialog says they go too and the app forgets their settings and
      // cache. They came back at the top level, stripped of both. So they
      // go first, deepest first: some servers refuse to delete a folder
      // that still has any.
      final below = [
        for (final f in await t.listFolders())
          if (f.path.startsWith('$path/')) f.path,
      ]..sort((a, b) =>
          '/'.allMatches(b).length.compareTo('/'.allMatches(a).length));
      for (final child in below) {
        await t.deleteFolder(child);
      }
    }
    await t.deleteFolder(path);
    await cache.deleteFolder(accountId, path);
  }

  @override
  Future<MailFolder> createFolder({
    required String accountId,
    required String name,
    String? parentId,
  }) async {
    // See renameFolder for the slash.
    final segment = safePathSegment(name);
    final path =
        parentId == null ? segment : '${splitFolderId(parentId).$2}/$segment';
    final t = await _transport(accountId);
    final before = await t.listFolders();
    if (before.any((r) => r.path.toLowerCase() == path.toLowerCase())) {
      throw FolderNameConflict(accountId, path);
    }
    await t.createFolder(path);
    final folders = await loadFolders(accountId);
    return folders.firstWhere(
      (f) => f.path == path,
      orElse: () => throw StateError('Created folder not listed: $path'),
    );
  }

  @override
  Future<void> markAllRead(String folderId) async {
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    await t.storeFlagOnAll(path, flag: MessageFlag.seen, set: true);
    // The flag sweep on the next sync brings the cache in line: all of it,
    // not only the newest rows a sync otherwise keeps up to date.
    await _sync(accountId, t).sync(
      path,
      reach: await cache.countMessages(accountId, path),
    );
    _handled(_inFolder(folderId));
  }

  @override
  Future<void> emptyFolder(String folderId) async {
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    await t.storeFlagOnAll(path, flag: MessageFlag.deleted, set: true);
    await t.expunge(path);
    await cache.clearFolder(accountId, path);
    _handled(_inFolder(folderId));
  }

  // --- messages --------------------------------------------------------------

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final (accountId, path) = splitFolderId(folderId);
    try {
      final t = await _transport(accountId);
      final sync = _sync(accountId, t);
      // As deep as the list asks for, so that what it shows is up to date.
      final result = await sync.sync(path, reach: offset + limit);
      await _junkBlocked(accountId, t, path, result.arrived);
      await sync.ensureCached(path, offset + limit);
    } on ConnectionFailed catch (e) {
      // Offline: whatever is cached is what there is.
      debugPrint('[myemail] sync $path failed, showing what is cached: $e');
    }
    return cachedMessages(folderId, offset: offset, limit: limit);
  }

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final (accountId, path) = splitFolderId(folderId);
    final rows = await cache.readMessages(
      accountId,
      path,
      offset: offset,
      limit: limit,
    );
    return [
      for (final r in rows) r.toMailMessage(accountId: accountId, folderId: folderId),
    ];
  }

  @override
  Future<MailMessage?> cachedMessage(String messageId) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final row = await cache.readMessage(accountId, path, uid);
    return row?.toMailMessage(accountId: accountId, folderId: folderId);
  }

  @override
  Future<MailBody> loadMessageBody(String messageId) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final cached = await cachedBody(cache, accountId, path, uid);
    if (cached != null) return cached;
    final t = await _transport(accountId);
    return _sync(accountId, t).body(path, uid);
  }

  @override
  Future<List<AddressSuggestion>> recentAddresses() => cache.addressHistory(
        mine: {
          for (final a in accountStore.read())
            a.emailAddress.trim().toLowerCase(),
        },
        now: DateTime.now(),
      );

  /// The accounts' address books online, held for the engine's life: which
  /// accounts have not allowed a search is remembered there, and recent
  /// answers.
  late final AccountPeople _people = AccountPeople(
    accessToken: oauthTokens.accessToken,
    accounts: accountStore.read,
  );

  @override
  Future<List<AddressSuggestion>> searchPeople(String query) =>
      _people.search(query);

  @override
  Future<void> warmPeopleSearch() => _people.warm();

  @override
  Future<PeopleSearchAccess> peopleSearchAccess(String accountId) async {
    final account =
        accountStore.read().where((a) => a.id == accountId).firstOrNull;
    if (account == null) {
      return const PeopleSearchAccess(PeopleSearchState.notPossible);
    }
    return _people.access(account);
  }

  @override
  Future<void> respondToInvite(
    String messageId,
    CalendarInvite invite,
    InviteResponse response, {
    String note = '',
    bool send = true,
    TimeSpan? proposal,
  }) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    // A shared mailbox's calendar is not reached here (that would be
    // Calendars.ReadWrite.Shared): its answer goes by mail, from it.
    final shared = accountStore
            .read()
            .where((a) => a.id == accountId)
            .firstOrNull
            ?.isShared ??
        false;
    // Not by UID for one occurrence of a series: the UID is the series',
    // and the event it finds is the whole series.
    if (!shared &&
        await t.respondToInvite(
          path,
          uid,
          response,
          iCalUid: invite.recurrenceId == null ? invite.uid : null,
          note: note,
          send: send,
          proposal: proposal,
        )) {
      return;
    }
    if (proposal != null) {
      throw const SendFailed(
        'A new time can be proposed only from a Microsoft account.',
      );
    }
    // Over mail, an answer the organiser is not sent is no answer at all.
    if (!send) {
      throw const SendFailed(
        'An answer can be kept from the organiser only on a Microsoft '
        'account.',
      );
    }

    // The server has no calendar of its own to answer on: the reply goes
    // as mail to the organiser, an iCalendar REPLY part beside a line of
    // text, which is how every calendar reads an answer from outside.
    final organizer = invite.organizer;
    if (organizer == null) {
      throw const SendFailed('The invitation names no organiser to reply to.');
    }
    final account = accountStore.read().firstWhere((a) => a.id == accountId);
    final me = MailAddress(email: account.emailAddress, name: account.senderName);
    await sendDraft(Draft(
      accountId: accountId,
      kind: ComposeKind.reply,
      to: [organizer],
      subject: inviteReplySubject(invite, response),
      // The name everyone else sees, as the calendar part has it; the
      // account's own label ("Personal") is for the folder list.
      htmlBody: '<p>${escapeHtml(account.senderName)} has '
          '${response.word.toLowerCase()} this invitation.</p>'
          '${note.trim().isEmpty ? '' : '<p>${escapeHtml(note.trim())}</p>'}',
      calendarReply: iMipReply(invite, attendee: me, response: response),
      originalMessageId: messageId,
    ));
  }

  /// The accounts' calendars, held for the engine's life: where a calendar
  /// said it holds meetings online is remembered there.
  late final AccountCalendar _calendars = AccountCalendar(
    accessToken: oauthTokens.accessToken,
    accounts: accountStore.read,
  );

  @override
  Future<List<OnlineMeetingKind>> onlineMeetingsFor(String accountId) async {
    final account =
        accountStore.read().where((a) => a.id == accountId).firstOrNull;
    if (account == null) return const [];
    return _calendars.onlineMeetingsFor(account);
  }

  @override
  Future<CreatedMeeting> createMeeting(MeetingDraft meeting) async {
    final account = accountStore.read().firstWhere(
          (a) => a.id == meeting.accountId,
          orElse: () => throw StateError('Unknown account ${meeting.accountId}'),
        );
    // The account's calendar chooses the wire and asks for the token the
    // way that wire wants it; the engine's part is naming the account.
    return _calendars.createMeeting(account, meeting);
  }

  @override
  Future<PreparedMeeting?> prepareOnlineMeeting(MeetingDraft meeting) async {
    final account = accountStore.read().firstWhere(
          (a) => a.id == meeting.accountId,
          orElse: () => throw StateError('Unknown account ${meeting.accountId}'),
        );
    return _calendars.prepareOnlineMeeting(account, meeting);
  }

  @override
  Future<bool> discardPreparedMeeting(PreparedMeeting prepared) async {
    final account = accountStore
        .read()
        .where((a) => a.id == prepared.accountId)
        .firstOrNull;
    // An account removed meanwhile took its calendar's access with it:
    // there is no trying again.
    if (account == null) return true;
    return _calendars.discardPreparedMeeting(account, prepared);
  }

  /// Not a shared mailbox's invitation, which is answered by mail.
  @override
  bool canProposeNewTime(String accountId) {
    final account =
        accountStore.read().where((a) => a.id == accountId).firstOrNull;
    return account != null &&
        account.provider == MailProvider.outlook &&
        !account.isShared;
  }

  @override
  Future<List<MailTip>> mailTips(String accountId, List<String> emails) async {
    if (emails.isEmpty) return const [];
    try {
      final t = await _transport(accountId);
      if (t is! GraphTransport) return const [];
      return await t.mailTips(emails);
    } catch (e) {
      debugPrint('[myemail] mail tips not read: $e');
      return const [];
    }
  }

  /// Each account's server settings, made when first asked for.
  final Map<String, ServerSettings> _serverSettings = {};

  @override
  ServerSettings? serverSettings(String accountId) {
    final account =
        accountStore.read().where((a) => a.id == accountId).firstOrNull;
    if (account == null ||
        account.authMethod != AuthMethod.oauth ||
        account.isShared) {
      return null;
    }
    // A token asked for the settings by name: a mailbox approved for mail
    // alone goes on reading its mail, and this says it needs consent.
    Future<String> token(List<String> scopes, bool force) =>
        oauthTokens.accessToken(accountId, force: force, scopes: scopes);
    Future<GraphTransport> graph() async {
      final t = await _transport(accountId);
      if (t is! GraphTransport) {
        throw const ConnectionFailed(
          'This account does not reach Microsoft Graph.',
        );
      }
      return t;
    }

    return _serverSettings[accountId] ??= switch (account.provider) {
      MailProvider.outlook => GraphServerSettings(
          api: GraphSettingsApi(
            accessToken: ({bool force = false}) =>
                token(MicrosoftOAuth.mailboxSettingsScopes, force),
          ),
          folderIdOf: (path) async => (await graph()).folderIdOf(path),
          pathsById: () async => (await graph()).folderPathsById(),
        ),
      MailProvider.gmail => GmailServerSettings(
          api: GmailSettingsApi(
            accessToken: ({bool force = false}) =>
                token(GoogleOAuth.gmailSettingsScopes, force),
          ),
          isArchive: (path) async =>
              _isAllMail(accountId, await _transport(accountId), path),
        ),
    };
  }

  @override
  Future<List<TimeSpan>> busyTimes(
    String accountId,
    DateTime start,
    DateTime end,
  ) =>
      _calendars.busyTimes(_accountFor(accountId), start, end);

  @override
  Future<Map<String, List<TimeSpan>?>> schedules(
    String accountId,
    List<String> emails,
    DateTime start,
    DateTime end,
  ) =>
      _calendars.schedules(_accountFor(accountId), emails, start, end);

  @override
  Future<CalendarMeeting?> meetingOnCalendar(
    String messageId,
    CalendarInvite invite,
  ) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final account = _accountFor(accountId);
    // Exchange links its meeting mail to the event, and for one meeting of
    // a series to that meeting: its own answer, asked first. Nothing else
    // links one, and a Gmail account is not connected to for nothing.
    String? linked;
    if (account.provider == MailProvider.outlook) {
      try {
        linked = await (await _transport(accountId)).linkedEventId(path, uid);
      } catch (_) {
        linked = null;
      }
    }
    return _calendars.meetingFor(account, invite, linkedEventId: linked);
  }

  @override
  Future<void> removeFromCalendar(CalendarMeeting meeting) =>
      _calendars.removeMeeting(_accountFor(meeting.accountId), meeting);

  @override
  Future<void> moveMeeting(CalendarMeeting meeting, CalendarInvite proposal) =>
      _calendars.moveMeeting(
        _accountFor(meeting.accountId),
        meeting,
        proposal,
      );

  /// The account by id, which the caller had from this engine.
  Account _accountFor(String accountId) => accountStore.read().firstWhere(
        (a) => a.id == accountId,
        orElse: () => throw StateError('Unknown account $accountId'),
      );

  @override
  Future<String> rawMessage(String messageId) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    return t.fetchRaw(path, uid);
  }

  @override
  Future<List<MailAttachment>> listAttachments(String messageId) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    return t.listAttachments(path, uid);
  }

  @override
  Future<OpenedHeaders> openedHeaders(String messageId) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    return OpenedHeaders.fromHeaders(
      await t.headerValues(path, uid, OpenedHeaders.headerNames),
    );
  }

  @override
  bool answersReadReceipts(String accountId) =>
      accountStore.read().where((a) => a.id == accountId).firstOrNull?.provider ==
      MailProvider.gmail;

  @override
  Future<void> sendReadReceipt(String messageId) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final account = _accountFor(accountId);
    final t = await _transport(accountId);
    final asked = await t.headerValues(
      path,
      uid,
      const ['Disposition-Notification-To', 'Message-ID', 'Subject', 'Date', 'From', 'To'],
    );
    final to = asked['disposition-notification-to'];
    if (to == null || !to.contains('@')) {
      throw const SendFailed('The message no longer asks for a read receipt.');
    }
    final original = em.MimeMessage();
    for (final MapEntry(:key, :value) in asked.entries) {
      original.addHeader(key, value);
    }
    final receipt = em.MessageBuilder.buildReadReceipt(
      original,
      em.MailAddress(account.senderName, account.emailAddress),
      reportingUa: 'MyEmail',
      subject: 'Read: ${original.decodeSubject() ?? ''}'.trim(),
      textTemplate: readReceiptText,
    );
    await _send(account, await _credentialsFor(account), receipt);
    await _markReceiptAnswered(t, path, uid);
  }

  @override
  Future<void> declineReadReceipt(String messageId) async {
    try {
      final (folderId, uid) = splitMessageId(messageId);
      final (accountId, path) = splitFolderId(folderId);
      await _markReceiptAnswered(await _transport(accountId), path, uid);
    } catch (e) {
      debugPrint('[myemail] receipt request not marked answered: $e');
    }
  }

  Future<void> _markReceiptAnswered(ImapTransport t, String path, int uid) async {
    try {
      await t.markReceiptAnswered(path, uid);
    } catch (e) {
      debugPrint('[myemail] receipt request not marked answered: $e');
    }
  }

  @override
  Future<Uint8List> fetchAttachment(
    String messageId,
    String attachmentId,
  ) async {
    final (folderId, uid) = splitMessageId(messageId);
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    return t.fetchAttachment(path, uid, attachmentId);
  }

  @override
  Future<void> setRead(String messageId, bool isRead) =>
      setMessagesRead([messageId], isRead);

  @override
  Future<void> setFlagged(String messageId, bool isFlagged) =>
      setMessagesFlagged([messageId], isFlagged);

  @override
  Future<void> setMessagesRead(List<String> messageIds, bool isRead) =>
      _setFlagOn(messageIds, MessageFlag.seen, isRead);

  @override
  Future<void> setMessagesFlagged(List<String> messageIds, bool isFlagged) =>
      _setFlagOn(messageIds, MessageFlag.flagged, isFlagged);

  /// The flag with its day on a Microsoft account; the flag alone over
  /// IMAP, which keeps no day, and on which complete is the flag taken off.
  @override
  Future<void> setFollowUp(
    List<String> messageIds, {
    DateTime? due,
    bool complete = false,
  }) =>
      _setFlagOn(
        messageIds,
        MessageFlag.flagged,
        !complete,
        store: (t, path, uids) => t is GraphTransport
            ? t.storeFollowUp(path, uids: uids, due: due, complete: complete)
            : t.storeFlag(path,
                uids: uids, flag: MessageFlag.flagged, set: !complete),
      );

  @override
  Future<List<MessageMove>> moveMessages(
    List<String> messageIds,
    String toFolderId,
  ) async {
    if (messageIds.isEmpty) return const [];
    final (toAccount, toPath) = splitFolderId(toFolderId);
    final moves = <MessageMove>[];
    final went = <String>[];
    for (final group in _groupByFolder(messageIds).entries) {
      final (accountId, fromPath) = splitFolderId(group.key);
      if (accountId != toAccount) {
        await _moveAcross(group.key, group.value, toFolderId,
            done: moves, went: went);
        continue;
      }
      if (fromPath == toPath) continue;
      final (:landed, :moved, :stopped) = await _moveGroup(
        accountId,
        fromPath,
        group.value,
        toPath,
        done: moves,
        went: went,
      );
      moves.add(MessageMove(
        fromFolderId: group.key,
        toFolderId: toFolderId,
        movedIds: [
          for (final uid in landed ?? const <int>[])
            MailMessage.idFor(toFolderId, uid),
        ],
        messageIds: moved.headers,
      ));
      went.addAll([for (final uid in moved.uids) MailMessage.idFor(group.key, uid)]);
      if (stopped != null) {
        throw PartialMove(done: moves, moved: went, cause: stopped);
      }
    }
    return moves;
  }

  /// One folder's part of a move into another account, which no server
  /// does: each message is copied across as it is, read or not, flagged or
  /// not, and dated when it arrived, and then the ones that made it are
  /// deleted here the way any delete is, into this account's Trash.
  ///
  /// Copies first, so a failure part way leaves a message in both places
  /// and never in neither. The ones copied before a failure are still
  /// deleted here and reported, as a [PartialMove], with the failure; so is
  /// a delete here that would not go, since the copies are there by then.
  Future<void> _moveAcross(
    String fromFolderId,
    List<int> uids,
    String toFolderId, {
    required List<MessageMove> done,
    required List<String> went,
  }) async {
    final (fromAccount, fromPath) = splitFolderId(fromFolderId);
    final (toAccount, toPath) = splitFolderId(toFolderId);
    final from = await _transport(fromAccount);
    final to = await _transport(toAccount);

    // Each original's copy there, by the original's uid; null where the
    // server did not say what it called it. And each one's Message-ID, read
    // now, because the delete is about to make the cache forget it.
    final copies = <int, String?>{};
    final headers = <int, String>{};
    Object? stopped;
    for (final uid in uids) {
      try {
        final cached = await cache.readMessage(fromAccount, fromPath, uid);
        final copy = await to.fileMessage(
          toPath,
          await from.fetchRaw(fromPath, uid),
          seen: cached?.isRead ?? true,
          flagged: cached?.isFlagged ?? false,
          arrived: cached?.arrived ?? cached?.date,
        );
        copies[uid] = copy == null ? null : MailMessage.idFor(toFolderId, copy);
        if (cached?.messageId case final id? when id.isNotEmpty) {
          headers[uid] = id;
        }
      } catch (e) {
        stopped = e;
        break;
      }
    }
    if (copies.isEmpty) {
      if (done.isEmpty) throw stopped!;
      throw PartialMove(done: done, moved: went, cause: stopped!);
    }
    try {
      await _syncIfCached(toAccount, to, toPath);
    } catch (_) {
      // The destination catches up on its next sync.
    }

    final originals = [
      for (final uid in copies.keys) MailMessage.idFor(fromFolderId, uid),
    ];
    MessageMove? binned;
    List<String> removed;
    try {
      binned = (await deleteMessages(originals)).firstOrNull;
      removed = originals;
    } catch (e) {
      binned = e is PartialMove ? e.done.firstOrNull : null;
      removed = e is PartialMove ? e.moved : const [];
      final kept = originals.length - removed.length;
      stopped = ConnectionFailed(
        '${kept == 1 ? 'One message was' : '$kept messages were'} copied to '
        'the other account but could not be taken out of this one, so '
        '${kept == 1 ? 'it is' : 'they are'} in both. '
        '(${e is ReadableError ? e.message : e})',
      );
    }
    if (removed.isNotEmpty) {
      final gone = [for (final id in removed) splitMessageId(id).$2];
      final landed = [for (final uid in gone) copies[uid]];
      done.add(MessageMove(
        fromFolderId: fromFolderId,
        toFolderId: toFolderId,
        movedIds: landed.contains(null) ? const [] : landed.cast<String>(),
        messageIds: [for (final uid in gone) ?headers[uid]],
        originals: binned,
      ));
      went.addAll(removed);
    }
    if (stopped != null) {
      if (done.isEmpty) throw stopped;
      throw PartialMove(done: done, moved: went, cause: stopped);
    }
  }

  /// One folder's part of a batch move, into [toPath] in the same account.
  ///
  /// A failure before anything went is thrown as it is if nothing in the
  /// batch has gone yet ([done] empty), and as a [PartialMove] naming what
  /// has otherwise. A failure part way through this folder comes back as
  /// [stopped], with what did go.
  Future<
      ({
        List<int>? landed,
        ({List<int> uids, List<String> headers}) moved,
        Object? stopped,
      })> _moveGroup(
    String accountId,
    String fromPath,
    List<int> uids,
    String toPath, {
    required List<MessageMove> done,
    required List<String> went,
  }) async {
    final t = await _transport(accountId);
    // Out of Gmail's All Mail only ever by a copy: see _isAllMail.
    final copyOnly = await _isAllMail(accountId, t, fromPath);
    List<int>? landed;
    var moved = uids;
    Object? stopped;
    try {
      landed = copyOnly
          ? await t.copyMessages(fromPath, uids, toPath)
          : await t.moveMessages(fromPath, uids, toPath);
    } on MovedInPart catch (part) {
      landed = part.landed;
      moved = part.moved;
      stopped = part.cause;
    } catch (e) {
      if (done.isEmpty) rethrow;
      throw PartialMove(done: done, moved: went, cause: e);
    }
    // Read before the cache forgets them, which is the last place they
    // can be read from here.
    final headers = await cache.messageIdsFor(accountId, fromPath, moved);
    // A copy out of All Mail leaves the message in it, as it should be.
    if (!copyOnly) {
      await cache.deleteUids(accountId, fromPath, moved.toSet());
      _handled(_uidsIn('$accountId:$fromPath', moved));
    }
    // The destination picks the new messages up on its next sync; it may
    // not be cached at all yet, and guessing UIDs would be worse.
    //
    // Best-effort. The move has happened by now, and on a weak connection
    // this is what failed: the app then said the message was where it was
    // and put its row back, although it was already in Trash.
    try {
      await _syncIfCached(accountId, t, toPath);
    } catch (_) {
      // The destination catches up on its next sync.
    }
    return (
      landed: landed,
      moved: (uids: moved, headers: headers),
      stopped: stopped,
    );
  }

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return const [];
    final moves = <MessageMove>[];
    final went = <String>[];
    for (final group in _groupByFolder(messageIds).entries) {
      final (accountId, fromPath) = splitFolderId(group.key);
      final t = await _transport(accountId);
      final trash = await _trashPath(accountId, t);

      if (trash == null || fromPath == trash) {
        // Already in Trash, or the account has none: delete for good. There
        // is nothing to put back, and the empty entry is how the caller
        // knows not to offer.
        try {
          await t.storeFlag(fromPath,
              uids: group.value, flag: MessageFlag.deleted, set: true);
          await t.expunge(fromPath);
        } on FlaggedInPart catch (part) {
          // Microsoft deletes one message at a time, and some went: those
          // are gone here too, and only the rest come back on screen.
          await cache.deleteUids(accountId, fromPath, part.stored.toSet());
          _handled(_uidsIn(group.key, part.stored));
          moves.add(MessageMove(
            fromFolderId: group.key,
            toFolderId: group.key,
            movedIds: const [],
          ));
          went.addAll(
              [for (final uid in part.stored) MailMessage.idFor(group.key, uid)]);
          throw PartialMove(done: moves, moved: went, cause: part.cause);
        } catch (e) {
          if (moves.isEmpty) rethrow;
          throw PartialMove(done: moves, moved: went, cause: e);
        }
        await cache.deleteUids(accountId, fromPath, group.value.toSet());
        _handled(_uidsIn(group.key, group.value));
        moves.add(MessageMove(
          fromFolderId: group.key,
          toFolderId: group.key,
          movedIds: const [],
        ));
        went.addAll(
            [for (final uid in group.value) MailMessage.idFor(group.key, uid)]);
        continue;
      }

      final (:landed, :moved, :stopped) = await _moveGroup(
        accountId,
        fromPath,
        group.value,
        trash,
        done: moves,
        went: went,
      );
      final trashId = '$accountId:$trash';
      moves.add(MessageMove(
        fromFolderId: group.key,
        toFolderId: trashId,
        movedIds: [
          for (final uid in landed ?? const <int>[])
            MailMessage.idFor(trashId, uid),
        ],
        messageIds: moved.headers,
      ));
      went.addAll([for (final uid in moved.uids) MailMessage.idFor(group.key, uid)]);
      if (stopped != null) {
        throw PartialMove(done: moves, moved: went, cause: stopped);
      }
    }
    return moves;
  }

  @override
  Future<void> undoMoves(List<MessageMove> moves) async {
    for (final move in moves) {
      var ids = move.movedIds;
      if (ids.isEmpty) ids = await _locate(move.toFolderId, move.messageIds);
      if (ids.isEmpty) {
        throw const ConnectionFailed(
          'Those messages could not be found to put back.',
        );
      }
      final originals = move.originals;
      if (originals == null) {
        await moveMessages(ids, move.fromFolderId);
        continue;
      }
      // From another account: the originals come back out of Trash, and
      // only then do the copies go, so a failure leaves a message in both
      // accounts and never in neither.
      await undoMoves([originals]);
      await _takeOut(ids);
    }
  }

  /// Take the copies a move into another account made back out of the
  /// folder they went to, where they are, without Trash.
  ///
  /// Not into Trash and out again, which deletes a message everywhere.
  /// Gmail keeps one message per Message-ID, so a copy filed into a Gmail
  /// account that had the message already is that message, with the
  /// folder's label added, and this way only the label goes. A copy Gmail
  /// did not have before stays in All Mail; on Microsoft's servers, which
  /// make a new message every time, it is deleted.
  Future<void> _takeOut(List<String> messageIds) async {
    for (final group in _groupByFolder(messageIds).entries) {
      final (accountId, path) = splitFolderId(group.key);
      final t = await _transport(accountId);
      await t.storeFlag(path,
          uids: group.value, flag: MessageFlag.deleted, set: true);
      await t.expunge(path);
      await cache.deleteUids(accountId, path, group.value.toSet());
      _handled(_uidsIn(group.key, group.value));
    }
  }

  /// Find messages in [folderId] by the `Message-ID` they carry.
  ///
  /// The folder is synced first: this is the path taken when the server
  /// moved the mail without saying where, so the destination may never have
  /// been opened and have nothing cached at all.
  Future<List<String>> _locate(
    String folderId,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return const [];
    final (accountId, path) = splitFolderId(folderId);
    final t = await _transport(accountId);
    await _sync(accountId, t).sync(path);
    final uids = await cache.uidsForMessageIds(
      accountId,
      path,
      messageIds.toSet(),
    );
    return [for (final uid in uids) MailMessage.idFor(folderId, uid)];
  }

  @override
  Future<List<MailMessage>> searchMessages(
    String query,
    SearchScope scope, {
    int limit = 100,
    SearchField field = SearchField.all,
  }) async {
    if (query.trim().isEmpty) return const [];
    final wide = scope.folderId == null;
    final failures = <(Object, StackTrace)>[];
    final targets = await _searchTargets(scope, failures);

    // Across accounts, one that fails (no signal, a sign-in to renew, a
    // folder deleted elsewhere) leaves the others' results standing. It
    // used to throw them all away. Only when nothing at all could be
    // searched is it an error, a lost connection as much as any: an empty
    // list then said "No messages found" of mail never looked for. A
    // failed folder is null here, which an empty one is not.
    final results = await Future.wait([
      for (final t in targets)
        wide
            ? _searchOneFolder(t, query, limit, field)
                .then<List<MailMessage>?>(
                (found) => found,
                onError: (Object e, StackTrace s) {
                  failures.add((e, s));
                  return null;
                },
              )
            : _searchOneFolder(t, query, limit, field),
    ]);
    if (failures.isNotEmpty && results.every((r) => r == null)) {
      final (error, stack) = failures.first;
      Error.throwWithStackTrace(error, stack);
    }

    // On Gmail a label is the same message seen from another folder, so
    // one message could come back once from the Inbox and again from each
    // label on it, filling the list with copies. One per Message-ID per
    // account: the Inbox's copy where there is one, then a label's, and
    // All Mail's last. All Mail is asked only for mail no other folder has
    // (see _searchTargets), and should Gmail hand back a copy anyway, a
    // move made from it would leave the message in the Inbox or under its
    // label as well.
    int rank(FolderRole role) => switch (role) {
          FolderRole.inbox => 0,
          FolderRole.archive => 2,
          _ => 1,
        };
    final seen = <String>{};
    final unique = <MailMessage>[];
    for (final tier in [0, 1, 2]) {
      for (final (i, found) in results.indexed) {
        if (rank(targets[i].role) != tier) continue;
        for (final m in found ?? const <MailMessage>[]) {
          final id = m.messageId;
          if (id != null && !seen.add('${m.accountId}\u0000$id')) continue;
          unique.add(m);
        }
      }
    }
    unique.sort((a, b) => b.date.compareTo(a.date));
    return unique.take(limit).toList();
  }

  @override
  bool canRecoverDeleted(String accountId) {
    final account =
        accountStore.read().where((a) => a.id == accountId).firstOrNull;
    return account != null &&
        account.provider == MailProvider.outlook &&
        account.authMethod == AuthMethod.oauth;
  }

  @override
  Future<List<RecoverableMessage>> recoverableMessages(
    String accountId, {
    String query = '',
    int offset = 0,
    int limit = 50,
  }) async {
    final t = await _transport(accountId);
    if (t is! GraphTransport) {
      throw FolderOperationNotSupported(accountId, 'recover deleted items');
    }
    return t.recoverable(skip: offset, top: limit, query: query);
  }

  @override
  Future<int> recoverMessages(String accountId, List<String> ids) async {
    final t = await _transport(accountId);
    if (t is! GraphTransport) {
      throw FolderOperationNotSupported(accountId, 'recover deleted items');
    }
    // The Inbox's next sync finds what came back, and numbers it.
    return t.recover(ids);
  }

  /// The folder snoozed mail waits in, at the top of each account.
  static const snoozedFolderName = 'Snoozed';

  @override
  Future<List<MessageMove>> snooze(
    List<String> messageIds,
    DateTime until,
  ) async {
    final moves = <MessageMove>[];
    for (final group in _groupByFolder(messageIds).entries) {
      final (accountId, fromPath) = splitFolderId(group.key);
      if (fromPath == snoozedFolderName) continue;
      final t = await _transport(accountId);
      final remote = folderLists.read(accountId) ?? await t.listFolders();
      if (!remote.any((f) => f.path == snoozedFolderName)) {
        await t.createFolder(snoozedFolderName);
        await loadFolders(accountId);
      }
      final entries = <SnoozedEntry>[];
      final ids = <String>[];
      for (final uid in group.value) {
        final header =
            (await cache.readMessage(accountId, fromPath, uid))?.messageId;
        if (header == null || header.isEmpty) continue;
        entries.add((
          accountId: accountId,
          messageId: header,
          fromPath: fromPath,
          snoozedPath: snoozedFolderName,
          until: until,
        ));
        ids.add(MailMessage.idFor(group.key, uid));
      }
      if (ids.isEmpty) continue;
      // Written down before the move: a move that went through with nothing
      // to say when it comes back would leave it waiting for ever.
      await cache.addSnoozed(entries);
      moves.addAll(await moveMessages(
        ids,
        MailFolder.idFor(accountId, snoozedFolderName),
      ));
    }
    return moves;
  }

  @override
  Future<int> wakeSnoozed({DateTime? now}) async {
    final at = now ?? DateTime.now();
    List<SnoozedEntry> due;
    try {
      due = [
        for (final e in await cache.readSnoozed())
          if (!e.until.isAfter(at)) e,
      ];
    } catch (e) {
      debugPrint('[myemail] could not read snoozed mail: $e');
      return 0;
    }
    var woken = 0;
    for (final e in due) {
      try {
        if (accountStore.read().every((a) => a.id != e.accountId)) {
          await cache.removeSnoozed(e.accountId, e.messageId);
          continue;
        }
        final waiting = MailFolder.idFor(e.accountId, e.snoozedPath);
        final ids = await _locate(waiting, [e.messageId]);
        if (ids.isEmpty) {
          // Taken out of Snoozed by hand: nothing to bring back.
          await cache.removeSnoozed(e.accountId, e.messageId);
          continue;
        }
        final t = await _transport(e.accountId);
        final remote = folderLists.read(e.accountId) ?? await t.listFolders();
        final back = remote.any((f) => f.path == e.fromPath)
            ? e.fromPath
            : remote
                    .where((f) => f.role == FolderRole.inbox)
                    .firstOrNull
                    ?.path ??
                'INBOX';
        final target = MailFolder.idFor(e.accountId, back);
        final moves = await moveMessages(ids, target);
        var landed = [for (final m in moves) ...m.movedIds];
        if (landed.isEmpty) landed = await _locate(target, [e.messageId]);
        if (landed.isNotEmpty) await setMessagesRead(landed, false);
        await cache.removeSnoozed(e.accountId, e.messageId);
        woken++;
      } catch (error) {
        debugPrint('[myemail] snoozed mail not back yet: $error');
      }
    }
    return woken;
  }

  @override
  Future<DateTime?> nextSnoozeWake() async {
    final all = await cache.readSnoozed();
    if (all.isEmpty) return null;
    return all.map((e) => e.until).reduce((a, b) => a.isBefore(b) ? a : b);
  }

  @override
  Future<List<MailMessage>> flaggedMessages(
    String accountId, {
    int limit = 100,
  }) async {
    final account = _accountFor(accountId);
    final t = await _transport(accountId);
    final remote = folderLists.read(accountId) ?? await t.listFolders();
    final leftOut = {
      for (final f in remote)
        if (f.role == FolderRole.deleted || f.role == FolderRole.junk) f.path,
    };
    if (t is GraphTransport) {
      final found = [
        for (final h in await t.flaggedHits(limit: limit))
          if (!leftOut.contains(h.path)) h,
      ];
      final rows = <MailMessage>[];
      for (final path in {for (final h in found) h.path}) {
        final mine = [
          for (final h in found)
            if (h.path == path) h,
        ];
        final due = {for (final h in mine) h.hit.uid: h.due};
        for (final m in await _rowsFor(
            accountId, path, t, [for (final h in mine) h.hit])) {
          rows.add(m.copyWith(flagDue: due[m.uid]));
        }
      }
      return rows..sort((a, b) => b.date.compareTo(a.date));
    }
    // Gmail: All Mail holds every label's mail, so the flag is asked of it
    // once. A star is the message's, whichever label it is seen under.
    final all = remote.where((f) => f.role == FolderRole.archive).firstOrNull;
    final path = all?.path ?? 'INBOX';
    final hits = await t.filterHits(
      path,
      MessageFilter.flagged,
      ownAddress: account.emailAddress,
      limit: limit,
    );
    return _rowsFor(accountId, path, t, hits);
  }

  @override
  Future<List<MailMessage>> cachedFlagged(
    String accountId, {
    int limit = 100,
  }) async {
    final remote = folderLists.read(accountId) ?? const <RemoteFolder>[];
    final roles = {for (final f in remote) f.path: f.role};
    final found = await cache.readFlagged(accountId, limit: limit * 2);
    final seen = <String>{};
    final rows = <MailMessage>[];
    // All Mail's copy first where a Gmail message is in more than one
    // folder, as the server's answer will have it.
    final ordered = [
      for (final f in found)
        if (roles[f.path] == FolderRole.archive) f,
      for (final f in found)
        if (roles[f.path] != FolderRole.archive) f,
    ];
    for (final (:path, :message) in ordered) {
      final role = roles[path];
      if (role == FolderRole.deleted || role == FolderRole.junk) continue;
      final key = message.messageId ?? '$path#${message.uid}';
      if (!seen.add(key)) continue;
      final folderId = MailFolder.idFor(accountId, path);
      rows.add(message.toMailMessage(accountId: accountId, folderId: folderId));
    }
    rows.sort((a, b) => b.date.compareTo(a.date));
    return rows.take(limit).toList();
  }

  @override
  Future<List<MailMessage>> filterMessages(
    String folderId,
    MessageFilter filter, {
    int limit = 100,
  }) async {
    if (filter == MessageFilter.all) return const [];
    final (accountId, path) = splitFolderId(folderId);
    final account = _accountFor(accountId);
    final t = await _transport(accountId);
    final hits = await t.filterHits(
      path,
      filter,
      ownAddress: account.emailAddress,
      limit: limit,
    );
    return _rowsFor(accountId, path, t, hits);
  }

  Future<List<MailMessage>> _searchOneFolder(
    _SearchTarget target,
    String query,
    int limit,
    SearchField field,
  ) async {
    final (:accountId, :path, role: _, :unlabelledOnly) = target;
    final t = await _transport(accountId);
    final hits = await t.searchHits(
      path,
      query,
      limit: limit,
      field: field,
      unlabelledOnly: unlabelledOnly,
    );
    return _rowsFor(accountId, path, t, hits);
  }

  /// [hits] in one folder as rows, newest first as they came: from the
  /// header the server sent with each where it sent one, else from the
  /// cache, and the rest fetched in one request.
  Future<List<MailMessage>> _rowsFor(
    String accountId,
    String path,
    ImapTransport t,
    List<SearchHit> hits,
  ) async {
    if (hits.isEmpty) return const [];
    final folderId = MailFolder.idFor(accountId, path);

    MailMessage row(
      RemoteHeader h, {
      String? preview,
      List<String>? names,
      Importance? importance,
    }) =>
        MailMessage(
          id: MailMessage.idFor(folderId, h.uid),
          accountId: accountId,
          folderId: folderId,
          uid: h.uid,
          subject: h.subject,
          from: h.from,
          to: h.to,
          cc: h.cc,
          replyTo: h.replyTo,
          date: h.date,
          arrived: h.arrived,
          preview: preview ?? h.preview,
          isRead: h.isRead,
          isFlagged: h.isFlagged,
          isAnswered: h.isAnswered,
          isForwarded: h.isForwarded,
          hasAttachments: h.hasAttachments,
          // A Microsoft hit says only that it has files; the cached row may
          // know what they are called.
          attachmentNames: h.attachmentNames ?? names ?? const [],
          importance: h.importance ?? importance ?? Importance.normal,
          sizeBytes: h.sizeBytes,
          isMeeting: h.isMeeting,
          messageId: h.messageId,
          inReplyTo: h.inReplyTo,
          conversationId: h.conversationId,
        );

    // Anything already cached is read in one go and brings its preview
    // along. What the search brought a header for needs nothing more, and
    // only the rest is fetched, all of it in one request.
    final cached = {
      for (final c in await cache.readHeaders(
        accountId,
        path,
        [for (final hit in hits) hit.uid],
      ))
        c.uid: c,
    };
    final rows = <MailMessage>[];
    final missing = <int>[];
    final caughtUp = <int, CachedFlags>{};
    for (final hit in hits) {
      final c = cached[hit.uid];
      if (hit.header case final h?) {
        // The server's word, just given, over the cached row's: a Microsoft
        // sync keeps only the newest rows' flags current, so an older one
        // read in Outlook still showed bold here. The cached row is brought
        // up to date with it, so a move or an open from the results agrees.
        rows.add(row(
          h,
          preview: c != null && h.preview.isEmpty ? c.preview : null,
          names: c?.attachmentNames,
          importance: c?.importance,
        ));
        if (c != null &&
            (c.isRead, c.isFlagged, c.isAnswered, c.isForwarded) !=
                (h.isRead, h.isFlagged, h.isAnswered, h.isForwarded)) {
          caughtUp[h.uid] = (
            isRead: h.isRead,
            isFlagged: h.isFlagged,
            isAnswered: h.isAnswered,
            isForwarded: h.isForwarded,
          );
        }
      } else if (c != null) {
        rows.add(c.toMailMessage(accountId: accountId, folderId: folderId));
      } else {
        missing.add(hit.uid);
      }
    }
    if (caughtUp.isNotEmpty) {
      try {
        await cache.updateFlags(accountId, path, caughtUp);
      } catch (_) {
        // The results are right either way; the next sync that reaches
        // the rows puts them right too.
      }
    }
    if (missing.isNotEmpty) {
      rows.addAll((await t.fetchHeadersByUids(path, missing)).map(row));
    }
    return rows;
  }

  /// The (account, folder path) pairs a scope covers.
  /// The folders a search looks in. Failures to list an account's folders
  /// go into [failures] rather than out, so the other accounts are still
  /// searched.
  Future<List<_SearchTarget>> _searchTargets(
    SearchScope scope,
    List<(Object, StackTrace)> failures,
  ) async {
    if (scope.folderId != null) {
      // All Mail searched on its own is searched whole: it is the folder
      // open, and everything in it is what is being looked through.
      final (accountId, path) = splitFolderId(scope.folderId!);
      return [
        (
          accountId: accountId,
          path: path,
          role: FolderRole.user,
          unlabelledOnly: false,
        ),
      ];
    }
    final accounts = [
      for (final a in accountStore.read())
        if (scope.accountId == null || a.id == scope.accountId) a,
    ];
    final targets = <_SearchTarget>[];
    for (final account in accounts) {
      List<RemoteFolder> remote;
      final cached = folderLists.read(account.id);
      if (cached != null) {
        remote = cached;
      } else {
        try {
          remote = await (await _transport(account.id)).listFolders();
        } catch (e, s) {
          // An unreachable account among them too: it was not searched, and
          // when none was, that is what the search has to say.
          failures.add((e, s));
          continue;
        }
      }
      final gmail = account.provider == MailProvider.gmail;
      for (final f in remote) {
        // Spam and Trash are not what "search my mail" means.
        if (f.role == FolderRole.junk || f.role == FolderRole.deleted) {
          continue;
        }
        // Gmail's All Mail is searched for the mail archived with no label
        // on it, which is there and nowhere else, and only for that. Asked
        // for everything, nearly every hit was a copy of the Inbox's or a
        // label's: a header fetched for each, for a row searchMessages
        // then dropped, and the copies filled its hundred hits before
        // older archived mail had a place. Starred and Important are
        // labels on mail All Mail has as well, so they would add nothing
        // but another search.
        if (gmail && f.isServerManaged) continue;
        targets.add((
          accountId: account.id,
          path: f.path,
          role: f.role,
          unlabelledOnly: gmail && f.role == FolderRole.archive,
        ));
      }
    }
    return targets;
  }

  /// Message ids grouped by the folder they live in, so one folder is one
  /// server round trip rather than one per message.
  static Map<String, List<int>> _groupByFolder(List<String> messageIds) {
    final byFolder = <String, List<int>>{};
    for (final id in messageIds) {
      final (folderId, uid) = splitMessageId(id);
      (byFolder[folderId] ??= []).add(uid);
    }
    return byFolder;
  }

  /// New mail in an Inbox from a blocked sender ([senderBlocks]), into the
  /// account's Junk folder as it arrives, before any list or notification
  /// has it: Outlook's Block Sender, carried out by the app. Mail that was
  /// there before, or put back since, is left where it is.
  ///
  /// Best-effort: a move that fails leaves the mail in the Inbox, and is
  /// logged rather than failing the sync it came with.
  Future<void> _junkBlocked(
    String accountId,
    ImapTransport t,
    String path,
    List<int> arrived,
  ) async {
    final blocks = senderBlocks?.call();
    if (blocks == null || blocks.isEmpty || arrived.isEmpty) return;
    try {
      final remote = folderLists.read(accountId) ?? await t.listFolders();
      if (!remote.any((f) => f.path == path && f.role == FolderRole.inbox)) {
        return;
      }
      final junk =
          remote.where((f) => f.role == FolderRole.junk).firstOrNull?.path;
      if (junk == null) return;
      final folderId = MailFolder.idFor(accountId, path);
      final blocked = <String>[];
      for (final uid in arrived) {
        final row = await cache.readMessage(accountId, path, uid);
        if (row != null && blocks.blocks(row.from.email)) {
          blocked.add(MailMessage.idFor(folderId, uid));
        }
      }
      if (blocked.isEmpty) return;
      await moveMessages(blocked, MailFolder.idFor(accountId, junk));
      debugPrint('[myemail] ${blocked.length} from blocked senders to Junk');
    } catch (e) {
      debugPrint('[myemail] could not move blocked mail to Junk: $e');
    }
  }

  /// Whether [path] is Gmail's All Mail, which holds every message the
  /// account has whatever its labels. A message leaves it only by being
  /// deleted, so it is never moved out of it: an Archive undone is a copy
  /// back into the Inbox, which puts the Inbox label back. A move would
  /// take it out of All Mail too, which Gmail reads as a delete, and so
  /// the Undo of an Archive would have sent the message to Trash.
  Future<bool> _isAllMail(
    String accountId,
    ImapTransport t,
    String path,
  ) async {
    if (_providerFor(accountId) != MailProvider.gmail) return false;
    final remote = folderLists.read(accountId) ?? await t.listFolders();
    return remote.any((f) => f.path == path && f.role == FolderRole.archive);
  }

  Future<String?> _trashPath(String accountId, ImapTransport t) async {
    final remote = folderLists.read(accountId) ?? await t.listFolders();
    for (final f in remote) {
      if (f.role == FolderRole.deleted) return f.path;
    }
    return null;
  }

  /// Sync a folder only if something is already cached for it; an untouched
  /// folder is left to its first open.
  Future<void> _syncIfCached(
    String accountId,
    ImapTransport t,
    String path,
  ) async {
    if (await cache.readFolderState(accountId, path) == null) return;
    await _sync(accountId, t).sync(path);
  }

  /// [flag] set or cleared on [messageIds], one call to the server per
  /// folder, and the cache told of each that changed. See
  /// [MailEngine.setMessagesRead] for what a failure throws.
  Future<void> _setFlagOn(
    List<String> messageIds,
    MessageFlag flag,
    bool set, {
    Future<void> Function(ImapTransport t, String path, List<int> uids)? store,
  }) async {
    final changed = <String>[];
    final failed = <String>[];
    (Object, StackTrace)? first;
    for (final group in _groupByFolder(messageIds).entries) {
      final (accountId, path) = splitFolderId(group.key);
      var stored = group.value;
      try {
        final t = await _transport(accountId);
        if (store != null) {
          await store(t, path, group.value);
        } else {
          await t.storeFlag(path, uids: group.value, flag: flag, set: set);
        }
      } on FlaggedInPart catch (part, stack) {
        stored = part.stored;
        first ??= (part.cause, stack);
      } catch (e, stack) {
        stored = const [];
        first ??= (e, stack);
      }
      final went = stored.toSet();
      for (final uid in group.value) {
        (went.contains(uid) ? changed : failed)
            .add(MailMessage.idFor(group.key, uid));
      }

      final flags = <int, CachedFlags>{};
      for (final uid in went) {
        final cached = await cache.readMessage(accountId, path, uid);
        if (cached == null) continue;
        flags[uid] = (
          isRead: flag == MessageFlag.seen ? set : cached.isRead,
          isFlagged: flag == MessageFlag.flagged ? set : cached.isFlagged,
          isAnswered: cached.isAnswered,
          isForwarded: cached.isForwarded,
        );
      }
      if (flags.isNotEmpty) await cache.updateFlags(accountId, path, flags);
    }
    if (flag == MessageFlag.seen && set && changed.isNotEmpty) {
      _handled(changed.toSet().contains);
    }
    if (first == null) return;
    if (changed.isEmpty) Error.throwWithStackTrace(first.$1, first.$2);
    throw PartialFlagChange(failed: failed, cause: first.$1);
  }

  @override
  Future<String?> saveDraft(Draft draft) async {
    final account = accountStore.read().firstWhere(
          (a) => a.id == draft.accountId,
          orElse: () => throw StateError('Unknown account ${draft.accountId}'),
        );
    final draftsPath = await _folderPathForRole(account.id, FolderRole.drafts);
    if (draftsPath == null) {
      // Said rather than returned quietly. Compose closed on "Saved to
      // Drafts" when nothing had been saved anywhere, and the half-written
      // message was gone.
      throw SendFailed(
        'The app cannot find a Drafts folder for ${account.emailAddress}, so '
        'the message was not saved.',
      );
    }

    final message = buildMimeMessage(draft: draft, account: account);
    final t = await _transport(account.id);

    // Append before deleting the old copy. The other order loses the draft
    // outright if the append then fails, and a duplicate is a far better
    // failure than a message that no longer exists anywhere.
    await t.appendMessage(draftsPath, message.renderMessage(), draft: true);
    await _dropPreviousDraft(draft.savedAs);

    // Resync so the new copy is in the cache, then find it: APPEND does not
    // reliably report the UID it landed on, and UIDPLUS is not universal.
    //
    // Past the append the draft is saved, whatever happens here. A failure
    // to find it used to throw, and a reply from the shade, taking that for
    // "not saved", went round again and left a copy in Drafts each time.
    try {
      await _sync(account.id, t).sync(draftsPath);
      final newest = await cache.uidRange(account.id, draftsPath);
      if (newest == null) return null;
      return MailMessage.idFor(
        MailFolder.idFor(account.id, draftsPath),
        newest.max,
      );
    } catch (e) {
      debugPrint('[myemail] draft saved, but not found again: $e');
      return null;
    }
  }

  @override
  Future<void> discardDraft(String savedAs) => _dropPreviousDraft(savedAs);

  /// Remove the copy a draft was opened from, so saving twice does not leave
  /// two. Best-effort: a draft that failed to delete is untidy, not broken.
  Future<void> _dropPreviousDraft(String? savedAs) async {
    if (savedAs == null) return;
    try {
      final (folderId, uid) = splitMessageId(savedAs);
      final (accountId, path) = splitFolderId(folderId);
      final t = await _transport(accountId);
      await t.storeFlag(path, uids: [uid], flag: MessageFlag.deleted, set: true);
      await t.expunge(path);
      await cache.deleteUids(accountId, path, {uid});
    } catch (_) {
      // Already gone, or the server refused. Either way the new copy is safe.
    }
  }

  @override
  Future<void> sendDraft(Draft draft) async {
    if (!draft.hasRecipients) {
      throw const SendFailed('Add at least one recipient.');
    }
    final account = accountStore.read().firstWhere(
          (a) => a.id == draft.accountId,
          orElse: () => throw StateError('Unknown account ${draft.accountId}'),
        );
    final credentials = await _credentialsFor(account);

    // Pictures kept in the HTML as data, a signature's logo above all, go
    // out as parts of their own, which Gmail and Outlook show and a data:
    // picture they do not. Here, so both routes below have it.
    final outgoing = withPicturesAsParts(draft);
    final message = buildMimeMessage(draft: outgoing, account: account);
    await _send(account, credentials, message, draft: outgoing);

    // It is away, so the copy in Drafts is now a duplicate of sent mail.
    await _dropPreviousDraft(draft.savedAs);

    // Gmail and Graph file sent mail into Sent themselves, so appending
    // would leave two copies. The check is per provider for one that does
    // not.
    if (_needsSentCopy(account.provider)) {
      final sentPath = await _folderPathForRole(account.id, FolderRole.sent);
      if (sentPath != null) {
        try {
          final t = await _transport(account.id);
          await t.appendMessage(sentPath, message.renderMessage());
        } catch (_) {
          // The message is already away; failing to file a copy is not worth
          // telling the user the send failed.
        }
      }
    }

    // What it replied to or passed on, marked so the arrow shows beside it
    // here and in every other mail app.
    await _markOriginals(draft);
  }

  /// Mark what [draft] replied to or forwarded, now that it is away: the
  /// message it was written from, and each message it carries whole as an
  /// attachment.
  ///
  /// On the server, then in the cache, so a list drawn again shows the mark
  /// at once rather than after the next sync. Never throws: the message has
  /// gone, and a mark that could not be made is no reason to say it has not.
  Future<void> _markOriginals(Draft draft) async {
    final original = draft.originalMessageId;
    if (original != null && draft.kind != ComposeKind.newMessage) {
      await _markOriginal(original, draft.kind);
    }
    final forwarded = {
      for (final a in draft.attachments) ?a.forwardedMessageId,
    };
    for (final messageId in forwarded) {
      await _markOriginal(messageId, ComposeKind.forward);
    }
  }

  Future<void> _markOriginal(String messageId, ComposeKind kind) async {
    final forward = kind == ComposeKind.forward;
    try {
      final (folderId, uid) = splitMessageId(messageId);
      final (accountId, path) = splitFolderId(folderId);
      final t = await _transport(accountId);
      if (forward) {
        await t.markForwarded(path, uid);
      } else {
        await t.markAnswered(path, uid, toAll: kind == ComposeKind.replyAll);
      }
      final cached = await cache.readMessage(accountId, path, uid);
      if (cached == null) return;
      // Written as the server now has it. Exchange keeps only what was done
      // last, so there the other mark goes; IMAP keeps both.
      final keepsOther = t.keepsBothMarks;
      await cache.updateFlags(accountId, path, {
        uid: (
          isRead: cached.isRead,
          isFlagged: cached.isFlagged,
          isAnswered: !forward || (keepsOther && cached.isAnswered),
          isForwarded: forward || (keepsOther && cached.isForwarded),
        ),
      });
    } catch (e) {
      debugPrint('[myemail] could not mark $messageId '
          '${forward ? 'forwarded' : 'answered'}: $e');
    }
  }

  /// Whether the app must file its own copy of a sent message.
  ///
  /// Both providers we support file it themselves, so appending would leave
  /// two copies of everything in Sent. Gmail has always done this for mail
  /// submitted over SMTP. Microsoft does it for mail sent through Graph,
  /// which is the path this app uses for it.
  ///
  /// If a sent message ever fails to appear in Sent for some provider, this
  /// is the switch: return true for it and the engine appends the copy
  /// itself.
  static bool _needsSentCopy(MailProvider provider) => switch (provider) {
        MailProvider.gmail => false,
        MailProvider.outlook => false,
      };

  Future<String?> _folderPathForRole(String accountId, FolderRole role) async {
    final remote = folderLists.read(accountId);
    if (remote == null) return null;
    for (final f in remote) {
      if (f.role == role) return f.path;
    }
    return null;
  }

  /// Put the message on the wire by whichever route the provider actually
  /// supports.
  ///
  /// Microsoft goes through Graph. SMTP submission is off by default for every
  /// tenant, Microsoft recommends against turning it on, and a tenant with
  /// security defaults enabled blocks it outright — so an app that only speaks
  /// SMTP cannot send from a work mailbox at all, and often not from a
  /// personal one either.
  ///
  /// Gmail stays on SMTP, where an app password works and there is nothing to
  /// gain from changing it.
  Future<void> _send(
    Account account,
    MailCredentials credentials,
    em.MimeMessage message, {
    Draft? draft,
  }) async {
    final injected = senderFactory?.call(account, credentials);
    if (injected != null) return injected.send(message);

    if (account.provider == MailProvider.outlook &&
        credentials is OAuthCredentials) {
      final sender = graphSenderFactory?.call(account, credentials) ??
          GraphSender(
            accessToken: ({bool force = false}) =>
                _tokenFor(account, force: force),
            mailbox: account.isShared ? account.emailAddress : null,
          );
      // The draft, not just the built message: a message too large to post
      // in one request has to be assembled on the server from its parts,
      // and the parts are in the draft.
      return draft == null
          ? sender.send(message)
          : sender.sendDraft(
              draft: draft,
              account: account,
              threadHeaders: await _threadHeaders(account, draft),
            );
    }

    return SmtpSender.forProvider(
      provider: account.provider,
      user: account.emailAddress,
      credentials: credentials,
    ).send(message);
  }

  /// Outlook's `Thread-Index` and `Thread-Topic` for a reply or forward of
  /// a message in the same Microsoft mailbox, made from the original's own
  /// index, so Exchange files it in the original's conversation. Without
  /// them every reply sent from here began a conversation of its own, in
  /// Outlook too. Empty for a new message, a reply from another account,
  /// and whenever the original cannot be asked: the message still goes,
  /// only as it went before.
  Future<Map<String, String>> _threadHeaders(
    Account account,
    Draft draft,
  ) async {
    final original = draft.originalMessageId;
    if (original == null || draft.kind == ComposeKind.newMessage) {
      return const {};
    }
    try {
      final (folderId, uid) = splitMessageId(original);
      final (accountId, path) = splitFolderId(folderId);
      if (accountId != account.id) return const {};
      final t = await _transport(accountId);
      if (t is! GraphTransport) return const {};
      final parent = await t.conversationIndexOf(path, uid);
      final index =
          parent == null ? null : replyThreadIndex(parent, DateTime.now());
      if (index == null) return const {};
      return {
        'Thread-Index': index,
        'Thread-Topic': threadTopic(draft.subject),
      };
    } catch (e) {
      debugPrint('[myemail] could not keep the reply in its thread: $e');
      return const {};
    }
  }

  // --- plumbing --------------------------------------------------------------

  /// The account's connection, made once however many ask at the same time.
  ///
  /// At start-up the folder tree and the message list ask for the same
  /// account together. Each used to find none, build its own and log in,
  /// and the second replaced the first in [_transports], so the first stayed
  /// open where [close] could never reach it. Everyone asking while one is
  /// being made now waits for that one.
  Future<ImapTransport> _transport(String accountId) async {
    final existing = _transports[accountId];
    if (existing != null) return existing;
    // A block, not an arrow: remove() hands back this very future, and
    // whenComplete would then wait on itself for ever.
    return _opening[accountId] ??= _open(accountId).whenComplete(() {
      _opening.remove(accountId);
    });
  }

  Future<ImapTransport> _open(String accountId) async {
    final account = accountStore.read().firstWhere(
          (a) => a.id == accountId,
          orElse: () => throw StateError('Unknown account $accountId'),
        );
    return _transports[accountId] =
        _transportFactory(account, await _credentialsFor(account));
  }

  /// Which service an account talks to, for the folder mapping.
  ///
  /// Gmail if the account has gone missing, which cannot normally happen:
  /// this is only reached for an account whose folders are being listed. The
  /// fallback keeps a folder list rendering rather than throwing from a
  /// mapping function.
  MailProvider _providerFor(String accountId) =>
      accountStore
          .read()
          .where((a) => a.id == accountId)
          .firstOrNull
          ?.provider ??
      MailProvider.gmail;

  /// How this account signs in, ready to be used when a connection opens.
  ///
  /// The OAuth branch reads nothing now on purpose. A token fetched here
  /// would be stale by the time a long-lived transport reconnected hours
  /// later, so what the transport gets is the means of asking, and the
  /// asking happens per connection.
  Future<MailCredentials> _credentialsFor(Account account) async {
    switch (account.authMethod) {
      case AuthMethod.oauth:
        return OAuthCredentials(
          ({bool force = false}) => _tokenFor(account, force: force),
        );
      case AuthMethod.appPassword:
        final secret = await credentialStore.readSecret(account.id);
        if (secret == null) {
          throw AuthenticationFailed(
            'No password is stored for ${account.emailAddress}. '
            'Remove the account and add it again.',
          );
        }
        return PasswordCredentials(secret);
    }
  }

  /// The token [account]'s mail is reached with: its own, or a shared
  /// mailbox's owner's, asked for with the shared-mailbox permissions by
  /// name, so an owner that has not allowed them reads as needing consent.
  Future<String> _tokenFor(Account account, {bool force = false}) {
    final via = account.sharedVia;
    return via == null
        ? oauthTokens.accessToken(account.id, force: force)
        : oauthTokens.accessToken(
            via,
            force: force,
            scopes: MicrosoftOAuth.sharedMailboxScopes,
          );
  }

  FolderSync _sync(String accountId, ImapTransport transport) =>
      _syncs.putIfAbsent(
        accountId,
        () => FolderSync(transport: transport, store: cache, accountId: accountId),
      );
}

/// One folder a search looks in, and whether only the mail no other folder
/// holds is wanted of it (see [ImapTransport.searchUids]).
typedef _SearchTarget = ({
  String accountId,
  String path,
  FolderRole role,
  bool unlabelledOnly,
});
