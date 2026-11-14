import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/mail_engine.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/draft.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/unsubscribe.dart';
import 'package:myemail/ui/messages/unsubscribe_link.dart';

/// Unsubscribe: one tap off a mailing list, made from the headers the list
/// puts on its mail (RFC 2369 and RFC 8058).
void main() {
  group('the headers', () {
    test('one click, where the list allows it over https', () {
      final options = UnsubscribeOptions.parse(
        '<mailto:leave@list.example.com?subject=unsubscribe>, '
            '<https://list.example.com/u?id=42>',
        'List-Unsubscribe=One-Click',
      )!;
      expect(options.oneClick, Uri.parse('https://list.example.com/u?id=42'));
      expect(options.mailto!.path, 'leave@list.example.com');
      expect(options.way, UnsubscribeWay.oneClick);
    });

    test('folded across lines, even inside the brackets', () {
      final options = UnsubscribeOptions.parse(
        '<https://list.example.com/unsub\r\n scribe?id=1>',
        null,
      )!;
      expect(options.web, Uri.parse('https://list.example.com/unsubscribe?id=1'));
      expect(options.oneClick, isNull, reason: 'no List-Unsubscribe-Post');
      expect(options.way, UnsubscribeWay.page);
    });

    test('the email before the page; never one click over plain http', () {
      final options = UnsubscribeOptions.parse(
        '<http://list.example.com/u>, <MAILTO:leave@list.example.com>',
        'List-Unsubscribe=One-Click',
      )!;
      expect(options.oneClick, isNull);
      expect(options.way, UnsubscribeWay.email);
    });

    test('an email to more than one address is no way to leave', () {
      expect(
        UnsubscribeOptions.parse(
          '<mailto:leave@list.example.com,boss@hadco.example>',
          null,
        ),
        isNull,
      );
    });

    test('nothing to act on is no button', () {
      expect(UnsubscribeOptions.parse(null, null), isNull);
      expect(UnsubscribeOptions.parse('<ftp://x>, garbage', null), isNull);
    });

    test('not in Junk, Sent or Drafts, and not on your own mail', () {
      final m = MailMessage(
        id: 'a:INBOX#1',
        accountId: 'a',
        folderId: 'a:INBOX',
        uid: 1,
        subject: 'News',
        from: const MailAddress(email: 'news@shop.example.com'),
        to: const [],
        date: DateTime(2026, 10, 1),
        preview: '',
      );
      bool offered(FolderRole role, {Set<String> own = const {}}) =>
          offersUnsubscribe(m, role: role, ownAddresses: own);
      expect(offered(FolderRole.inbox), isTrue);
      expect(offered(FolderRole.user), isTrue);
      expect(offered(FolderRole.junk), isFalse);
      expect(offered(FolderRole.sent), isFalse);
      expect(offered(FolderRole.drafts), isFalse);
      expect(
        offered(FolderRole.inbox, own: {'news@shop.example.com'}),
        isFalse,
      );
    });
  });

  group('leaving', () {
    late _Engine engine;
    late ProviderContainer c;
    final asked = <Uri>[];
    final opened = <Uri>[];
    var status = 200;

    final message = MailMessage(
      id: 'acct-personal:INBOX#1',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 1,
      subject: 'News',
      from: const MailAddress(email: 'news@shop.example.com', name: 'Shop'),
      to: const [],
      date: DateTime(2026, 10, 1),
      preview: '',
    );

    setUp(() {
      asked.clear();
      opened.clear();
      status = 200;
      engine = _Engine();
      c = ProviderContainer(
        overrides: [
          mailEngineProvider.overrideWithValue(engine),
          oneClickUnsubscribeProvider.overrideWithValue((uri) async {
            asked.add(uri);
            return status;
          }),
          openInBrowserProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return true;
          }),
        ],
      );
      addTearDown(c.dispose);
    });

    final all = UnsubscribeOptions.parse(
      '<mailto:leave@shop.example.com?subject=Remove%20me>, '
          '<https://shop.example.com/u>',
      'List-Unsubscribe=One-Click',
    )!;

    test('one click, and the list is remembered as left', () async {
      expect(await unsubscribe(c.read, message, all), UnsubscribeOutcome.done);
      expect(asked, [Uri.parse('https://shop.example.com/u')]);
      expect(engine.sent, isEmpty);
      expect(c.read(unsubscribedProvider), contains(unsubscribeKey(all)));
    });

    test('a one-click address that refuses falls to the email', () async {
      status = 500;
      expect(await unsubscribe(c.read, message, all), UnsubscribeOutcome.sent);
      final draft = engine.sent.single;
      expect(draft.accountId, 'acct-personal');
      expect(draft.to.single.email, 'leave@shop.example.com');
      expect(draft.subject, 'Remove me');
      expect(draft.kind, ComposeKind.newMessage);
    });

    test("the email goes to the link's own address alone, a line long",
        () async {
      // The list writes the link, and Ron's account sends what it says.
      final greedy = UnsubscribeOptions.parse(
        '<mailto:leave@shop.example.com?to=boss@hadco.example'
            '&to=x@y.example&cc=c@z.example&bcc=d@z.example'
            '&subject=Remove%20me%0D%0ABuy%20now'
            '&body=unsubscribe%2042%0D%0A${'Buy%20now%20' * 40}>',
        null,
      )!;
      expect(
        await unsubscribe(c.read, message, greedy),
        UnsubscribeOutcome.sent,
      );
      final draft = engine.sent.single;
      expect([for (final a in draft.to) a.email], ['leave@shop.example.com']);
      expect(draft.cc, isEmpty);
      expect(draft.bcc, isEmpty);
      expect(draft.subject, 'Remove me');
      expect(draft.htmlBody, '<p>unsubscribe 42</p>');
    });

    test('only a page: it opens, to be finished there', () async {
      final page = UnsubscribeOptions.parse('<https://shop.example.com/p>', null)!;
      expect(await unsubscribe(c.read, message, page), UnsubscribeOutcome.opened);
      expect(opened, [Uri.parse('https://shop.example.com/p')]);
      expect(c.read(unsubscribedProvider), isEmpty,
          reason: 'not left until the page is finished');
    });
  });

  testWidgets('beside the sender of a list message, with what it will do',
      (tester) async {
    final engine = _Engine();
    final container = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        oneClickUnsubscribeProvider.overrideWithValue((_) async => 200),
      ],
    );
    addTearDown(container.dispose);
    final m = MailMessage(
      id: 'acct-personal:INBOX#1',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 1,
      subject: 'News',
      from: const MailAddress(email: 'news@shop.example.com', name: 'Shop'),
      to: const [],
      date: DateTime(2026, 10, 1),
      preview: '',
    );
    engine.unsubscribe[m.id] = UnsubscribeOptions.parse(
      '<https://shop.example.com/u>',
      'List-Unsubscribe=One-Click',
    )!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: Center(child: UnsubscribeLink(message: m))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('unsubscribe')));
    await tester.pumpAndSettle();
    expect(find.textContaining('MyEmail tells them now'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Unsubscribe'));
    await tester.pumpAndSettle();
    expect(find.text('Unsubscribed'), findsOneWidget);
  });

  group('leaving the message as soon as the dialog closes', () {
    // Delete, Back or the next message takes the link away, its ref with
    // it, while the list is still being told.
    final m = MailMessage(
      id: 'acct-personal:INBOX#1',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 1,
      subject: 'News',
      from: const MailAddress(email: 'news@shop.example.com', name: 'Shop'),
      to: const [],
      date: DateTime(2026, 10, 1),
      preview: '',
    );
    late _Engine engine;
    late Completer<int> answer;
    late ProviderContainer container;
    late ValueNotifier<bool> open;

    ScaffoldMessengerState messenger(WidgetTester tester) =>
        ScaffoldMessenger.of(tester.element(find.byType(Scaffold)));

    /// A bar of someone else's, a delete's with its Undo, as it puts one
    /// up: over whatever is showing.
    Future<void> deleted(WidgetTester tester) async {
      messenger(tester)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          duration: Duration(seconds: 5),
          content: Text('Deleted'),
        ));
      await tester.pumpAndSettle();
    }

    Future<UnsubscribeOptions> confirm(
      WidgetTester tester,
      String header, {
      String? post,
      bool barUp = false,
    }) async {
      engine = _Engine()..gate = Completer<void>();
      answer = Completer<int>();
      container = ProviderContainer(
        overrides: [
          uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
          mailEngineProvider.overrideWithValue(engine),
          oneClickUnsubscribeProvider.overrideWithValue((_) => answer.future),
          openInBrowserProvider.overrideWithValue((_) async => true),
        ],
      );
      addTearDown(container.dispose);
      final options = UnsubscribeOptions.parse(header, post)!;
      engine.unsubscribe[m.id] = options;
      open = ValueNotifier(true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: open,
                builder: (_, isOpen, _) => isOpen
                    ? Center(child: UnsubscribeLink(message: m))
                    : const SizedBox(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (barUp) await deleted(tester);
      await tester.tap(find.byKey(const ValueKey('unsubscribe')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Unsubscribe'));
      await tester.pumpAndSettle();
      return options;
    }

    testWidgets("Delete straight after: the delete's bar stays its time, "
        'and how it went comes after it', (tester) async {
      await confirm(tester, '<mailto:leave@shop.example.com>');
      expect(find.text('Unsubscribing from Shop…'), findsOneWidget);
      await deleted(tester);

      engine.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Deleted'), findsOneWidget);
      const sent = 'Unsubscribe email sent to Shop. It can take them a few '
          'days.';
      expect(find.text(sent), findsNothing);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Deleted'), findsNothing);
      expect(find.text(sent), findsOneWidget);
    });

    testWidgets('a bar already up is not cut short either', (tester) async {
      await confirm(tester, '<mailto:leave@shop.example.com>', barUp: true);
      expect(find.text('Deleted'), findsOneWidget);

      engine.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Deleted'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(
        find.text('Unsubscribe email sent to Shop. It can take them a few '
            'days.'),
        findsOneWidget,
      );
      expect(find.text('Unsubscribing from Shop…'), findsNothing);
    });

    testWidgets('says it is under way, and is not offered again meanwhile',
        (tester) async {
      await confirm(tester, '<mailto:leave@shop.example.com>');
      expect(find.text('Unsubscribing from Shop…'), findsOneWidget);
      expect(find.text('Unsubscribing…'), findsOneWidget);
      expect(find.byKey(const ValueKey('unsubscribe')), findsNothing);

      engine.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Unsubscribed'), findsOneWidget);
    });

    testWidgets('by email: the email went, and the bar says so',
        (tester) async {
      final options = await confirm(
        tester,
        '<mailto:leave@shop.example.com?subject=Remove%20me>',
      );
      open.value = false;
      await tester.pumpAndSettle();

      engine.gate!.complete();
      await tester.pumpAndSettle();
      expect(engine.sent, hasLength(1));
      expect(
        find.text('Unsubscribe email sent to Shop. It can take them a few '
            'days.'),
        findsOneWidget,
      );
      expect(container.read(unsubscribedProvider),
          contains(unsubscribeKey(options)));
    });

    testWidgets('one click: the list took it, and it is remembered as left',
        (tester) async {
      final options = await confirm(
        tester,
        '<https://shop.example.com/u>',
        post: 'List-Unsubscribe=One-Click',
      );
      open.value = false;
      await tester.pumpAndSettle();

      answer.complete(200);
      await tester.pumpAndSettle();
      expect(
        find.text('Unsubscribed from Shop. It can take them a few days.'),
        findsOneWidget,
      );
      expect(container.read(unsubscribedProvider),
          contains(unsubscribeKey(options)));
    });
  });

  testWidgets('by email, the dialog says to whom and what it says',
      (tester) async {
    final engine = _Engine();
    final container = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    final m = MailMessage(
      id: 'acct-personal:INBOX#1',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 1,
      subject: 'News',
      from: const MailAddress(email: 'news@shop.example.com', name: 'Shop'),
      to: const [],
      date: DateTime(2026, 10, 1),
      preview: '',
    );
    engine.unsubscribe[m.id] = UnsubscribeOptions.parse(
      '<mailto:leave@shop.example.com?to=boss@hadco.example'
          '&subject=Remove%20me>',
      null,
    )!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: Center(child: UnsubscribeLink(message: m))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('unsubscribe')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('to leave@shop.example.com, from '),
      findsOneWidget,
    );
    expect(find.textContaining('the subject "Remove me"'), findsOneWidget);
    expect(find.textContaining('boss@'), findsNothing);
  });

  testWidgets('one click with an email behind it: the dialog names the '
      'email too', (tester) async {
    // A one-click address that fails falls to the email, which goes from
    // Ron's account: it is shown before he says yes, not after.
    final engine = _Engine();
    final container = ProviderContainer(
      overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
      ],
    );
    addTearDown(container.dispose);
    final m = MailMessage(
      id: 'acct-personal:INBOX#1',
      accountId: 'acct-personal',
      folderId: 'acct-personal:INBOX',
      uid: 1,
      subject: 'News',
      from: const MailAddress(email: 'news@shop.example.com', name: 'Shop'),
      to: const [],
      date: DateTime(2026, 10, 1),
      preview: '',
    );
    engine.unsubscribe[m.id] = UnsubscribeOptions.parse(
      '<mailto:leave@shop.example.com?subject=Remove%20me>, '
          '<https://shop.example.com/u>',
      'List-Unsubscribe=One-Click',
    )!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: Center(child: UnsubscribeLink(message: m))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('unsubscribe')));
    await tester.pumpAndSettle();
    expect(find.textContaining('MyEmail tells them now'), findsOneWidget);
    expect(
      find.textContaining('to leave@shop.example.com, from '),
      findsOneWidget,
    );
    expect(find.textContaining('the subject "Remove me"'), findsOneWidget);
  });
}

/// The sample engine, keeping what it was asked to send, after [gate]
/// where a test holds the send back.
class _Engine extends SampleMailEngine {
  final sent = <Draft>[];
  Completer<void>? gate;

  @override
  Future<void> sendDraft(Draft draft) async {
    await gate?.future;
    sent.add(draft);
  }
}
