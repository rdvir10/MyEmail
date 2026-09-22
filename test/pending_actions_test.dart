import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/notifications/notification_actions.dart';
import 'package:myemail/data/notifications/pending_actions.dart';
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
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  PendingActions queue() => PendingActions();

  test('a press survives being written down and read back', () async {
    await queue().add(const PendingAction(
      actionId: NotificationActions.deleteId,
      messageId: 'a:INBOX#42',
    ));

    final waiting = await queue().take();

    expect(waiting, hasLength(1));
    expect(waiting.single.actionId, NotificationActions.deleteId);
    expect(waiting.single.messageId, 'a:INBOX#42');
    expect(waiting.single.typed, isNull);
  });

  test('what was typed into a reply comes back with it', () async {
    await queue().add(const PendingAction(
      actionId: NotificationActions.replyId,
      messageId: 'a:INBOX#42',
      typed: 'Ten works.',
    ));

    expect((await queue().take()).single.typed, 'Ten works.');
  });

  test('two presses both wait their turn', () async {
    await queue().add(const PendingAction(
      actionId: NotificationActions.deleteId,
      messageId: 'a:INBOX#1',
    ));
    await queue().add(const PendingAction(
      actionId: NotificationActions.deleteId,
      messageId: 'a:INBOX#2',
    ));

    final waiting = await queue().take();

    expect(waiting.map((a) => a.messageId), ['a:INBOX#1', 'a:INBOX#2']);
  });

  test('taking it empties it, so nothing is done twice', () async {
    // The worker and the app both drain this. Doing a delete twice is worse
    // than not doing it, so whoever gets there first takes the lot.
    await queue().add(const PendingAction(
      actionId: NotificationActions.deleteId,
      messageId: 'a:INBOX#42',
    ));

    expect(await queue().take(), hasLength(1));
    expect(await queue().take(), isEmpty);
  });

  test('an empty queue is empty rather than an error', () async {
    expect(await queue().take(), isEmpty);
  });

  test('a corrupted record is dropped, not carried around', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      PendingActions.key: 'not json at all',
    });

    expect(await queue().take(), isEmpty);
  });

  test('a record missing what it needs is ignored', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      PendingActions.key:
          '[{"action":"mailtree.delete"},{"action":"mailtree.delete",'
              '"message":"a:INBOX#7"}]',
    });

    final waiting = await queue().take();

    expect(waiting, hasLength(1));
    expect(waiting.single.messageId, 'a:INBOX#7');
  });
}
