import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';
import 'package:myemail/data/widget/mailbox_widgets.dart';
import 'package:myemail/data/widget/widget_setup_channel.dart';
import 'package:myemail/data/widget/widget_state_store.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_folder.dart';
import 'package:myemail/state/folder_tree.dart' show kUnifiedInboxId;

/// Home-screen widgets when something is wrong somewhere else.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('one account in trouble', () {
    late _OneAccountRefused engine;
    late FakeHomeScreenSurface surface;
    late MemoryWidgetStateStore store;
    late MailboxWidgets widgets;
    late String healthy;
    late String troubled;

    setUp(() async {
      engine = _OneAccountRefused();
      surface = FakeHomeScreenSurface();
      store = MemoryWidgetStateStore();
      widgets = MailboxWidgets(surface: surface, store: store);
      final accounts = await engine.loadAccounts();
      Future<String> inboxOf(String accountId) async =>
          (await engine.loadFolders(accountId))
              .firstWhere((f) => f.role == FolderRole.inbox)
              .id;
      healthy = await inboxOf(accounts[0].id);
      troubled = await inboxOf(accounts[1].id);
      await widgets.setUp(
          appWidgetId: '1',
          mailbox: WidgetMailbox(folderId: healthy),
          engine: engine);
      await widgets.setUp(
          appWidgetId: '2',
          mailbox: WidgetMailbox(folderId: troubled),
          engine: engine);
      await widgets.setUp(
          appWidgetId: '3',
          mailbox: WidgetMailbox(folderId: kUnifiedInboxId),
          engine: engine);
      engine.refused = accounts[1].id;
      surface.values.clear();
    });

    test('does not stop the other widgets updating', () async {
      // A lapsed sign-in on one account used to leave every widget, Gmail
      // and All inboxes included, on old numbers until it was fixed.
      await widgets.refresh(engine);

      expect(surface.values['count.$healthy.total'], isNotNull);
      expect(surface.values['count.$kUnifiedInboxId.total'], isNotNull,
          reason: 'All inboxes counts that account as it was last seen');
    });

    test('and its own widget keeps its mailbox rather than going blank',
        () async {
      await widgets.refresh(engine);

      expect(surface.values['widget.2.folder'], troubled);
      expect(surface.values.containsKey('count.$troubled.total'), isFalse,
          reason: 'what it last showed stays on screen');
    });
  });

  group('which widgets are placed', () {
    const channel = MethodChannel('mailtree/widget');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('none is an answer, not "not known"', () async {
      // Both were an empty list, so removing the last widget was never
      // noticed: it went on being counted and listed in Settings.
      messenger.setMockMethodCallHandler(channel, (_) async => <String>[]);

      expect(await placedWidgetIds(), isEmpty);
      expect(await placedWidgetIds(), isNotNull);
    });

    test('and a failure to ask is "not known"', () async {
      messenger.setMockMethodCallHandler(
          channel, (_) async => throw PlatformException(code: 'nope'));

      expect(await placedWidgetIds(), isNull);
    });

    test('and with none placed, every widget is forgotten', () async {
      final store = MemoryWidgetStateStore();
      store.mailboxes['1'] = const WidgetMailbox(folderId: 'a:INBOX');

      await MailboxWidgets(surface: FakeHomeScreenSurface(), store: store)
          .refresh(SampleMailEngine(), placed: const []);

      expect(store.mailboxes, isEmpty);
    });
  });
}

/// One account whose folders cannot be listed: a sign-in to renew.
class _OneAccountRefused extends SampleMailEngine {
  String? refused;

  @override
  Future<List<MailFolder>> loadFolders(String accountId) async {
    if (accountId == refused) {
      throw const AuthenticationFailed('Sign in again.');
    }
    return super.loadFolders(accountId);
  }
}
