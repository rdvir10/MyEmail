import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/notifications/notification_action_isolate.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/data/notifications/pending_actions.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/draft.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// The queue that makes a notification button actually happen.
///
/// Android gives the isolate it starts for a notification action very little
/// time, and the plugin's callback returns void, so nothing waits for work
/// started inside it. A delete is a round trip to the mail server, which that
/// isolate does not reliably survive — which is why pressing Delete appeared
/// to do nothing at all. So the press is written down, which is quick and
/// cannot half-happen, and something with a proper lifetime does the rest.
void main() {
  late Directory dir;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    dir = Directory.systemTemp.createTempSync('myemail-pending-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  PendingActions queue() => PendingActions(directory: dir);

  PendingAction delete(int uid) => PendingAction(
        actionId: NotificationActions.deleteId,
        messageId: 'a:INBOX#$uid',
      );

  group('the queue', () {
    test('a press survives being written down and read back', () async {
      await queue().add(delete(42));

      final waiting = await queue().take();

      expect(waiting, hasLength(1));
      expect(waiting.single.action.actionId, NotificationActions.deleteId);
      expect(waiting.single.action.messageId, 'a:INBOX#42');
      expect(waiting.single.action.typed, isNull);
    });

    test('what was typed into a reply comes back with it', () async {
      await queue().add(const PendingAction(
        actionId: NotificationActions.replyId,
        messageId: 'a:INBOX#42',
        typed: 'Ten works.',
      ));

      expect((await queue().take()).single.action.typed, 'Ten works.');
    });

    test('presses come back in the order they were made', () async {
      await queue().add(delete(1));
      await queue().add(delete(2));

      final waiting = await queue().take();

      expect(waiting.map((c) => c.action.messageId),
          ['a:INBOX#1', 'a:INBOX#2']);
    });

    test('taking one claims it, so nothing is done twice', () async {
      await queue().add(delete(42));

      expect(await queue().take(), hasLength(1));
      expect(await queue().take(), isEmpty);
    });

    test('two presses written at once are both kept', () async {
      // One list, read, changed and written back: the second write lost the
      // first press.
      await Future.wait([queue().add(delete(1)), queue().add(delete(2))]);

      expect(await queue().take(), hasLength(2));
    });

    test('two drains at once share out the presses, never both one', () async {
      // The WorkManager job and the app opening, together: a reply went
      // twice.
      for (var i = 0; i < 20; i++) {
        await queue().add(delete(i));
      }

      final both = await Future.wait([queue().take(), queue().take()]);

      final ids = [
        for (final side in both) ...side.map((c) => c.action.messageId),
      ];
      expect(ids, hasLength(20));
      expect(ids.toSet(), hasLength(20));
    });

    test('a press made while a drain runs is left for the next', () async {
      // It used to be wiped with the list the drain had just emptied,
      // typed reply and all.
      await queue().add(delete(1));
      final taking = queue().take();
      await queue().add(delete(2));

      final first = await taking;
      final second = await queue().take();

      expect(
        [...first, ...second].map((c) => c.action.messageId).toSet(),
        {'a:INBOX#1', 'a:INBOX#2'},
      );
    });

    test('a press put back is there for the next drain, one try older',
        () async {
      await queue().add(delete(1));
      final claim = (await queue().take()).single;

      await queue().putBack(claim);
      final again = (await queue().take()).single;
      expect(again.action.attempts, 1);

      await queue().putBack(again, counted: false);
      expect((await queue().take()).single.action.attempts, 1,
          reason: 'being offline is not a failed try');
    });

    test('a press a killed drain was holding comes back in time', () async {
      await queue().add(delete(1));
      await queue().take(); // and never finished
      expect(await queue().take(), isEmpty);

      for (final f in dir.listSync().whereType<File>()) {
        f.setLastModifiedSync(
            DateTime.now().subtract(const Duration(hours: 1)));
      }

      expect((await queue().take()).single.action.messageId, 'a:INBOX#1');
    });

    test('but one that waited long before it was taken is not taken twice',
        () async {
      await queue().add(delete(1));
      for (final f in dir.listSync().whereType<File>()) {
        f.setLastModifiedSync(
            DateTime.now().subtract(const Duration(hours: 1)));
      }

      expect(await queue().take(), hasLength(1));
      expect(await queue().take(), isEmpty,
          reason: 'held by the first drain, which is still working on it');
    });

    test('an unreadable record is dropped, not carried around', () async {
      File('${dir.path}${Platform.pathSeparator}1-a.json')
          .writeAsStringSync('not json at all');
      File('${dir.path}${Platform.pathSeparator}2-b.json')
          .writeAsStringSync('{"action":"mailtree.delete"}');

      expect(await queue().take(), isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('presses queued by the previous version are brought in', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        PendingActions.legacyKey:
            '[{"action":"mailtree.delete","message":"a:INBOX#7"}]',
      });

      expect((await queue().take()).single.action.messageId, 'a:INBOX#7');
      expect(
        await SharedPreferencesAsync().getString(PendingActions.legacyKey),
        isNull,
      );
    });
  });

  test('the app reports without setting the notifications up again', () {
    // Set up again with no tap handler, the plugin dropped the app's own:
    // until a restart, tapping new mail brought the app forward without
    // opening the message. No Dart test can run the plugin, so this reads
    // the place the app drains the queue. (main.dart had a second, for
    // presses delivered to the app itself, which Android never does for
    // these buttons.)
    for (final path in ['lib/ui/shell/app_shell.dart']) {
      final source = File(path).readAsStringSync();
      expect(source, contains('drainPendingNotificationActions('),
          reason: path);
      expect(source, contains('reportOutcome(outcome, action, pluginReady: true)'),
          reason: path);
    }
  });

  group('carrying them out', () {
    /// The sample engine, with ways to make it fail.
    late _Failing engine;

    setUp(() => engine = _Failing());

    Future<DrainResult> drain({
      Future<void> Function(ActionOutcome, PendingAction)? report,
    }) =>
        drainPendingNotificationActions(
          queue: queue(),
          open: () async => (NotificationActions(engine: engine), () async {}),
          report: report ?? (_, _) async {},
        );

    Future<String> anInboxMessage() async {
      final account = (await engine.loadAccounts()).first;
      final inbox = (await engine.loadFolders(account.id)).first;
      return (await engine.loadMessages(inbox.id)).first.id;
    }

    test('a report that fails does not stop the next press', () async {
      final id = await anInboxMessage();
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: id,
        typed: 'Yes.',
      ));
      await queue().add(PendingAction(
        actionId: NotificationActions.deleteId,
        messageId: id,
      ));
      engine.sendFails = true; // so the reply is reported, into Drafts
      var reports = 0;

      final result = await drain(report: (_, _) async {
        reports++;
        throw StateError('the notification could not be posted');
      });

      expect(result.done, 2);
      expect(reports, 2);
    });

    test('a failure to open the mail puts every press back', () async {
      await queue().add(delete(1));
      await queue().add(delete(2));

      final result = await drainPendingNotificationActions(
        queue: queue(),
        open: () async => throw StateError('no database'),
      );

      expect(result.waiting, 2);
      expect(await queue().take(), hasLength(2));
    });

    test('a reply typed while offline waits for a connection', () async {
      // It was taken off the queue before anything was tried, and opening
      // the app offline lost what was typed for good.
      final id = await anInboxMessage();
      engine.offline = true;
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: id,
        typed: 'Thursday is fine.',
      ));

      expect((await drain()).waiting, 1);
      final kept = (await queue().take()).single;
      expect(kept.action.typed, 'Thursday is fine.');
      expect(kept.action.attempts, 0);
    });

    test('one that keeps failing is given up on, and what was typed shown',
        () async {
      final id = await anInboxMessage();
      engine.broken = true;
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: id,
        typed: 'Thursday is fine.',
      ));
      final reported = <String>[];

      for (var i = 0; i < maxActionAttempts; i++) {
        await drain(report: (outcome, action) async {
          reported.add('${outcome.name}:${action.typed}');
        });
      }

      expect(reported, ['notKept:Thursday is fine.']);
      expect(await queue().take(), isEmpty);
    });

    test('a draft that went nowhere is not reported as in Drafts', () async {
      final id = await anInboxMessage();
      engine
        ..sendFails = true
        ..noDraftsFolder = true;

      final outcome = await NotificationActions(engine: engine)
          .perform(NotificationActions.replyId, id, 'Thursday is fine.');

      expect(outcome, isNot(ActionOutcome.savedAsDraft));
    });
  });
}

class _Failing extends SampleMailEngine {
  bool offline = false;
  bool broken = false;
  bool sendFails = false;
  bool noDraftsFolder = false;

  void _check() {
    if (offline) throw const ConnectionFailed('offline');
    if (broken) throw StateError('broken');
  }

  @override
  Future<void> sendDraft(Draft draft) async {
    _check();
    if (sendFails) throw const SendFailed('refused');
    return super.sendDraft(draft);
  }

  @override
  Future<String?> saveDraft(Draft draft) async {
    _check();
    if (noDraftsFolder) return null;
    return super.saveDraft(draft);
  }
}
