import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myemail/data/auth/oauth_token.dart';
import 'package:myemail/data/credential_store.dart';
import 'package:myemail/data/duet/duet_uploader.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/duet_settings.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:myemail/state/duet_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/settings/duet_screen.dart';

/// MyEmail's half of the connector for Claude (#2): what it sends to the
/// connector, and Settings, Claude (Duet).
void main() {
  test('the settings read back, Hadco read-once at first', () {
    const s = DuetSettings(
      enabled: true,
      accounts: {'a', 'h'},
      readOnce: {'h'},
    );
    expect(DuetSettings.fromJson(s.toJson()), s);
    expect(DuetSettings.fromJson(null), const DuetSettings());
    expect(DuetSettings.fromJson('{nonsense'), const DuetSettings());
    expect(DuetSettings.readOnceByDefault('RDvir@hadco-metal.com'), isTrue);
    expect(DuetSettings.readOnceByDefault('ron@myhomestudio.club'), isFalse);
  });

  group('the uploader', () {
    late SampleMailEngine engine;
    late MemoryUiStateStore ui;
    late MemoryCredentialStore secrets;
    late List<http.Request> requests;
    late int status;
    late DateTime now;

    DuetUploader uploader() => DuetUploader(
          engine: engine,
          ui: ui,
          secrets: secrets,
          clock: () => now,
          client: MockClient((request) async {
            requests.add(request);
            return http.Response(jsonEncode({'stored': 1}), status);
          }),
        );

    Map<String, Object?> body(int i) =>
        (jsonDecode(requests[i].body) as Map).cast<String, Object?>();

    Future<String> inboxOf(String accountId) async {
      final folders = await engine.loadFolders(accountId);
      final inbox = folders.firstWhere((f) => f.role == FolderRole.inbox);
      await engine.loadMessages(inbox.id);
      return inbox.id;
    }

    setUp(() async {
      engine = SampleMailEngine();
      ui = MemoryUiStateStore();
      secrets = MemoryCredentialStore();
      requests = [];
      status = 200;
      now = DateTime.now();
      await inboxOf('acct-personal');
      await inboxOf('acct-side');
    });

    Future<void> switchOn(DuetSettings settings) async {
      await ui.writeString(UiStateKeys.duet, settings.toJson());
      await secrets.writeSecret(DuetUploader.keyName, 'KEY1-KEY2-KEY3-KEY4-KEY5-KEY6');
    }

    test('off, or with no key, nothing is sent', () async {
      expect((await uploader().run()).ran, isFalse);
      await ui.writeString(
        UiStateKeys.duet,
        const DuetSettings(enabled: true, accounts: {'acct-personal'}).toJson(),
      );
      expect((await uploader().run()).ran, isFalse, reason: 'no key yet');
      expect(requests, isEmpty);
    });

    test("a keep account's newest messages, as text, with what its Inbox "
        'holds; each sent once', () async {
      await switchOn(const DuetSettings(enabled: true, accounts: {'acct-personal'}));
      final first = await uploader().run();
      expect(first.ran, isTrue);
      expect(first.sent, DuetUploader.perPass);
      expect(first.line, 'Sent ${DuetUploader.perPass} messages');

      final sent = body(0);
      expect(requests.single.url.path, '/api/upload');
      expect(requests.single.headers['X-MyEmail-Upload-Key'], 'KEY1-KEY2-KEY3-KEY4-KEY5-KEY6');
      expect(sent['account'], {
        'key': 'acct-personal',
        'name': 'Personal',
        'policy': 'keep',
      });
      final messages = (sent['messages'] as List).cast<Map>();
      expect(messages, hasLength(DuetUploader.perPass));
      expect(messages.first.keys,
          containsAll(['id', 'from', 'to', 'date', 'subject', 'text']));
      expect((messages.first['text'] as String), isNotEmpty);
      expect((sent['keep'] as List), isNotEmpty);

      // Too soon for another pass, then forced: the rest of the newest, not
      // the ones already sent.
      expect((await uploader().run()).ran, isFalse, reason: 'every five minutes');
      final again = await uploader().run(force: true);
      final second = (body(1)['messages'] as List).cast<Map>();
      expect(second.map((m) => m['id']).toSet().intersection(
            messages.map((m) => m['id']).toSet(),
          ), isEmpty);
      expect(again.sent, DuetUploader.newest - DuetUploader.perPass);

      // Forgotten, the newest go again.
      await uploader().forgetSent();
      await uploader().run(force: true);
      expect((body(2)['messages'] as List), hasLength(DuetUploader.perPass));
    });

    test('a read-once account: only the last day, and no Inbox list',
        () async {
      await switchOn(const DuetSettings(
        enabled: true,
        accounts: {'acct-side'},
        readOnce: {'acct-side'},
      ));
      await uploader().run();
      final sent = body(0);
      expect((sent['account'] as Map)['policy'], 'readOnce');
      expect(sent.containsKey('keep'), isFalse);
      for (final m in (sent['messages'] as List).cast<Map>()) {
        final date = DateTime.parse(m['date'] as String);
        expect(now.difference(date), lessThan(DuetUploader.readOnceWindow));
      }
    });

    test('an account no longer ticked is taken off the connector', () async {
      await switchOn(const DuetSettings(enabled: true, accounts: {'acct-personal'}));
      await uploader().run();
      await ui.writeString(
        UiStateKeys.duet,
        const DuetSettings(enabled: true, accounts: {'acct-side'}).toJson(),
      );
      await uploader().run(force: true);
      final clear = requests.map((r) => jsonDecode(r.body) as Map).firstWhere(
            (b) => b['clear'] == true,
          );
      expect((clear['account'] as Map)['key'], 'acct-personal');
    });

    test('a refused key or no connection is said, and nothing counted sent',
        () async {
      await switchOn(const DuetSettings(enabled: true, accounts: {'acct-personal'}));
      status = 401;
      final refused = await uploader().run();
      expect(refused.line, 'The connector does not take this upload key.');
      status = 200;
      await uploader().run(force: true);
      expect((body(1)['messages'] as List), hasLength(DuetUploader.perPass),
          reason: 'the refused ones go again');

      final offline = DuetUploader(
        engine: engine,
        ui: ui,
        secrets: secrets,
        clock: () => now,
        client: MockClient((_) async => throw Exception('no network')),
      );
      expect((await offline.run(force: true)).line, 'Could not reach the connector.');
      final kept = jsonDecode(ui.readString(UiStateKeys.duetStatus)!) as Map;
      expect(kept['ok'], isFalse);
    });
  });

  group('Settings, Claude (Duet)', () {
    testWidgets('switched on with a key and an account, Send now sends',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = SampleMailEngine();
      final hadco = (await tester.runAsync(() => engine.addOAuthAccount(
            displayName: 'Hadco',
            emailAddress: 'rdvir@hadco-metal.com',
            provider: MailProvider.outlook,
            token: OAuthToken(
              accessToken: 'a',
              refreshToken: 'r',
              expiresAt: DateTime.utc(2030),
            ),
          )))!;
      await tester.runAsync(() async {
        final folders = await engine.loadFolders('acct-personal');
        await engine.loadMessages(
            folders.firstWhere((f) => f.role == FolderRole.inbox).id);
      });
      final ui = MemoryUiStateStore();
      final secrets = MemoryCredentialStore();
      final requests = <http.Request>[];
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        credentialStoreProvider.overrideWithValue(secrets),
        mailEngineProvider.overrideWithValue(engine),
        duetUploaderProvider.overrideWith((ref) => DuetUploader(
              engine: engine,
              ui: ui,
              secrets: secrets,
              client: MockClient((r) async {
                requests.add(r);
                return http.Response('{}', 200);
              }),
            )),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: DuetScreen()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('duet-on')));
      await tester.enterText(
          find.byKey(const ValueKey('duet-key')), 'abcd-efgh-jkmn-pqrs-tuvw-xyz2');
      await tester.tap(find.byKey(const ValueKey('duet-account:acct-personal')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('duet-once:acct-personal')), findsOneWidget);
      expect(c.read(duetSettingsProvider).readOnce, isEmpty);

      await tester.ensureVisible(find.byKey(ValueKey('duet-account:${hadco.id}')));
      await tester.tap(find.byKey(ValueKey('duet-account:${hadco.id}')));
      await tester.pumpAndSettle();
      expect(c.read(duetSettingsProvider).readOnce, {hadco.id},
          reason: "Hadco's starts read-once");

      expect(await tester.runAsync(() => secrets.readSecret(DuetUploader.keyName)),
          'abcd-efgh-jkmn-pqrs-tuvw-xyz2');
      await tester.ensureVisible(find.byKey(const ValueKey('duet-send')));
      await tester.tap(find.byKey(const ValueKey('duet-send')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pumpAndSettle();

      expect(requests, isNotEmpty);
      expect(find.byKey(const ValueKey('duet-status')), findsOneWidget);
      expect(find.textContaining('Sent'), findsOneWidget);
      expect(DuetSettings.fromJson(ui.readString(UiStateKeys.duet)).enabled, isTrue,
          reason: 'kept where the background reads it');
    });
  });
}
