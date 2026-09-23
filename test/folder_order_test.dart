import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';

/// Newest first means by date, in one folder as everywhere else.
void main() {
  test('a message that arrived late sits where its date puts it', () async {
    // A folder comes back in arrival order. A message undone, moved in or
    // delivered late was drawn at the top weeks old, while the unified
    // Inbox and search had it where its date said.
    final engine = _ArrivalOrder([
      _message(9, DateTime(2026, 8, 1)), // moved in today, from August
      _message(8, DateTime(2026, 9, 22)),
      _message(7, DateTime(2026, 9, 21)),
    ]);
    final c = ProviderContainer(overrides: [
      mailEngineProvider.overrideWithValue(engine),
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
    ]);
    addTearDown(c.dispose);

    await c.read(messagesProvider('a:INBOX').future);

    expect(c.read(sortedMessagesProvider('a:INBOX')).map((m) => m.uid),
        [8, 7, 9]);
  });
}

MailMessage _message(int uid, DateTime date) => MailMessage(
      id: 'a:INBOX#$uid',
      accountId: 'a',
      folderId: 'a:INBOX',
      uid: uid,
      subject: 'M$uid',
      from: const MailAddress(email: 'dana@example.com'),
      to: const [],
      date: date,
      preview: '',
    );

/// Hands a folder over highest number first, as the cache does.
class _ArrivalOrder extends SampleMailEngine {
  _ArrivalOrder(this.messages);

  final List<MailMessage> messages;

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      messages;

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      messages;
}
