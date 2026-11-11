import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/graph/graph_profile_api.dart';
import 'package:myemail/data/notifications/mail_notifier.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/password_expiry.dart';
import 'package:myemail/state/password_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/state/sync_providers.dart';
import 'package:myemail/ui/settings/edit_account_screen.dart';

const _work = Account(
  id: 'work',
  displayName: 'Hadco',
  emailAddress: 'me@example.com',
  provider: MailProvider.outlook,
  authMethod: AuthMethod.oauth,
  colorValue: 0,
);
const _shared = Account(
  id: 'info',
  displayName: 'Info',
  emailAddress: 'info@example.com',
  provider: MailProvider.outlook,
  authMethod: AuthMethod.oauth,
  colorValue: 0,
  sharedVia: 'work',
);
const _gmail = Account(
  id: 'home',
  displayName: 'Home',
  emailAddress: 'me@example.org',
  provider: MailProvider.gmail,
  authMethod: AuthMethod.oauth,
  colorValue: 0,
);

/// The sample engine with these accounts, and Microsoft's answer for each.
class _Engine extends SampleMailEngine {
  _Engine(this.ages);

  final Map<String, Object> ages;
  final asked = <String>[];

  @override
  Future<List<Account>> loadAccounts() async => [_work, _shared, _gmail];

  @override
  Future<PasswordAge> passwordAge(String accountId) async {
    asked.add(accountId);
    final age = ages[accountId];
    if (age is PasswordAge) return age;
    if (age != null) throw age;
    return PasswordAge.unknown;
  }
}

void main() {
  group('PasswordExpiry', () {
    final changed = DateTime(2026, 9, 12, 8, 30);

    test('runs out the organisation\'s days after the last change', () {
      final e = PasswordExpiry.of(PasswordAge(lastChanged: changed), 90)!;
      expect(e.expires, DateTime(2026, 12, 11, 8, 30));
      expect(e.daysLeft(DateTime(2026, 11, 10, 23)), 31);
      expect(e.isNear(DateTime(2026, 11, 26)), isFalse);
      expect(e.isNear(DateTime(2026, 11, 27)), isTrue);
    });

    test('says nothing for never, 0 days or no date', () {
      expect(
        PasswordExpiry.of(
            PasswordAge(lastChanged: changed, neverExpires: true), 90),
        isNull,
      );
      expect(PasswordExpiry.of(PasswordAge(lastChanged: changed), 0), isNull);
      expect(PasswordExpiry.of(PasswordAge.unknown, 90), isNull);
    });

    test('words the days', () {
      final e = PasswordExpiry.of(PasswordAge(lastChanged: changed), 90)!;
      expect(e.warning(DateTime(2026, 12, 2)), 'Password expires in 9 days');
      expect(e.warning(DateTime(2026, 12, 10)), 'Password expires tomorrow');
      expect(e.warning(DateTime(2026, 12, 11, 20)), 'Password expires today');
      expect(e.warning(DateTime(2026, 12, 13)), 'Password expired 2 days ago');
    });

    test('reminds 14 and 3 days before, in the morning, if still to come', () {
      final e = PasswordExpiry.of(PasswordAge(lastChanged: changed), 90)!;
      expect(e.reminders(DateTime(2026, 11, 10)), [
        (daysBefore: 14, at: DateTime(2026, 11, 27, 9)),
        (daysBefore: 3, at: DateTime(2026, 12, 8, 9)),
      ]);
      expect(e.reminders(DateTime(2026, 12, 1)), [
        (daysBefore: 3, at: DateTime(2026, 12, 8, 9)),
      ]);
      expect(e.reminders(DateTime(2026, 12, 9)), isEmpty);
    });

    test('reminder ids are fixed and apart', () {
      expect(PasswordExpiry.reminderId('work', 14),
          PasswordExpiry.reminderId('work', 14));
      expect(PasswordExpiry.reminderId('work', 14),
          isNot(PasswordExpiry.reminderId('work', 3)));
      expect(PasswordExpiry.reminderId('work', 14), greaterThanOrEqualTo(0));
    });

    test('payload names the account', () {
      expect(passwordAccountOf(passwordPayload('work')), 'work');
      expect(passwordAccountOf('folder#1'), isNull);
      expect(passwordAccountOf(null), isNull);
    });
  });

  group('GraphProfileApi', () {
    test('reads the date and the never-expires policy', () {
      final age = GraphProfileApi.passwordAgeFrom(
        '{"lastPasswordChangeDateTime":"2026-09-12T08:30:00Z",'
        '"passwordPolicies":"DisableStrongPassword, '
        'DisablePasswordExpiration"}',
      );
      expect(age.lastChanged, DateTime.utc(2026, 9, 12, 8, 30));
      expect(age.neverExpires, isTrue);
    });

    test("Windows' day nought is no date", () {
      // What Graph gives a user synced from the office's own servers.
      final age = GraphProfileApi.passwordAgeFrom(
        '{"lastPasswordChangeDateTime":"1601-01-01T00:00:00Z",'
        '"passwordPolicies":null}',
      );
      expect(age.lastChanged, isNull);
    });

    test('a personal account says neither', () {
      final age = GraphProfileApi.passwordAgeFrom(
        '{"lastPasswordChangeDateTime":null,"passwordPolicies":null}',
      );
      expect(age, PasswordAge.unknown);
    });

    test('asks /me for both by name, once more on a 401', () async {
      final seen = <http.Request>[];
      final forced = <bool>[];
      final api = GraphProfileApi(
        accessToken: ({bool force = false}) async {
          forced.add(force);
          return force ? 'new' : 'old';
        },
        httpClient: MockClient((request) async {
          seen.add(request);
          if (request.headers['Authorization'] == 'Bearer old') {
            return http.Response('', 401);
          }
          return http.Response(
            '{"lastPasswordChangeDateTime":"2026-09-12T08:30:00Z"}',
            200,
          );
        }),
      );
      final age = await api.passwordAge();
      expect(age.lastChanged, DateTime.utc(2026, 9, 12, 8, 30));
      expect(age.neverExpires, isFalse);
      expect(forced, [false, true]);
      expect(seen.last.url.queryParameters[r'$select'],
          'lastPasswordChangeDateTime,passwordPolicies');
    });
  });

  group('PasswordKeeper', () {
    late _Engine engine;
    late FakeMailNotifier notifier;
    late MemoryUiStateStore store;
    late ProviderContainer container;
    var now = DateTime(2026, 11, 10, 12);

    ProviderContainer make(Map<String, Object> ages) {
      engine = _Engine(ages);
      notifier = FakeMailNotifier();
      store = MemoryUiStateStore();
      final c = ProviderContainer(overrides: [
        mailEngineProvider.overrideWithValue(engine),
        mailNotifierProvider.overrideWithValue(notifier),
        uiStateStoreProvider.overrideWithValue(store),
        passwordClockProvider.overrideWithValue(() => now),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    setUp(() => now = DateTime(2026, 11, 10, 12));

    test('sets two reminders for the work account and asks for no other',
        () async {
      container = make({
        'work': PasswordAge(lastChanged: DateTime(2026, 9, 12, 8, 30)),
      });
      await container.read(accountsProvider.future);
      await container.read(passwordKeeperProvider).keepUp();

      expect(engine.asked, ['work']);
      final r14 = notifier.reminders[PasswordExpiry.reminderId('work', 14)]!;
      expect(r14.at, DateTime(2026, 11, 27, 9));
      expect(r14.title, 'Hadco password expires in 14 days');
      expect(r14.body, 'me@example.com: change it by Fri 11 Dec 2026.');
      expect(r14.payload, passwordPayload('work'));
      expect(notifier.reminders, hasLength(2));
    });

    test('a longer rule moves them; 0 takes them back', () async {
      container = make({
        'work': PasswordAge(lastChanged: DateTime(2026, 9, 12, 8, 30)),
      });
      await container.read(accountsProvider.future);
      final keeper = container.read(passwordKeeperProvider);
      await keeper.keepUp();

      container.read(passwordDaysProvider.notifier).set('work', 120);
      await keeper.keepUp(force: true, reread: false);
      expect(notifier.reminders[PasswordExpiry.reminderId('work', 14)]!.at,
          DateTime(2026, 12, 27, 9));
      expect(store.readOrder(UiStateKeys.passwordDays), {'work': 120});

      container.read(passwordDaysProvider.notifier).set('work', 0);
      await keeper.keepUp(force: true, reread: false);
      expect(notifier.reminders, isEmpty);
    });

    test('one already shown is not taken down', () async {
      container = make({
        'work': PasswordAge(lastChanged: DateTime(2026, 9, 12, 8, 30)),
      });
      await container.read(accountsProvider.future);
      final keeper = container.read(passwordKeeperProvider);
      await keeper.keepUp();
      now = DateTime(2026, 11, 28, 12);
      await keeper.keepUp(force: true);
      expect(
        notifier.reminders.keys,
        containsAll([
          PasswordExpiry.reminderId('work', 14),
          PasswordExpiry.reminderId('work', 3),
        ]),
      );
    });

    test('not allowed: the line stays quiet and nothing is set', () async {
      container = make({
        'work': const SignInNeedsConsent('Not allowed.'),
      });
      await container.read(accountsProvider.future);
      await container.read(passwordKeeperProvider).keepUp();
      expect(notifier.reminders, isEmpty);
      expect(container.read(passwordWarningProvider('work')), isNull);
    });

    test('the folder list says so from 14 days before', () async {
      container = make({
        'work': PasswordAge(lastChanged: DateTime(2026, 9, 12, 8, 30)),
      });
      await container.read(passwordAgeProvider('work').future);
      expect(container.read(passwordWarningProvider('work')), isNull);
      now = DateTime(2026, 12, 2, 12);
      container.invalidate(passwordWarningProvider('work'));
      expect(container.read(passwordWarningProvider('work')),
          'Password expires in 9 days');
    });
  });

  group("on the account's settings", () {
    Widget app(_Engine engine, DateTime now, {Account account = _work}) =>
        ProviderScope(
          overrides: [
            mailEngineProvider.overrideWithValue(engine),
            passwordClockProvider.overrideWithValue(() => now),
          ],
          child: MaterialApp(home: EditAccountScreen(account: account)),
        );

    testWidgets('says when it was changed and when it expires',
        (tester) async {
      await tester.pumpWidget(app(
        _Engine({'work': PasswordAge(lastChanged: DateTime(2026, 9, 12, 8))}),
        DateTime(2026, 11, 10, 12),
      ));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('password-days')), 200,
          scrollable: find
              .descendant(
                  of: find.byType(ListView), matching: find.byType(Scrollable))
              .first);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('password-line'))).data,
        'Last changed Sat 12 Sep 2026. Expires Fri 11 Dec 2026, in 31 days.',
      );
      expect(find.text('Change it at Microsoft'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('password-days')), '0');
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('password-line'))).data,
        'Last changed Sat 12 Sep 2026.',
      );
    });

    testWidgets('not allowed yet offers Allow', (tester) async {
      await tester.pumpWidget(app(
        _Engine({'work': const SignInNeedsConsent('Not allowed.')}),
        DateTime(2026, 11, 10, 12),
      ));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('password-days')), 200,
          scrollable: find
              .descendant(
                  of: find.byType(ListView), matching: find.byType(Scrollable))
              .first);
      expect(find.byKey(const ValueKey('password-allow')), findsOneWidget);
    });

    testWidgets('a shared mailbox has no password of its own',
        (tester) async {
      await tester.pumpWidget(app(
        _Engine(const {}),
        DateTime(2026, 11, 10, 12),
        account: _shared,
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('password-days')), findsNothing);
    });
  });
}
