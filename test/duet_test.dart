import 'dart:async';
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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// A copy of the device's settings, read once as the app and the worker
/// each read theirs. Set up [SharedPreferencesAsyncPlatform.instance]
/// first.
Future<UiStateStore> _copy() async => PrefsUiStateStore(
      await SharedPreferencesWithCache.create(
        cacheOptions: const SharedPreferencesWithCacheOptions(),
      ),
    );

/// Secrets in memory, whose writes wait for [gate] while there is one.
class _HeldSecrets extends MemoryCredentialStore {
  Completer<void>? gate;

  @override
  Future<void> writeSecret(String accountId, String secret) async {
    await gate?.future;
    await super.writeSecret(accountId, secret);
  }
}

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

    DuetUploader uploader([UiStateStore? over]) => DuetUploader(
          engine: engine,
          ui: over ?? ui,
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

    /// The accounts the requests from the [from]th on took off the
    /// connector, and those they sent to it.
    ({List<String> cleared, List<String> sent}) since(int from) {
      final bodies = [
        for (var i = from; i < requests.length; i++) body(i),
      ];
      String keyOf(Map<String, Object?> b) => '${(b['account'] as Map)['key']}';
      return (
        cleared: [for (final b in bodies) if (b['clear'] == true) keyOf(b)],
        sent: [for (final b in bodies) if (b['clear'] != true) keyOf(b)],
      );
    }

    test('a removed account is taken off the connector', () async {
      // Ticked when it was removed: nothing ever cleared it, and Duet went
      // on reading that Inbox.
      await switchOn(const DuetSettings(
        enabled: true,
        accounts: {'acct-personal', 'acct-side'},
      ));
      await uploader().run();
      expect(since(0).sent, unorderedEquals(['acct-personal', 'acct-side']));
      await engine.removeAccount('acct-side');

      final from = requests.length;
      await uploader().run(force: true);
      expect(since(from).cleared, ['acct-side']);
      expect(since(from).sent, ['acct-personal']);
      final after = requests.length;
      await uploader().run(force: true);
      expect(since(after).cleared, isEmpty, reason: 'cleared once');
    });

    test('switched off, what was sent is taken off the connector', () async {
      await switchOn(const DuetSettings(
        enabled: true,
        accounts: {'acct-personal', 'acct-side'},
      ));
      await uploader().run();
      await ui.writeString(
        UiStateKeys.duet,
        const DuetSettings(
          enabled: false,
          accounts: {'acct-personal', 'acct-side'},
        ).toJson(),
      );

      // At the next pass, with no Send now.
      now = now.add(const Duration(minutes: 6));
      final from = requests.length;
      final off = await uploader().run();
      expect(
        since(from).cleared,
        unorderedEquals(['acct-personal', 'acct-side']),
      );
      expect(since(from).sent, isEmpty);
      expect(off.line, 'Cleared from your connector');

      final after = requests.length;
      expect((await uploader().run(force: true)).ran, isFalse,
          reason: 'nothing left on the connector');
      expect(requests, hasLength(after));
    });

    test('Send everything again still clears an account unticked', () async {
      // It forgot every account sent, so one unticked just before stayed
      // on the connector for good.
      await switchOn(const DuetSettings(
        enabled: true,
        accounts: {'acct-personal', 'acct-side'},
      ));
      await uploader().run();
      await ui.writeString(
        UiStateKeys.duet,
        const DuetSettings(enabled: true, accounts: {'acct-personal'}).toJson(),
      );

      await uploader().forgetSent();
      final from = requests.length;
      await uploader().run(force: true);
      expect(since(from).cleared, ['acct-side']);
      expect(since(from).sent, ['acct-personal']);
      expect(
        (body(requests.length - 1)['messages'] as List),
        hasLength(DuetUploader.perPass),
        reason: 'the newest go again',
      );
    });

    group('a pass that would change nothing on the connector (#185)', () {
      // Each upload rewrites the account's file in the connector's Blob
      // store, and a pass every five minutes with nothing new could use up
      // the store's monthly allowance.

      /// The next pass, [after] the one before.
      Future<DuetResult> later([Duration after = const Duration(minutes: 6)]) {
        now = now.add(after);
        return uploader().run();
      }

      /// A keep account switched on and its newest messages all sent: the
      /// first pass sends twenty, the next the other ten.
      Future<void> allSent() async {
        await switchOn(
            const DuetSettings(enabled: true, accounts: {'acct-personal'}));
        await uploader().run();
        await later();
        expect(requests, hasLength(2));
      }

      test('a keep account with nothing new is not sent again until a few '
          'hours have passed', () async {
        await allSent();
        final quiet = await later();
        expect(requests, hasLength(2), reason: 'nothing new, the same Inbox');
        expect(quiet.ran, isTrue);
        expect(quiet.sent, 0);
        expect(quiet.line, 'Up to date');
        final kept = jsonDecode(ui.readString(UiStateKeys.duetStatus)!) as Map;
        expect(kept['line'], 'Up to date');
        expect(kept['ok'], isTrue);
        await later(const Duration(hours: 1));
        expect(requests, hasLength(2));

        // Sent all the same every few hours, so the connector's copy
        // cannot drift from the device's for long.
        await later(DuetUploader.resendAfter);
        expect(requests, hasLength(3));
        expect(body(2)['messages'], isEmpty);
        expect((body(2)['keep'] as List).toSet(),
            (body(1)['keep'] as List).toSet());
        await later();
        expect(requests, hasLength(3));
      });

      test('Send now and Send everything again always send', () async {
        await allSent();
        await uploader().run(force: true);
        expect(requests, hasLength(3), reason: 'Send now');
        expect(body(2)['messages'], isEmpty);
        await uploader().forgetSent();
        await uploader().run(force: true);
        expect(requests, hasLength(4), reason: 'Send everything again');
        expect(body(3)['messages'] as List, hasLength(DuetUploader.perPass));
      });

      test('a message gone from the Inbox still leaves the connector at the '
          'next pass', () async {
        await allSent();
        await later();
        expect(requests, hasLength(2));
        final gone = (body(1)['keep'] as List).first as String;
        await engine.deleteMessages([gone]);
        await later();
        expect(requests, hasLength(3));
        expect(body(2)['keep'] as List, isNot(contains(gone)));
      });

      test('a read-once account is sent every pass, as it was, so what is '
          'past its day goes from the connector as soon as before', () async {
        await allSent();
        await switchOn(const DuetSettings(
          enabled: true,
          accounts: {'acct-personal'},
          readOnce: {'acct-personal'},
        ));
        await later();
        await later();
        expect(requests, hasLength(4));
        expect(body(3)['messages'], isEmpty);
        expect((body(3)['account'] as Map)['policy'], 'readOnce');

        // Back to keep, it is sent: the connector last took it as
        // read-once, whatever it took before that.
        await switchOn(
            const DuetSettings(enabled: true, accounts: {'acct-personal'}));
        await later();
        expect(requests, hasLength(5));
        expect((body(4)['account'] as Map)['policy'], 'keep');
      });

      test('a new connector address is sent to at the next pass', () async {
        await allSent();
        await switchOn(const DuetSettings(
          enabled: true,
          server: 'https://other.example',
          accounts: {'acct-personal'},
        ));
        await later();
        expect(requests, hasLength(3));
        expect(requests.last.url.host, 'other.example');
      });

      test('one the connector refused is sent again at the next pass',
          () async {
        await allSent();
        status = 500;
        await uploader().run(force: true);
        expect(requests, hasLength(3));
        // It may have been kept before the answer was lost, or not at all:
        // what the connector holds is not known, so it is not assumed.
        status = 200;
        await later();
        expect(requests, hasLength(4));
        await later();
        expect(requests, hasLength(4));
      });
    });

    group('the app and the worker, each with its own copy of the settings',
        () {
      // The worker reads its copy again each pass; the app, kept alive for
      // hours by push, does not, and its copy had none of what the worker
      // sent.
      late UiStateStore app;
      late UiStateStore worker;

      setUp(() async {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        app = await _copy();
        await app.writeString(
          UiStateKeys.duet,
          const DuetSettings(enabled: true, accounts: {'acct-personal'})
              .toJson(),
        );
        worker = await _copy();
        await secrets.writeSecret(
            DuetUploader.keyName, 'KEY1-KEY2-KEY3-KEY4-KEY5-KEY6');
      });

      Set<Object?> idsIn(int i) =>
          {for (final m in (body(i)['messages'] as List).cast<Map>()) m['id']};

      test('what the worker sent is not sent again by the app', () async {
        await uploader(worker).run();
        expect(idsIn(0), hasLength(DuetUploader.perPass));

        now = now.add(const Duration(minutes: 6));
        await uploader(app).run();
        expect(idsIn(1).intersection(idsIn(0)), isEmpty);
      });

      test('sent by the worker a moment ago, the app waits its five minutes',
          () async {
        await uploader(worker).run();
        now = now.add(const Duration(minutes: 2));
        expect((await uploader(app).run()).ran, isFalse);
        expect(requests, hasLength(1));
      });

      test('what the app last sent, the worker knows, and sends nothing new '
          'again (#185)', () async {
        await uploader(app).run();
        now = now.add(const Duration(minutes: 6));
        await uploader(app).run();
        expect(requests, hasLength(2), reason: 'the newest thirty, all sent');

        // The worker's copy was read before either pass.
        now = now.add(const Duration(minutes: 6));
        final quiet = await uploader(worker).run();
        expect(quiet.ran, isTrue);
        expect(requests, hasLength(2));
      });

      group('a Send now while the worker is part way through a pass (#185)',
          () {
        // Each pass wrote back every record it had read at its start, and
        // the last to finish won. A record could then describe an upload
        // the connector did not take last, and the next pass skip an
        // account whose new message had since been deleted: it stayed on
        // the connector for hours, where it used to leave at the next pass.
        late Completer<void> hold;
        late Completer<void> held;
        String? holdOn;

        setUp(() {
          hold = Completer<void>();
          held = Completer<void>();
          holdOn = null;
        });

        /// An uploader whose next upload of [holdOn] waits for [hold],
        /// once the connector has it.
        DuetUploader over(UiStateStore store) => DuetUploader(
              engine: engine,
              ui: store,
              secrets: secrets,
              clock: () => now,
              client: MockClient((request) async {
                requests.add(request);
                final sent = jsonDecode(request.body) as Map;
                if ((sent['account'] as Map)['key'] == holdOn) {
                  holdOn = null;
                  held.complete();
                  await hold.future;
                }
                return http.Response('{}', 200);
              }),
            );

        Future<String> inboxIdOf(String accountId) async =>
            (await engine.cachedFolders(accountId))
                .firstWhere((f) => f.role == FolderRole.inbox)
                .id;

        /// A message off the end of [accountId]'s Inbox.
        Future<void> oneGoneFrom(String accountId) async {
          final inbox = await inboxIdOf(accountId);
          final list = await engine.cachedMessages(inbox, limit: 500);
          await engine.deleteMessages([list.last.id]);
        }

        /// New mail in Personal's Inbox (Side's newest, moved there): its
        /// id there.
        Future<String> arrives() async {
          final side = await inboxIdOf('acct-side');
          final newest = (await engine.cachedMessages(side, limit: 1)).single;
          final moves = await engine.moveMessages(
              [newest.id], await inboxIdOf('acct-personal'));
          return moves.single.movedIds.single;
        }

        /// While the worker is held: new mail, sent by Send now, then
        /// deleted, so Personal's Inbox is as it was before. Its id.
        Future<String> meanwhile(Future<DuetResult> pass) async {
          await held.future;
          final m = await arrives();
          now = now.add(const Duration(seconds: 30));
          await over(app).run(force: true);
          await engine.deleteMessages([m]);
          hold.complete();
          await pass;
          return m;
        }

        /// Personal's uploads from the [from]th request on.
        List<Map<String, Object?>> personal(int from) => [
              for (var i = from; i < requests.length; i++)
                if ((body(i)['account'] as Map)['key'] == 'acct-personal')
                  body(i),
            ];

        test('the worker leaves alone the record of an account it did not '
            'send', () async {
          await app.writeString(
            UiStateKeys.duet,
            const DuetSettings(
              enabled: true,
              accounts: {'acct-personal', 'acct-side'},
            ).toJson(),
          );
          await over(app).run();
          now = now.add(const Duration(minutes: 6));
          await over(app).run();
          // Side has something for the worker to send, and it is held
          // there; Personal it leaves, as nothing changed.
          await oneGoneFrom('acct-side');
          now = now.add(const Duration(minutes: 6));
          holdOn = 'acct-side';
          final m = await meanwhile(over(worker).run());

          now = now.add(const Duration(minutes: 6));
          final from = requests.length;
          await over(app).run();
          expect(personal(from), hasLength(1),
              reason: 'the connector last took it with the new message');
          expect(personal(from).single['keep'] as List, isNot(contains(m)));
        });

        test('an account both passes sent goes again at the next pass',
            () async {
          await over(app).run();
          now = now.add(const Duration(minutes: 6));
          await over(app).run();
          // The worker sends Personal, and is held once the connector has
          // it; Send now's comes after, so the connector keeps that one.
          await oneGoneFrom('acct-personal');
          now = now.add(const Duration(minutes: 6));
          holdOn = 'acct-personal';
          final m = await meanwhile(over(worker).run());

          now = now.add(const Duration(minutes: 6));
          final from = requests.length;
          await over(app).run();
          expect(personal(from), hasLength(1),
              reason: 'which of the two it took last is not known');
          expect(personal(from).single['keep'] as List, isNot(contains(m)));
        });
      });
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
    test('an account removed is unticked, with its shared mailboxes',
        () async {
      // Left ticked, the Settings row went on counting it, and nothing on
      // the screen could untick it: only accounts there now are listed.
      final engine = SampleMailEngine();
      final shared = await engine.addSharedMailbox(
        viaAccountId: 'acct-side',
        emailAddress: 'orders@example.com',
        displayName: 'Orders',
      );
      final ui = MemoryUiStateStore();
      await ui.writeString(
        UiStateKeys.duet,
        DuetSettings(
          enabled: true,
          accounts: {'acct-personal', 'acct-side', shared.id},
          readOnce: {'acct-side'},
        ).toJson(),
      );
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      await c.read(accountsProvider.future);
      expect(c.read(duetSettingsProvider).accounts, hasLength(3));

      await c.read(accountsProvider.notifier).remove('acct-side');

      const left = DuetSettings(enabled: true, accounts: {'acct-personal'});
      expect(c.read(duetSettingsProvider), left);
      expect(DuetSettings.fromJson(ui.readString(UiStateKeys.duet)), left,
          reason: 'kept where the background reads it');
    });

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

    testWidgets("the worker's last pass is the one it says", (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final app = await _copy();
      final worker = await _copy();
      await worker.writeString(
        UiStateKeys.duetStatus,
        jsonEncode({
          'at': DateTime(2026, 11, 14, 9, 5).toIso8601String(),
          'line': 'Sent 3 messages',
          'ok': true,
        }),
      );
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(app),
        credentialStoreProvider.overrideWithValue(MemoryCredentialStore()),
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: DuetScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Sent 3 messages'), findsOneWidget);
    });

    testWidgets('a new upload key typed is used at the next pass, not hours '
        'later (#185)', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // What the connector last took, it took under the old key.
      final ui = MemoryUiStateStore();
      await ui.writeString(
        UiStateKeys.duetPosted,
        jsonEncode({
          'acct-personal': {
            'digest': 'x',
            'at': DateTime(2026, 11, 15, 9).toIso8601String(),
          },
        }),
      );
      final secrets = _HeldSecrets();
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        credentialStoreProvider.overrideWithValue(secrets),
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: DuetScreen()),
      ));
      await tester.pumpAndSettle();
      expect(ui.readString(UiStateKeys.duetPosted), isNotNull,
          reason: 'opening the screen forgets nothing');

      await tester.enterText(
          find.byKey(const ValueKey('duet-key')), 'abcd-efgh-jkmn-pqrs-tuvw-xyz2');
      await tester.pumpAndSettle();
      expect(ui.readString(UiStateKeys.duetPosted), isNull);
      expect(await tester.runAsync(() => secrets.readSecret(DuetUploader.keyName)),
          'abcd-efgh-jkmn-pqrs-tuvw-xyz2');

      // The screen closed while the key is still being kept: forgotten all
      // the same, and nothing thrown.
      await ui.writeString(UiStateKeys.duetPosted, '{}');
      secrets.gate = Completer<void>();
      await tester.enterText(
          find.byKey(const ValueKey('duet-key')), 'bcde-fghj-kmnp-qrst-uvwx-yz23');
      await tester.pumpWidget(const SizedBox());
      secrets.gate!.complete();
      await tester.pumpAndSettle();
      expect(ui.readString(UiStateKeys.duetPosted), isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
