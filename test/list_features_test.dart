import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/display_settings.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/message_move.dart';
import 'package:myemail/domain/row_format.dart';
import 'package:myemail/state/display_providers.dart';
import 'package:myemail/state/folder_tree.dart' show kUnifiedInboxId;
import 'package:myemail/state/list_filter.dart';
import 'package:myemail/state/message_providers.dart';
import 'package:myemail/state/pinned_messages.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/row_formats.dart';
import 'package:myemail/ui/messages/message_tile.dart';
import 'package:myemail/ui/shell/app_shell.dart';

import 'fakes/fake_webview.dart';

/// The list as Outlook draws it: To in Sent, the All / Unread and Filter
/// bar, pins, conditional formats, your replies inside threads, and when an
/// opened message counts as read.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  const inbox = 'acct-personal:INBOX';
  const sent = 'acct-personal:[Gmail]/Sent Mail';

  late _Engine engine;
  late ProviderContainer c;

  setUp(() => engine = _Engine());

  Future<void> pump(
    WidgetTester tester, {
    String folder = inbox,
    Size size = const Size(400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    c = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pumpAndSettle();
    c.read(selectedFolderIdProvider.notifier).select(folder);
    await tester.pumpAndSettle();
  }

  List<MailMessage> rows(WidgetTester tester) => [
        for (final t in tester.widgetList<MessageTile>(find.byType(MessageTile)))
          t.message,
      ];

  testWidgets('a row in Sent says who it went to', (tester) async {
    await pump(tester, folder: sent);
    final first = rows(tester).first;
    expect(first.from.email, 'me@example.com', reason: 'the sample sends as me');
    expect(find.textContaining('To: ${first.to.first.display}'), findsWidgets);
  });

  testWidgets('Unread leaves the unread rows, and adds what the server found',
      (tester) async {
    await pump(tester);
    // The whole list, not only the rows on screen: the newest are unread.
    List<MailMessage> listed() => c.read(sortedMessagesProvider(inbox));
    expect(listed().any((m) => m.isRead), isTrue);

    await tester.tap(find.text('Unread'));
    await tester.pumpAndSettle();

    expect(listed(), isNotEmpty);
    expect(listed().every((m) => !m.isRead), isTrue);
    expect(find.text('Older unread, only on the server'), findsOneWidget,
        reason: 'a message the list never held, from filterMessages');

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(listed().any((m) => m.isRead), isTrue);
    expect(find.text('Older unread, only on the server'), findsNothing);
  });

  testWidgets('Unread on All Inboxes: opening a message does not search '
      'every Inbox on the server again', (tester) async {
    // Each message opened under Unread is marked read. The list's copy of
    // it is the newer word about it, so what the server found is still
    // good; it was asked for again all the same, every Inbox, on every
    // message opened.
    await pump(tester, folder: kUnifiedInboxId, size: const Size(1400, 900));
    c
        .read(listFiltersProvider.notifier)
        .set(kUnifiedInboxId, MessageFilter.unread);
    await tester.pumpAndSettle();
    final asked = engine.filtered.length;
    expect(asked, greaterThan(1), reason: 'every account has an Inbox');

    // Messages the list holds, as reading down it opens them.
    final held = {
      for (final m in c.read(messagesProvider(kUnifiedInboxId)).value!) m.id,
    };
    String? before;
    for (var i = 0; i < 2; i++) {
      final unread = rows(tester).firstWhere((m) =>
          !m.isRead &&
          held.contains(m.id) &&
          m.id != c.read(selectedMessageIdProvider));
      await tester.tap(find.byKey(ValueKey('tile:${unread.id}')));
      // The sample engine takes its time, as a server does.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(engine.readMarked, contains(unread.id));
      // The one read before, left for this one, is read: no longer shown.
      if (before != null) {
        expect(c.read(sortedMessagesProvider(kUnifiedInboxId)).map((m) => m.id),
            isNot(contains(before)));
      }
      before = unread.id;
    }

    expect(engine.filtered, hasLength(asked));
  });

  testWidgets('Unread: a message read here stays away once the list no '
      'longer holds it', (tester) async {
    // The list holds the newest page of the folder, and new mail pushes
    // the rest out of it. What the server found for the filter was from
    // before the message was read, and drew it again from there, bold.
    await pump(tester, size: const Size(1400, 900));
    c.read(listFiltersProvider.notifier).set(inbox, MessageFilter.unread);
    await tester.pumpAndSettle();
    final held = c.read(messagesProvider(inbox)).value!;
    final last = held.lastWhere((m) => !m.isRead);
    List<String> shown() =>
        [for (final m in c.read(sortedMessagesProvider(inbox))) m.id];

    Future<void> open(String id) async {
      c.read(selectedMessageIdProvider.notifier).select(id);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    }

    await open(last.id);
    expect(engine.readMarked, contains(last.id));
    await open(held.firstWhere((m) => !m.isRead && m.id != last.id).id);
    expect(shown(), isNot(contains(last.id)));

    // New mail, enough to push it out of what the list holds, and the
    // minute's refresh.
    for (var i = held.indexOf(last); i < held.length; i++) {
      engine.deliver(inbox);
    }
    c.read(listRefreshProvider.notifier).ping();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(c.read(messagesProvider(inbox)).value!.map((m) => m.id),
        isNot(contains(last.id)),
        reason: 'pushed out of what the list holds');
    expect(shown(), isNot(contains(last.id)));
  });

  testWidgets('a pinned message heads the list, under Pinned', (tester) async {
    await pump(tester);
    final chosen = rows(tester)[3];

    c.read(pinnedMessagesProvider.notifier).setPinned([chosen.id], true);
    await tester.pumpAndSettle();

    expect(rows(tester).first.id, chosen.id);
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
  });

  testWidgets('a conditional format colours its rows', (tester) async {
    await pump(tester);
    final first = rows(tester).first;
    c.read(rowFormatsProvider.notifier).save(RowFormat(
          id: 'r1',
          condition: RowCondition.from,
          text: first.from.email,
          colour: RowColour.red,
        ));
    await tester.pumpAndSettle();

    final sender = tester.widget<Text>(
      find.descendant(
        of: find.byType(MessageTile).first,
        matching: find.textContaining(first.from.email),
      ),
    );
    expect(sender.style?.color, RowColour.red.light);
  });

  testWidgets('your reply from Sent shows inside the thread it answers',
      (tester) async {
    await pump(tester);
    final answered = rows(tester).first;
    engine.sentReply = MailMessage(
      id: '$sent#9001',
      accountId: 'acct-personal',
      folderId: sent,
      uid: 9001,
      subject: 'Re: ${answered.subject}',
      preview: 'My answer',
      from: const MailAddress(email: 'me@example.com', name: 'Me'),
      to: [answered.from],
      date: answered.date.add(const Duration(minutes: 5)),
      isRead: true,
    );
    c.read(displayProvider.notifier).setConversations(true);
    await tester.pumpAndSettle();

    await tester.tap(find.text(answered.subject).first);
    await tester.pumpAndSettle();

    final sentName = c.read(folderIndexProvider)[sent]!.displayName;
    expect(find.text(sentName), findsOneWidget,
        reason: 'the reply carries the folder it is in');
    expect(rows(tester).any((m) => m.id == engine.sentReply!.id), isTrue);
  });

  // Your reply from Sent is drawn inside the thread it answers with no
  // checkbox: nothing done to the thread reaches it. Ctrl+A and Space
  // ticked it all the same, unseen. Such a tick came to nothing until
  // 3.13.1 looked ticks up in everything drawn, and from then Delete took
  // the reply out of Sent with the rest.

  /// The Inbox with its first thread open and a reply of yours from Sent
  /// drawn inside it: the message answered, and the reply.
  Future<(MailMessage, MailMessage)> pumpWithReply(WidgetTester tester) async {
    await pump(tester);
    final answered = rows(tester).first;
    final reply = engine.sentReply = MailMessage(
      id: '$sent#9001',
      accountId: 'acct-personal',
      folderId: sent,
      uid: 9001,
      subject: 'Re: ${answered.subject}',
      preview: 'My answer',
      from: const MailAddress(email: 'me@example.com', name: 'Me'),
      to: [answered.from],
      date: answered.date.add(const Duration(minutes: 5)),
      isRead: true,
    );
    c.read(displayProvider.notifier).setConversations(true);
    await tester.pumpAndSettle();
    await tester.tap(find.text(answered.subject).first);
    await tester.pumpAndSettle();
    expect(rows(tester).any((m) => m.id == reply.id), isTrue);
    return (answered, reply);
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+A does not tick your reply from Sent, and Delete leaves '
      'it there', (tester) async {
    final (answered, reply) = await pumpWithReply(tester);
    c.read(selectedMessageIdProvider.notifier).select(answered.id);
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.keyA, control: true);
    final ticked = c.read(selectedMessageIdsProvider);
    expect(ticked, contains(answered.id));
    expect(ticked, isNot(contains(reply.id)));

    await press(tester, LogicalKeyboardKey.delete);
    expect(engine.deleted, contains(answered.id));
    expect(engine.deleted, isNot(contains(reply.id)));
  });

  testWidgets('Space on your reply from Sent ticks nothing', (tester) async {
    final (_, reply) = await pumpWithReply(tester);
    c.read(selectedMessageIdProvider.notifier).select(reply.id);
    await tester.pumpAndSettle();

    await press(tester, LogicalKeyboardKey.space);

    expect(c.read(selectedMessageIdsProvider), isEmpty);
  });

  for (final control in [false, true]) {
    final how = control ? 'Ctrl+D' : 'Delete';
    testWidgets('a tick on your reply from Sent and nothing else: $how '
        'takes neither it nor the message open', (tester) async {
      final (answered, reply) = await pumpWithReply(tester);
      c.read(selectedMessageIdProvider.notifier).select(answered.id);
      c.read(selectedMessageIdsProvider.notifier).addAll([reply.id]);
      await tester.pumpAndSettle();

      await press(
        tester,
        control ? LogicalKeyboardKey.keyD : LogicalKeyboardKey.delete,
        control: control,
      );

      expect(engine.deleted, isEmpty);
      expect(
        find.text('None of the ticked messages is in the list now.'),
        findsOneWidget,
      );
    });
  }

  testWidgets('After 5 seconds: opened and left before then, it stays unread',
      (tester) async {
    await pump(tester);
    c.read(displayProvider.notifier).setMarkRead(MarkReadWhen.afterDelay);
    await tester.pumpAndSettle();
    final unread = rows(tester).firstWhere((m) => !m.isRead);

    await tester.tap(find.text(unread.subject).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(engine.readMarked, isEmpty);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(engine.readMarked.toSet(), {unread.id});
  });
}

/// The sample engine, with one message only the server's filter finds, a
/// reply of yours in Sent when a test puts one there, and a record of what
/// was marked read and what was deleted.
class _Engine extends SampleMailEngine {
  MailMessage? sentReply;
  final readMarked = <String>[];
  final deleted = <String>[];

  /// The folders the server was searched in for a filter, once a search.
  final filtered = <String>[];

  @override
  Future<List<MessageMove>> deleteMessages(List<String> messageIds) {
    deleted.addAll(messageIds);
    return super.deleteMessages(messageIds);
  }

  @override
  Future<List<MailMessage>> filterMessages(
    String folderId,
    MessageFilter filter, {
    int limit = 100,
  }) async {
    filtered.add(folderId);
    final found = await super.filterMessages(folderId, filter, limit: limit);
    if (filter != MessageFilter.unread) return found;
    return [
      ...found,
      MailMessage(
        id: '$folderId#99999',
        accountId: folderId.split(':').first,
        folderId: folderId,
        uid: 99999,
        subject: 'Older unread, only on the server',
        preview: '',
        from: const MailAddress(email: 'old@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime.now().add(const Duration(minutes: 1)),
        isRead: false,
      ),
    ];
  }

  @override
  Future<List<MailMessage>> cachedMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final reply = sentReply;
    if (reply != null && folderId == reply.folderId) return [reply];
    return _withArrived(folderId, offset, limit,
        await super.cachedMessages(folderId, offset: offset, limit: limit));
  }

  @override
  Future<List<MailMessage>> loadMessages(
    String folderId, {
    int offset = 0,
    int limit = 50,
  }) async =>
      _withArrived(folderId, offset, limit,
          await super.loadMessages(folderId, offset: offset, limit: limit));

  /// New mail, newest first, by folder: see [deliver].
  final _arrived = <String, List<MailMessage>>{};

  /// A new unread message on top of [folderId], which pushes the oldest of
  /// a page out of it, as new mail does.
  void deliver(String folderId) {
    final list = _arrived[folderId] ??= [];
    final uid = 800000 + list.length;
    list.insert(
      0,
      MailMessage(
        id: MailMessage.idFor(folderId, uid),
        accountId: folderId.split(':').first,
        folderId: folderId,
        uid: uid,
        subject: 'Just arrived $uid',
        preview: '',
        from: const MailAddress(email: 'dana@example.com'),
        to: const [MailAddress(email: 'me@example.com')],
        date: DateTime.now(),
      ),
    );
  }

  List<MailMessage> _withArrived(
    String folderId,
    int offset,
    int limit,
    List<MailMessage> page,
  ) {
    final arrived = _arrived[folderId];
    if (arrived == null || offset > 0) return page;
    return [...arrived, ...page].take(limit).toList();
  }

  @override
  Future<void> setRead(String messageId, bool isRead) async {
    if (isRead) readMarked.add(messageId);
    return super.setRead(messageId, isRead);
  }

  @override
  Future<void> setMessagesRead(List<String> messageIds, bool isRead) async {
    if (isRead) readMarked.addAll(messageIds);
    return super.setMessagesRead(messageIds, isRead);
  }
}
