import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/compose/smtp_sender.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_credentials.dart';

import 'fakes/fake_imap_transport.dart';

/// Adding an Outlook.com account, and the ways it is not a Gmail account.
void main() {
  late FakeImapTransport server;
  late MemoryAccountStore accounts;
  late MemoryCredentialStore secrets;
  late CachedImapEngine engine;
  late List<MailCredentials> handed;

  setUp(() {
    server = FakeImapTransport();
    accounts = MemoryAccountStore();
    secrets = MemoryCredentialStore();
    handed = [];
    engine = CachedImapEngine(
      accountStore: accounts,
      credentialStore: secrets,
      cache: MemoryCacheStore(),
      transportFactory: (_, credentials) {
        handed.add(credentials);
        return server;
      },
    );
    server.folder('INBOX', role: FolderRole.inbox);
    server.folder('Sent', role: FolderRole.sent);
    server.folder('Archive', role: FolderRole.archive);
  });

  OAuthToken token({String access = 'access-1'}) => OAuthToken(
        accessToken: access,
        refreshToken: 'refresh-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

  Future<Account> addOutlook() => engine.addOAuthAccount(
        displayName: 'Personal',
        emailAddress: 'someone@example.com',
        provider: MailProvider.outlook,
        token: token(),
      );

  group('adding the account', () {
    test('records it as an OAuth account, not a password one', () async {
      final account = await addOutlook();

      expect(account.authMethod, AuthMethod.oauth);
      expect(account.provider, MailProvider.outlook);
    });

    test('stores the whole token, so the refresh token survives a restart',
        () async {
      final account = await addOutlook();

      final stored = OAuthToken.fromStoredJson(
        await secrets.readSecret(account.id),
      );
      expect(stored, isNotNull);
      expect(stored!.accessToken, 'access-1');
      expect(stored.refreshToken, 'refresh-1',
          reason: 'without this the account cannot get another access token '
              'and signs itself out within the hour');
    });

    test('proves the token against the server before storing anything',
        () async {
      server.offline = true;

      await expectLater(addOutlook(), throwsA(isA<Object>()));

      expect(accounts.read(), isEmpty);
      expect(await secrets.readSecret('acct-1'), isNull);
    });

    test('later connections get refreshable credentials, not the one token',
        () async {
      // The transport built during the probe closes over the token that was
      // just handed in. Keeping it would leave the account working until that
      // token expired and then failing with no way to refresh, which is the
      // sort of bug that only shows up an hour into use.
      final account = await addOutlook();
      handed.clear();

      await engine.loadFolders(account.id);

      expect(handed.single, isA<OAuthCredentials>());
    });

    test('a Gmail account still gets a password', () async {
      await engine.addAccount(
        displayName: 'Personal',
        emailAddress: 'me@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );

      expect(handed.single, isA<PasswordCredentials>());
    });
  });

  group('folders', () {
    test('Archive accepts messages on Outlook but not on Gmail', () async {
      // The difference is not cosmetic. On Gmail, "All Mail" is every message
      // the account holds and archiving is removing a label, so a drop there
      // does nothing. On Outlook, Archive is an ordinary folder and one of
      // the most-used move targets there.
      expect(
        FolderCapabilities.forOutlook(FolderRole.archive).canAcceptMessages,
        isTrue,
      );
      expect(
        FolderCapabilities.forGmail(FolderRole.archive).canAcceptMessages,
        isFalse,
      );
    });

    test('an Outlook account gets the Outlook rules', () async {
      final account = await addOutlook();

      final folders = await engine.loadFolders(account.id);
      final archive = folders.firstWhere((f) => f.role == FolderRole.archive);

      expect(archive.capabilities.canAcceptMessages, isTrue,
          reason: 'the provider on the account must reach the folder mapping');
    });

    test('Sent and Drafts accept appends on Outlook', () {
      // Gmail files sent mail itself and refuses arbitrary appends; Outlook
      // does not mind, which is how a draft written here appears on the web.
      expect(
        FolderCapabilities.forOutlook(FolderRole.sent).canAcceptMessages,
        isTrue,
      );
      expect(
        FolderCapabilities.forOutlook(FolderRole.drafts).canAcceptMessages,
        isTrue,
      );
    });

    test('the special folders still cannot be renamed or deleted', () {
      for (final role in [
        FolderRole.inbox,
        FolderRole.sent,
        FolderRole.drafts,
        FolderRole.archive,
        FolderRole.deleted,
        FolderRole.junk,
      ]) {
        final c = FolderCapabilities.forOutlook(role);
        expect(c.canRename, isFalse, reason: '$role');
        expect(c.canDelete, isFalse, reason: '$role');
        expect(c.canMove, isFalse, reason: '$role');
      }
    });

    test('ordinary folders are fully editable', () {
      final c = FolderCapabilities.forOutlook(FolderRole.user);
      expect(c.canRename, isTrue);
      expect(c.canCreateChild, isTrue);
      expect(c.canDelete, isTrue);
    });
  });

  group('where to connect', () {
    // These are settings, not logic, and normally not worth a test. They earn
    // one because they are provider-specific, they cannot be exercised
    // without a real account, and getting them wrong fails as a hang or a
    // refused connection rather than as anything that names the cause.
    test('Gmail submits over implicit TLS on 465', () {
      expect(SmtpSender.smtpHostFor(MailProvider.gmail), 'smtp.gmail.com');
      expect(SmtpSender.portFor(MailProvider.gmail), 465);
      expect(SmtpSender.usesStartTlsFor(MailProvider.gmail), isFalse);
    });

    test('Microsoft submits over STARTTLS on 587, because 465 is not open',
        () {
      expect(
        SmtpSender.smtpHostFor(MailProvider.outlook),
        'smtp.office365.com',
      );
      expect(SmtpSender.portFor(MailProvider.outlook), 587);
      expect(SmtpSender.usesStartTlsFor(MailProvider.outlook), isTrue);
    });

    test('both read mail over IMAP on the standard TLS port', () {
      expect(
        CachedImapEngine.imapHostFor(MailProvider.outlook),
        'outlook.office365.com',
      );
      expect(CachedImapEngine.imapHostFor(MailProvider.gmail), 'imap.gmail.com');
    });
  });
}
