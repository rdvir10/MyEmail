import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/notifications/android_mail_notifier.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sync/background_sync.dart';
import 'package:myemail/data/sync/sync_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/folder_capabilities.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/domain/sync_prefs.dart';

import 'fakes/fake_imap_transport.dart';

/// New-mail notifications going away once the mail has been dealt with.
///
/// Nothing used to take one down. Read, filed or deleted in the app, or on
/// another device, a message kept its notification, whose Delete then said
/// it had failed and whose tap opened a message that was gone.
void main() {
  group('the engine says what it dealt with', () {
    late FakeImapTransport server;
    late CachedImapEngine engine;
    late Account account;
    late List<bool Function(String)> handled;

    setUp(() async {
      server = FakeImapTransport();
      server.folder('INBOX', role: FolderRole.inbox);
      server.folder('[Gmail]/Trash', role: FolderRole.deleted);
      server.folder('Work');
      handled = [];
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
        onMessagesHandled: handled.add,
      );
      account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      server.folder('INBOX')
        ..deliver(subject: 'One')
        ..deliver(subject: 'Two');
    });

    bool anyTakes(String messageId) => handled.any((h) => h(messageId));

    test('marking one read', () async {
      final inbox = await engine.loadMessages('${account.id}:INBOX');

      await engine.setRead(inbox.first.id, true);

      expect(anyTakes(inbox.first.id), isTrue);
      expect(anyTakes(inbox.last.id), isFalse);
    });

    test('but not marking one unread', () async {
      final inbox = await engine.loadMessages('${account.id}:INBOX');

      await engine.setRead(inbox.first.id, false);

      expect(handled, isEmpty);
    });

    test('moving and deleting', () async {
      final inbox = await engine.loadMessages('${account.id}:INBOX');

      await engine.moveMessages([inbox.first.id], '${account.id}:Work');
      expect(anyTakes(inbox.first.id), isTrue);

      await engine.deleteMessages([inbox.last.id]);
      expect(anyTakes(inbox.last.id), isTrue);
    });

    test('marking the whole folder read takes its messages and no others',
        () async {
      final inbox = await engine.loadMessages('${account.id}:INBOX');

      await engine.markAllRead('${account.id}:INBOX');

      expect(anyTakes(inbox.first.id), isTrue);
      expect(anyTakes('${account.id}:Work#1'), isFalse);
      expect(anyTakes('${account.id}:INBOX#x#1'), isFalse,
          reason: 'a folder whose name carries on past a # is another folder');
    });
  });

  group('the background pass', () {
    late FakeImapTransport server;
    late CachedImapEngine engine;
    late FakeMailNotifier notifier;
    late BackgroundSync sync;
    late Account account;

    setUp(() async {
      server = FakeImapTransport();
      server.folder('INBOX', role: FolderRole.inbox);
      engine = CachedImapEngine(
        accountStore: MemoryAccountStore(),
        credentialStore: MemoryCredentialStore(),
        cache: MemoryCacheStore(),
        transportFactory: (_, _) => server,
      );
      account = await engine.addAccount(
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        secret: 'abcdabcdabcdabcd',
      );
      notifier = FakeMailNotifier();
      final now = DateTime.now();
      sync = BackgroundSync(
        engine: engine,
        notifier: notifier,
        state: MemorySyncStateStore(
          prefs: const SyncPrefs(mode: SyncMode.periodic),
        ),
        clock: () => now,
      );
      // A first pass to set the mark, then three new messages announced.
      await sync.run();
      for (final subject in ['Kept', 'Read elsewhere', 'Deleted elsewhere']) {
        server.folder('INBOX').deliver(subject: subject, date: now);
      }
      await sync.run();
    });

    test('takes down what was read or deleted elsewhere, and only that',
        () async {
      final shown = await notifier.shownMessageIds();
      expect(shown, hasLength(3));
      final inbox = server.folder('INBOX');
      final read = inbox.messages.values
          .firstWhere((m) => m.subject == 'Read elsewhere');
      final deleted = inbox.messages.values
          .firstWhere((m) => m.subject == 'Deleted elsewhere');
      final kept =
          inbox.messages.values.firstWhere((m) => m.subject == 'Kept');
      read.isRead = true;
      read.modSeq = inbox.bump();
      inbox.delete(deleted.uid);

      await sync.run();

      expect(await notifier.shownMessageIds(),
          {'${account.id}:INBOX#${kept.uid}'});
    });
  });

  group('on Android', () {
    late _Plugin plugin;
    late AndroidMailNotifier notifier;

    const account = Account(
      id: 'a',
      displayName: 'P',
      emailAddress: 'p@example.com',
      provider: MailProvider.gmail,
      authMethod: AuthMethod.appPassword,
      colorValue: 0xFF0F6CBD,
    );
    const inbox = MailFolder(
      id: 'a:INBOX',
      accountId: 'a',
      name: 'INBOX',
      path: 'INBOX',
      capabilities: FolderCapabilities.systemFolder(),
      role: FolderRole.inbox,
    );
    MailNotification one(String id) => MailNotification(
          id: MailNotification.idForMessage(id),
          title: 'Someone',
          body: 'Subject',
          payload: id,
          when: DateTime(2026, 9, 1),
        );

    setUp(() {
      plugin = _Plugin();
      notifier = AndroidMailNotifier(
        plugin: plugin,
        drawBadge: (_) async => null,
      );
    });

    test('each message is posted under its own id, and found by it',
        () async {
      await notifier.showNewMail(
        account: account,
        folder: inbox,
        notifications: [one('a:INBOX#1'), one('a:INBOX#2')],
      );

      expect(await notifier.shownMessageIds(), {'a:INBOX#1', 'a:INBOX#2'});
    });

    test('one taken down leaves the rest and their summary', () async {
      await notifier.showNewMail(
        account: account,
        folder: inbox,
        notifications: [one('a:INBOX#1'), one('a:INBOX#2')],
      );

      await notifier.withdraw((id) => id == 'a:INBOX#1');

      expect(await notifier.shownMessageIds(), {'a:INBOX#2'});
      expect(plugin.showing.length, 2, reason: 'one message and the summary');
    });

    test('the last one taken down takes its summary with it', () async {
      await notifier.showNewMail(
        account: account,
        folder: inbox,
        notifications: [one('a:INBOX#1')],
      );

      await notifier.withdraw((id) => id == 'a:INBOX#1');

      expect(plugin.showing, isEmpty,
          reason: 'a summary saying "1 new message" over nothing');
    });

    test('a list Android will not give is nothing to take down', () async {
      plugin.listFails = true;

      await notifier.withdraw((_) => true);

      expect(await notifier.shownMessageIds(), isEmpty);
    });
  });

  group('account badges', () {
    test('one that fails is tried again for the next batch', () async {
      // One slow draw in a worker that had just started used to take the
      // badges off everything that worker posted for most of an hour.
      final plugin = _Plugin();
      var draws = 0;
      final png = Uint8List.fromList([1, 2, 3]);
      final notifier = AndroidMailNotifier(
        plugin: plugin,
        drawBadge: (_) async => ++draws == 1 ? null : png,
      );
      const account = Account(
        id: 'a',
        displayName: 'P',
        emailAddress: 'p@example.com',
        provider: MailProvider.gmail,
        authMethod: AuthMethod.appPassword,
        colorValue: 0xFF0F6CBD,
      );
      const inbox = MailFolder(
        id: 'a:INBOX',
        accountId: 'a',
        name: 'INBOX',
        path: 'INBOX',
        capabilities: FolderCapabilities.systemFolder(),
        role: FolderRole.inbox,
      );
      MailNotification one(String id) => MailNotification(
            id: MailNotification.idForMessage(id),
            title: 'Someone',
            body: 'Subject',
            payload: id,
            when: DateTime(2026, 9, 1),
          );

      await notifier.showNewMail(
          account: account, folder: inbox, notifications: [one('a:INBOX#1')]);
      await notifier.showNewMail(
          account: account, folder: inbox, notifications: [one('a:INBOX#2')]);

      expect(plugin.largeIcons['a:INBOX#1'], isNull);
      expect(plugin.largeIcons['a:INBOX#2'], isNotNull);
    });
  });
}

/// Android's notification shade, reduced to what the notifier asks of it.
class _Plugin implements FlutterLocalNotificationsPlugin {
  /// What is showing, by (tag, id).
  final Map<(String?, int), ActiveNotification> showing = {};
  final Map<String, Object?> largeIcons = {};
  bool listFails = false;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async =>
      true;

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async =>
      null;

  @override
  T? resolvePlatformSpecificImplementation<
      T extends FlutterLocalNotificationsPlatform>() => null;

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    final android = notificationDetails?.android;
    final tag = android?.tag;
    showing[(tag, id)] = ActiveNotification(
      id: id,
      tag: tag,
      groupKey: android?.groupKey,
      title: title,
      body: body,
    );
    if (tag != null) largeIcons[tag] = android?.largeIcon;
  }

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async {
    if (listFails) throw UnsupportedError('Android 5');
    return showing.values.toList();
  }

  @override
  Future<void> cancel({required int id, String? tag}) async =>
      showing.remove((tag, id));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
