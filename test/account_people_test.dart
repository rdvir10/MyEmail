import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myemail/data/auth/google_oauth.dart';
import 'package:myemail/data/auth/microsoft_oauth.dart';
import 'package:myemail/data/contacts/account_people.dart';
import 'package:myemail/domain/account.dart';

/// Searching each account's own address book online, against fake Google
/// and Microsoft servers.
void main() {
  const work = Account(
    id: 'work',
    displayName: 'Work',
    emailAddress: 'ron@hadco.example',
    provider: MailProvider.outlook,
    authMethod: AuthMethod.oauth,
    colorValue: 0,
  );
  const gmail = Account(
    id: 'gmail',
    displayName: 'Personal',
    emailAddress: 'ron@gmail.example',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.oauth,
    colorValue: 0,
  );
  const withPassword = Account(
    id: 'old',
    displayName: 'Old',
    emailAddress: 'old@gmail.example',
    provider: MailProvider.gmail,
    authMethod: AuthMethod.appPassword,
    colorValue: 0,
  );

  late List<http.Request> requests;
  late List<({String account, List<String>? scopes})> tokensAsked;

  /// What the token function says for each account: a token, or a throw.
  late Map<String, Object> tokenFor;

  AccountPeople people(
    List<Account> accounts,
    http.Response Function(http.Request) server,
  ) {
    return AccountPeople(
      accessToken: (id, {bool force = false, List<String>? scopes}) async {
        tokensAsked.add((account: id, scopes: scopes));
        final t = tokenFor[id] ?? 'token-$id';
        if (t is Exception) throw t;
        return t as String;
      },
      accounts: () => accounts,
      httpClient: MockClient((request) async {
        requests.add(request);
        return server(request);
      }),
    );
  }

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});

  setUp(() {
    requests = [];
    tokensAsked = [];
    tokenFor = {};
  });

  group('Microsoft', () {
    test("asks for the person's people and directory, quoted", () async {
      final p = people([work], (r) {
        return json({
          'value': [
            {
              'displayName': 'Tyler Lee',
              'scoredEmailAddresses': [
                {'address': 'tyler@hadco.example', 'relevanceScore': 8},
              ],
            },
            {'displayName': 'No address', 'scoredEmailAddresses': []},
          ],
        });
      });

      final found = await p.search('tyler lee');

      expect(found.single.email, 'tyler@hadco.example');
      expect(found.single.name, 'Tyler Lee');
      expect(found.single.fromContacts, isTrue);
      final r = requests.single;
      expect(r.url.path, '/v1.0/me/people');
      expect(r.url.queryParameters[r'$search'], '"tyler lee"');
      expect(r.headers['X-PeopleQuery-QuerySources'], 'Mailbox,Directory');
      expect(r.headers['Authorization'], 'Bearer token-work');
      expect(tokensAsked.single.scopes, MicrosoftOAuth.peopleScopes);
    });

    test('a personal account that refuses the directory is asked without',
        () async {
      final p = people([work], (r) {
        if (r.headers.containsKey('X-PeopleQuery-QuerySources')) {
          return json({'error': {'code': 'BadRequest'}}, 400);
        }
        return json({'value': []});
      });

      await p.search('ty');
      await p.search('tyl');

      expect(requests, hasLength(3),
          reason: 'once with, once without, then without from then on');
    });
  });

  group('Google', () {
    test('readies the search, then asks contacts and other contacts',
        () async {
      final p = people([gmail], (r) {
        final q = r.url.queryParameters['query'];
        if (q == '') return json({});
        final other = r.url.path.contains('otherContacts');
        return json({
          'results': [
            {
              'person': {
                'names': [
                  {'displayName': other ? 'Dana (Gmail)' : 'Dana Levi'},
                ],
                'emailAddresses': [
                  {'value': other ? 'dana.l@example.com' : 'dana@example.com'},
                ],
              },
            },
          ],
        });
      });

      final found = await p.search('dan');

      expect(found.map((f) => f.email),
          ['dana@example.com', 'dana.l@example.com'],
          reason: 'the contacts saved by hand first');
      expect(
        requests.where((r) => r.url.queryParameters['query'] == ''),
        hasLength(2),
        reason: 'Google asks for an empty search first',
      );
      expect(tokensAsked.first.scopes, GoogleOAuth.contactsScopes);

      requests.clear();
      await p.search('dana');
      expect(
        requests.where((r) => r.url.queryParameters['query'] == ''),
        isEmpty,
        reason: 'readied once',
      );
    });

    test('the People API switched off is said, in Settings', () async {
      final p = people([gmail], (r) {
        return json({
          'error': {
            'code': 403,
            'message': 'People API has not been used in project 1 before or '
                'it is disabled.',
            'status': 'PERMISSION_DENIED',
            'details': [
              {'reason': 'SERVICE_DISABLED'},
            ],
          },
        }, 403);
      });

      final access = await p.access(gmail);

      expect(access.state, PeopleSearchState.switchedOff);
      expect(access.message, contains('People API'));
    });
  });

  group('an account that has not allowed it', () {
    test('is passed over without a word, and not asked again at once',
        () async {
      tokenFor['work'] = const SignInNeedsConsent('no', needsAdministrator: true);
      final p = people([work, gmail], (r) {
        if (r.url.queryParameters['query'] == '') return json({});
        return json({
          'results': [
            {
              'person': {
                'emailAddresses': [
                  {'value': 'dana@example.com'},
                ],
              },
            },
          ],
        });
      });

      expect((await p.search('da')).single.email, 'dana@example.com',
          reason: "the other account's answer still comes");
      await p.search('dan');

      expect(tokensAsked.where((t) => t.account == 'work'), hasLength(1));
      expect((await p.access(work)).state,
          PeopleSearchState.needsAdministrator);
    });

    test('an app password is never asked', () async {
      final p = people([withPassword], (r) => json({}));

      expect(await p.search('da'), isEmpty);
      expect(tokensAsked, isEmpty);
      expect((await p.access(withPassword)).state,
          PeopleSearchState.notPossible);
    });

    test('is asked again once it has signed in again', () async {
      tokenFor['work'] = const SignInNeedsConsent('no');
      final p = people([work], (r) => json({'value': []}));

      await p.search('da');
      tokenFor.remove('work');
      p.forget('work');
      await p.search('dan');

      expect(requests, hasLength(1));
    });
  });

  test('the same letters again are answered from what came back', () async {
    final p = people([work], (r) => json({'value': []}));

    await p.search('Dan');
    await p.search('dan ');

    expect(requests, hasLength(1));
  });
}
