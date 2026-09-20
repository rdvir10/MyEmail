import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/folder_tree.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/providers.dart';

/// The unified Inbox holds still.
void main() {
  Future<(ProviderContainer, _CountingEngine)> open() async {
    final engine = _CountingEngine();
    final c = ProviderContainer(overrides: [
      mailEngineProvider.overrideWithValue(engine),
      uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
    ]);
    addTearDown(c.dispose);
    await c.read(accountsProvider.future);
    await c.read(foldersProvider.future);
    await c.read(messagesProvider(kUnifiedInboxId).future);
    return (c, engine);
  }

  test('marking a message read does not reload it', () async {
    // The folder counts refresh with every read mark. A list that followed
    // them would resync every account on each arrow key press.
    final (c, engine) = await open();
    final loads = engine.messageLoads;
    final first = c.read(messagesProvider(kUnifiedInboxId)).value!.first;

    await c
        .read(messagesProvider(kUnifiedInboxId).notifier)
        .setRead(first.id, !first.isRead);
    await c.read(foldersProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(engine.messageLoads, loads);
    expect(c.read(messagesProvider(kUnifiedInboxId)).value!.first.id, first.id);
  });

  test('its order is the same every time it is built', () async {
    // Two accounts' mail shares timestamps; sorted on date alone, the rows
    // with equal dates came out in a different order on every rebuild,
    // and the arrow keys landed somewhere else each time.
    final (c, _) = await open();
    final before = c.read(messagesProvider(kUnifiedInboxId)).value!;

    c.invalidate(messagesProvider(kUnifiedInboxId));
    final after = await c.read(messagesProvider(kUnifiedInboxId).future);

    expect(after.map((m) => m.id), before.map((m) => m.id));
    for (var i = 1; i < after.length; i++) {
      expect(after[i].date.isAfter(after[i - 1].date), isFalse);
    }
  });
}

class _CountingEngine extends SampleMailEngine {
  int messageLoads = 0;

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) {
    messageLoads++;
    return super.loadMessages(folderId, offset: offset, limit: limit);
  }
}
