import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/notifications/notification_action_isolate.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/data/notifications/pending_actions.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/mail_message.dart';
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

    test('a drain still working keeps its claim fresh', () async {
      await queue().add(delete(1));
      final held = (await queue().take()).single;
      for (final f in dir.listSync().whereType<File>()) {
        f.setLastModifiedSync(
            DateTime.now().subtract(const Duration(hours: 1)));
      }

      await queue().touch(held);

      expect(await queue().take(), isEmpty,
          reason: 'freshened, so not taken for a dead drain');
    });

    test('a drain that lost its claim while frozen sends and finishes nothing',
        () async {
      // Frozen mid-press long enough for its claim to look dead, it woke
      // after another drain had taken the press and sent the reply, and
      // sent it again.
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: 'a:INBOX#1',
        typed: 'Yes.',
      ));
      final frozen = (await queue().take()).single;
      for (final f in dir.listSync().whereType<File>()) {
        f.setLastModifiedSync(
            DateTime.now().subtract(const Duration(minutes: 10)));
      }
      final other = (await queue().take()).single;

      await expectLater(queue().markSending(frozen), throwsA(isA<LostClaim>()));
      await queue().done(frozen);
      await queue().putBack(frozen);

      final marked = await queue().markSending(other);
      expect(marked.action.sendStarted, isTrue,
          reason: "still the other drain's to send");
    });

    test('a claim left by a process that has died is let go at once',
        () async {
      await queue().add(delete(1));
      final press = dir.listSync().whereType<File>().single;
      File('${press.path}.claim').writeAsStringSync('999999999:gone');

      expect(await queue().take(), hasLength(1));
    });

    test('a press whose write was cut off is brought back', () async {
      // Written aside and not yet renamed into place when the isolate died:
      // nothing read the file, and the reply in it was gone.
      final tmp = File('${dir.path}${Platform.pathSeparator}1-a.tmp')
        ..writeAsStringSync(jsonEncode(const PendingAction(
          actionId: NotificationActions.replyId,
          messageId: 'a:INBOX#1',
          typed: 'Ten works.',
        ).toJson()))
        ..setLastModifiedSync(
            DateTime.now().subtract(const Duration(minutes: 5)));

      expect((await queue().take()).single.action.typed, 'Ten works.');
      expect(tmp.existsSync(), isFalse);
    });

    test('but one being written now is left alone', () async {
      final tmp = File('${dir.path}${Platform.pathSeparator}1-a.tmp')
        ..writeAsStringSync('{"action":"mailtree.del');

      expect(await queue().take(), isEmpty);
      expect(tmp.readAsStringSync(), '{"action":"mailtree.del',
          reason: 'the writer still has to rename it');
      expect(dir.listSync().where((f) => f.path.endsWith('.json')), isEmpty);
    });

    test('a write cut off before its contents does not replace the press',
        () async {
      // Killed between opening the file and writing it: the empty .tmp was
      // put over the good press, which was then dropped as unreadable,
      // typed reply and all.
      await queue().add(const PendingAction(
        actionId: NotificationActions.replyId,
        messageId: 'a:INBOX#1',
        typed: 'Ten works.',
      ));
      final json = dir.listSync().whereType<File>().single;
      File('${json.path.substring(0, json.path.length - 5)}.tmp')
        ..writeAsStringSync('')
        ..setLastModifiedSync(
            DateTime.now().subtract(const Duration(minutes: 5)));

      expect((await queue().take()).single.action.typed, 'Ten works.');
      expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('a press put back is replaced in place, never deleted first',
        () async {
      // Deleted and then written, a press was gone for good if the isolate
      // died in between.
      await queue().add(delete(1));
      final claim = (await queue().take()).single;
      final json = dir
          .listSync()
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.json'));
      final base = json.path.substring(0, json.path.length - '.json'.length);
      // Where the new copy would be written: the write fails part way.
      Directory('$base.tmp').createSync();

      await expectLater(
          queue().putBack(claim), throwsA(isA<FileSystemException>()));

      expect(json.existsSync(), isTrue,
          reason: 'still there when its replacement never landed');
      Directory('$base.tmp').deleteSync();
    });

    test('when it was pressed goes with it', () async {
      final before = DateTime.now();
      await queue().add(delete(1));

      final queued = (await queue().take()).single.action.queuedAt;
      expect(queued, isNotNull);
      expect(queued!.isBefore(before.subtract(const Duration(seconds: 1))),
          isFalse);
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

    test('a failure to open the mail keeps the mark a send left', () async {
      // Cleared, the next drain sent a reply that may already have gone.
      final id = await anInboxMessage();
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: id,
        typed: 'Yes.',
        sendStarted: true,
      ));

      final result = await drainPendingNotificationActions(
        queue: queue(),
        open: () async => throw StateError('no database'),
      );

      expect(result.waiting, 1);
      expect((await queue().take()).single.action.sendStarted, isTrue);
    });

    test('a reply that throws is said as a reply, with its words', () async {
      // It was reported as a failed Delete: "the message is where it was",
      // and what was typed nowhere.
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: await anInboxMessage(),
        typed: 'Thursday is fine.',
      ));
      final reported = <String>[];

      for (var i = 0; i < maxActionAttempts; i++) {
        await drainPendingNotificationActions(
          queue: queue(),
          open: () async => (_Throwing(engine), () async {}),
          report: (outcome, action) async =>
              reported.add('${outcome.name}:${action.typed}'),
        );
      }

      expect(reported, ['notKept:Thursday is fine.']);
    });

    test('a stop asked for before a reply goes leaves it to be sent later',
        () async {
      // Sent inside the stop's grace and cut off, it came back as "may or
      // may not have gone" though nothing had been sent when the stop came.
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: await anInboxMessage(),
        typed: 'Yes.',
      ));
      var stopping = false;

      final result = await drainPendingNotificationActions(
        queue: queue(),
        open: () async => (
          NotificationActions(engine: _StopDuring(engine, () => stopping = true)),
          () async {},
        ),
        report: (_, _) async {},
        shouldStop: () => stopping,
      );

      expect(engine.sends, 0);
      expect(result.waiting, 1);
      final kept = (await queue().take()).single.action;
      expect(kept.sendStarted, isFalse);
      expect(kept.attempts, 0, reason: 'a stop is not a failed try');
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

    test('presses are claimed one at a time, so a stop strands none',
        () async {
      // All were claimed up front. A drain Android stopped left every one
      // claimed for half an hour, while the job that ran next found
      // nothing it could take and called that success.
      final id = await anInboxMessage();
      for (var i = 0; i < 3; i++) {
        await queue().add(PendingAction(
          actionId: NotificationActions.replyId,
          messageId: id,
          typed: 'Reply $i',
        ));
      }
      var stopping = false;

      final result = await drainPendingNotificationActions(
        queue: queue(),
        open: () async => (NotificationActions(engine: engine), () async {}),
        // Android asks to stop once the first is done.
        report: (_, _) async => stopping = true,
        shouldStop: () => stopping,
      );

      expect(result.done, 1);
      expect(result.waiting, 2);
      expect(await queue().take(), hasLength(2),
          reason: 'unclaimed, for whoever looks next');
    });

    test('a press another drain is working on is counted, so someone looks '
        'again', () async {
      // That drain may die before it finishes; a queue it held used to
      // look empty, and nothing came back for it.
      await queue().add(delete(1));
      await queue().take(); // another drain, still at it

      final result = await drain();

      expect(result.held, 1);
      expect(result.leftOver, isTrue);
    });

    test('a reply is marked as being sent before it goes', () async {
      final id = await anInboxMessage();
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: id,
        typed: 'Yes.',
      ));
      String? onDisk;
      engine.onSend = () => onDisk = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .single
          .readAsStringSync();

      await drain();

      expect(onDisk, contains('"sending":true'));
    });

    test('a reply put back after a send that did not go loses the mark',
        () async {
      final id = await anInboxMessage();
      engine.offline = true;
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: id,
        typed: 'Yes.',
      ));

      expect((await drain()).waiting, 1);
      expect((await queue().take()).single.action.sendStarted, isFalse,
          reason: 'it did not go, so it may be sent next time');
    });

    test('a reply marked as being sent is never sent again', () async {
      final id = await anInboxMessage();
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: id,
        typed: 'Yes, ten.',
        sendStarted: true,
      ));
      final reported = <String>[];

      await drain(report: (outcome, action) async {
        reported.add('${outcome.name}:${action.typed}');
      });

      expect(engine.sends, 0);
      expect(reported, ['maybeSent:Yes, ten.']);
      expect(await queue().take(), isEmpty);
    });

    test('a press that has waited a day for a connection is given up on',
        () async {
      // Offline was retried for ever: a Microsoft refusal read as offline
      // kept one press, and everything behind it, going round.
      final id = await anInboxMessage();
      engine.offline = true;
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: id,
        typed: 'Thursday is fine.',
        queuedAt: DateTime.now().subtract(const Duration(hours: 25)),
      ));
      final reported = <String>[];

      final result = await drain(report: (outcome, action) async {
        reported.add('${outcome.name}:${action.typed}');
      });

      expect(result.waiting, 0);
      expect(reported, ['notKept:Thursday is fine.']);
    });

    test('a report that alone holds what was typed keeps it queued if it '
        'cannot be posted', () async {
      final id = await anInboxMessage();
      await queue().add(PendingAction(
        actionId: NotificationActions.replyId,
        messageId: id,
        typed: 'Yes, ten.',
        sendStarted: true,
      ));

      final result = await drain(report: (_, _) async {
        throw StateError('the notification could not be posted');
      });

      expect(result.waiting, 1);
      final kept = (await queue().take()).single.action;
      expect(kept.typed, 'Yes, ten.');
      expect(kept.sendStarted, isTrue, reason: 'still never sent again');
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

/// Actions whose every press throws, as a broken original can make a
/// reply do.
class _Throwing extends NotificationActions {
  _Throwing(MailEngine engine) : super(engine: engine);

  @override
  Future<ActionOutcome> perform(
    String actionId,
    String messageId,
    String? typed, {
    bool sendStarted = false,
    Future<void> Function()? beforeSend,
  }) =>
      throw StateError('could not quote the original');
}

/// The engine, with Android asking the job to stop while the original is
/// being read, before the reply is sent.
class _StopDuring extends SampleMailEngine {
  _StopDuring(this._inner, this._stop);

  final _Failing _inner;
  final void Function() _stop;

  @override
  Future<MailMessage?> cachedMessage(String messageId) async {
    _stop();
    return _inner.cachedMessage(messageId);
  }

  @override
  Future<void> sendDraft(Draft draft) => _inner.sendDraft(draft);
}

class _Failing extends SampleMailEngine {
  bool offline = false;
  bool broken = false;
  bool sendFails = false;
  bool noDraftsFolder = false;
  void Function()? onSend;
  int sends = 0;

  void _check() {
    if (offline) throw const ConnectionFailed('offline');
    if (broken) throw StateError('broken');
  }

  @override
  Future<void> sendDraft(Draft draft) async {
    sends++;
    onSend?.call();
    _check();
    if (sendFails) throw const SendFailed('refused');
    return super.sendDraft(draft);
  }

  @override
  Future<String?> saveDraft(Draft draft) async {
    _check();
    // As the engines say it: an account with no Drafts folder throws.
    if (noDraftsFolder) throw const SendFailed('No Drafts folder.');
    return super.saveDraft(draft);
  }
}
