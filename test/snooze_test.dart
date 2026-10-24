import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/account_store.dart';
import 'package:myemail/data/cache/cache_store.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/imap/cached_imap_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/sync/background_worker.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_providers.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/messages/reading_pane.dart';
import 'package:myemail/ui/messages/snooze_sheet.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_imap_transport.dart';
import 'fakes/fake_webview.dart';

/// Snooze (#32): out of the list until a time chosen, waiting in a Snoozed
/// folder on the server, and back in its folder, unread, at that time.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  group('the times offered', () {
    String said(List<({String label, DateTime at})> choices) =>
        [for (final c in choices) '${c.label} ${c.at}'].join(' | ');

    test('on a Wednesday morning: later today, tomorrow, the weekend, '
        'next week', () {
      // Wednesday 28 October 2026, ten in the morning.
      expect(
        said(snoozeChoices(DateTime(2026, 10, 28, 10))),
        'Later today 2026-10-28 13:00:00.000 | '
        'Tomorrow 2026-10-29 08:00:00.000 | '
        'This weekend 2026-10-31 08:00:00.000 | '
        'Next week 2026-11-02 08:00:00.000',
      );
    });

    test('late in the day there is no later today; on a Friday the weekend '
        'is tomorrow, said once', () {
      expect(
        said(snoozeChoices(DateTime(2026, 10, 28, 19))),
        isNot(contains('Later today')),
      );
      final friday = snoozeChoices(DateTime(2026, 10, 30, 10));
      expect(friday.map((c) => c.label),
          ['Later today', 'Tomorrow', 'Next week']);
      expect(friday.last.at, DateTime(2026, 11, 2, 8));
    });

    test('in a week worked from Sunday to Thursday', () {
      const week = {
        DateTime.sunday,
        DateTime.monday,
        DateTime.tuesday,
        DateTime.wednesday,
        DateTime.thursday,
      };
      final choices = snoozeChoices(DateTime(2026, 10, 28, 10), workWeek: week);
      expect(
        {for (final c in choices) c.label: c.at},
        {
          'Later today': DateTime(2026, 10, 28, 13),
          'Tomorrow': DateTime(2026, 10, 29, 8),
          'This weekend': DateTime(2026, 10, 30, 8),
          'Next week': DateTime(2026, 11, 1, 8),
        },
      );
    });
  });

  group('on the server', () {
    late FakeImapTransport server;
    late CachedImapEngine engine;
    late Account account;

    setUp(() async {
      server = FakeImapTransport()
        ..folder('INBOX', role: FolderRole.inbox)
        ..folder('[Gmail]/Trash', role: FolderRole.deleted);
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
      await engine.loadFolders(account.id);
    });

    String inbox() => '${account.id}:INBOX';

    test('waits in a Snoozed folder made for it, and comes back unread at '
        'its time', () async {
      server.folder('INBOX').deliver(subject: 'Later', isRead: true);
      final message = (await engine.loadMessages(inbox())).single;
      final until = DateTime(2026, 10, 27, 8);

      final moves = await engine.snooze([message.id], until);

      expect(moves.single.toFolderId, '${account.id}:Snoozed');
      expect(server.calls, contains('CREATE Snoozed'));
      expect(await engine.loadMessages(inbox()), isEmpty);
      expect(await engine.nextSnoozeWake(), until);

      expect(await engine.wakeSnoozed(now: DateTime(2026, 10, 27, 7)), 0,
          reason: 'not before its time');
      expect(await engine.wakeSnoozed(now: DateTime(2026, 10, 27, 8, 1)), 1);

      final back = (await engine.loadMessages(inbox())).single;
      expect(back.subject, 'Later');
      expect(back.isRead, isFalse, reason: 'back unread, as Outlook brings it');
      expect(server.folder('Snoozed').messages, isEmpty);
      expect(await engine.nextSnoozeWake(), isNull);
    });

    test('one taken out of Snoozed by hand is let go', () async {
      server.folder('INBOX').deliver(subject: 'Later');
      final message = (await engine.loadMessages(inbox())).single;
      await engine.snooze([message.id], DateTime(2026, 10, 27, 8));
      server.folder('Snoozed').messages.clear();

      expect(await engine.wakeSnoozed(now: DateTime(2026, 10, 28)), 0);
      expect(await engine.nextSnoozeWake(), isNull);
    });

    test('back to the Inbox where its folder has gone', () async {
      server
        ..folder('Work')
        ..folder('Work').deliver(subject: 'Filed');
      await engine.loadFolders(account.id);
      final message =
          (await engine.loadMessages('${account.id}:Work')).single;
      await engine.snooze([message.id], DateTime(2026, 10, 27, 8));
      server.folders.remove('Work');
      await engine.loadFolders(account.id);

      expect(await engine.wakeSnoozed(now: DateTime(2026, 10, 28)), 1);
      expect((await engine.loadMessages(inbox())).single.subject, 'Filed');
    });
  });

  group('on screen', () {
    late FakeBackgroundScheduler scheduler;

    Future<ProviderContainer> pump(
      WidgetTester tester,
      SampleMailEngine engine,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      scheduler = FakeBackgroundScheduler();
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        backgroundSchedulerProvider.overrideWithValue(scheduler),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    List<String> rows(ProviderContainer c) => [
          for (final m in c.read(sortedMessagesProvider(
              c.read(effectiveSelectedFolderIdProvider)!)))
            m.id,
        ];

    testWidgets('from the message\'s menu: Tomorrow takes it out of the list '
        'until tomorrow morning, and Undo puts it back', (tester) async {
      final engine = SampleMailEngine();
      final c = await pump(tester, engine);
      await tester.tap(find.byType(MessageTile).first);
      await tester.pumpAndSettle();
      final message = c.read(selectedMessageProvider)!;

      await tester.tap(find.descendant(
        of: find.byType(ReadingPane),
        matching: find.byTooltip('More'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Snooze…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('snooze-Tomorrow')));
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1, 8);
      expect(rows(c), isNot(contains(message.id)));
      expect(engine.snoozed.values.single.until, tomorrow);
      expect(scheduler.wakes.last, tomorrow,
          reason: 'the background is told when to bring it back');
      expect(find.textContaining('Snoozed until'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      final inbox =
          await tester.runAsync(() => engine.loadMessages(message.folderId));
      expect(inbox!.any((m) => m.subject == message.subject), isTrue);
    });

    testWidgets('a swipe can be set to Snooze, and asks when', (tester) async {
      final engine = SampleMailEngine();
      final c = await pump(tester, engine);
      c.read(displayProvider.notifier).setSwipeLeft(SwipeAction.snooze);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(MessageTile).first, const Offset(-500, 0));
      await tester.pumpAndSettle();

      expect(find.text('Snooze until'), findsOneWidget);
    });
  });
}
