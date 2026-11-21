import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/contacts/contact_mapping.dart';
import 'package:myemail/domain/synced_contact.dart';

/// The contact sync's field mapping: what is read from a Gmail Person and
/// an Outlook contact, and what is written back, as the plan's "What is
/// copied" sets out.
void main() {
  Map<String, Object?> contact([Map<String, Object?> more = const {}]) => {
    'metadata': {
      'source': {'type': 'CONTACT', 'id': 'c1'},
    },
    ...more,
  };
  Map<String, Object?> profile([Map<String, Object?> more = const {}]) => {
    'metadata': {
      'source': {'type': 'PROFILE', 'id': 'p1'},
    },
    ...more,
  };
  Map<String, Object?> primary(Map<String, Object?> more) => {
    'metadata': {
      'primary': true,
      'source': {'type': 'CONTACT', 'id': 'c1'},
    },
    ...more,
  };

  final norm = ContactNormaliser(region: 'US');
  GooglePersonUpdate rebuild(
    Map<String, Object?> person,
    SyncedContact target,
    Set<ContactField> fields, {
    Map<ContactField, Map<String, String>> replaced = const {},
    ContactNormaliser? normaliser,
    SyncedContact? seen,
  }) => googlePersonUpdate(
    person,
    target,
    fields,
    replaced: replaced,
    normaliser: normaliser ?? norm,
    seen: seen,
  );

  group('reading a Gmail contact', () {
    final person = <String, Object?>{
      'resourceName': 'people/c1',
      'etag': '%EgUBAgMEBQ==',
      'metadata': {
        'sources': [
          {'type': 'PROFILE', 'updateTime': '2026-01-01T00:00:00Z'},
          {'type': 'CONTACT', 'updateTime': '2026-11-02T10:00:00.5Z'},
        ],
        'previousResourceNames': ['people/c0'],
      },
      'names': [
        profile({'givenName': 'Profile', 'familyName': 'Only'}),
        contact({
          'givenName': 'Ann',
          'middleName': 'B',
          'familyName': 'Cole',
          'honorificPrefix': 'Dr.',
          'honorificSuffix': 'Jr.',
          'phoneticGivenName': 'An',
          'phoneticFamilyName': 'Kol',
          'unstructuredName': 'Dr. Ann B Cole Jr.',
          'displayName': 'Ann Cole',
        }),
      ],
      'nicknames': [
        contact({'value': 'Maiden', 'type': 'MAIDEN_NAME'}),
        contact({'value': 'Annie'}),
      ],
      'emailAddresses': [
        contact({'value': 'ann@home.example', 'type': 'home'}),
        primary({'value': 'ann@work.example', 'type': 'work'}),
        profile({'value': 'ann@profile.example'}),
      ],
      'phoneNumbers': [
        contact({'value': '555 0101', 'type': 'workMobile'}),
        contact({'value': '555 0102', 'type': 'home'}),
        contact({'value': '555 0103', 'type': 'mobile'}),
        contact({'value': '555 0104', 'type': 'work'}),
        contact({'value': '555 0105', 'type': 'homeFax'}),
        contact({'value': '555 0106', 'type': 'home'}),
      ],
      'addresses': [
        contact({
          'type': 'work',
          'streetAddress': '1 Main St',
          'extendedAddress': 'Suite 5',
          'city': 'Springfield',
          'region': 'IL',
          'postalCode': '62701',
          'country': 'United States',
        }),
        contact({'type': 'work', 'streetAddress': 'Second work'}),
        contact({
          'type': 'home',
          'streetAddress': '2 Home Rd',
          'countryCode': 'GB',
        }),
      ],
      'organizations': [
        contact({'name': 'Old Co', 'current': false}),
        contact({
          'name': 'Hadco',
          'department': 'Ops',
          'title': 'Lead',
          'location': 'B2',
        }),
      ],
      'birthdays': [
        contact({
          'date': {'year': 1980, 'month': 2, 'day': 29},
        }),
      ],
      'biographies': [
        contact({
          'value': '<p>Line one</p><p>Line&nbsp;two<br>three</p>',
          'contentType': 'TEXT_HTML',
        }),
      ],
      'relations': [
        contact({'person': 'Bob', 'type': 'spouse'}),
        contact({'person': 'Cy', 'type': 'child'}),
        contact({'person': 'Di', 'type': 'child'}),
        contact({'person': 'Ed', 'type': 'manager'}),
        contact({'person': 'Fay', 'type': 'assistant'}),
        contact({'person': 'Gus', 'type': 'brother'}),
      ],
      'urls': [
        contact({'value': 'https://blog.example', 'type': 'blog'}),
        contact({'value': 'https://home.example', 'type': 'homePage'}),
      ],
      'imClients': [
        contact({'username': 'ann.im', 'protocol': 'skype'}),
      ],
      'clientData': [
        contact({'key': 'other.app', 'value': 'x'}),
        contact({'key': googleLinkKey, 'value': 'AAMkGraphId='}),
      ],
    };

    test('takes only the contact\'s own entries, and each detail', () {
      final g = GoogleContact.fromPerson(person);
      expect(g.resourceName, 'people/c1');
      expect(g.etag, '%EgUBAgMEBQ==');
      expect(g.updatedAt, DateTime.utc(2026, 11, 2, 10, 0, 0, 500));
      expect(g.tag, 'AAMkGraphId=');
      expect(g.previousNames, ['people/c0']);
      expect(g.deleted, isFalse);
      final d = g.details;
      expect(
        d.name,
        ContactName.of(
          given: 'Ann',
          middle: 'B',
          family: 'Cole',
          prefix: 'Dr.',
          suffix: 'Jr.',
          phoneticGiven: 'An',
          phoneticFamily: 'Kol',
        ),
      );
      expect(d.name!.display, isNull, reason: 'parts present: not compared');
      expect(d.text(ContactField.nickname), 'Annie');
      expect(d.list(ContactField.emails), [
        'ann@work.example',
        'ann@home.example',
      ], reason: 'primary first; the profile address left out');
      expect(d.text(ContactField.mobile), '555 0103');
      expect(d.list(ContactField.homePhones), ['555 0102', '555 0106']);
      expect(d.list(ContactField.workPhones), ['555 0104']);
      expect(
        d.address(ContactField.workAddress),
        ContactAddress.of(
          street: '1 Main St\nSuite 5',
          city: 'Springfield',
          region: 'IL',
          postalCode: '62701',
          country: 'United States',
        ),
      );
      expect(d.address(ContactField.homeAddress)!.country, 'GB');
      expect(d.address(ContactField.otherAddress), isNull);
      expect(d.text(ContactField.company), 'Hadco');
      expect(d.text(ContactField.department), 'Ops');
      expect(d.text(ContactField.jobTitle), 'Lead');
      expect(d.text(ContactField.office), 'B2');
      expect(
        d.birthday,
        const ContactBirthday(year: 1980, month: 2, day: 29),
      );
      expect(d.notes!.html, isTrue);
      expect(d.notes!.text, 'Line one\nLine two\nthree');
      expect(d.text(ContactField.spouse), 'Bob');
      expect(d.list(ContactField.children), ['Cy', 'Di']);
      expect(d.text(ContactField.manager), 'Ed');
      expect(d.text(ContactField.assistant), 'Fay');
      expect(d.text(ContactField.webPage), 'https://home.example');
      expect(d.list(ContactField.im), ['ann.im']);
    });

    test('a work mobile counts when there is no mobile', () {
      final d = syncedFromPerson({
        'phoneNumbers': [
          contact({'value': '1', 'type': 'workMobile'}),
        ],
      });
      expect(d.text(ContactField.mobile), '1');
    });

    test('a name with no parts travels as its unstructured name', () {
      final d = syncedFromPerson({
        'names': [
          contact({
            'unstructuredName': 'The Plumber',
            'displayName': 'The Plumber',
          }),
        ],
      });
      expect(d.name, ContactName.of(display: 'The Plumber'));
    });

    test('a year-less birthday is a value with no year', () {
      final d = syncedFromPerson({
        'birthdays': [
          contact({
            'date': {'month': 7, 'day': 4},
          }),
        ],
      });
      expect(d.birthday, const ContactBirthday(month: 7, day: 4));
    });

    test('a deleted entry from a sync-token listing says so', () {
      final g = GoogleContact.fromPerson({
        'resourceName': 'people/c9',
        'metadata': {'deleted': true},
      });
      expect(g.deleted, isTrue);
      expect(g.details.isEmpty, isTrue);
    });
  });

  group('reading an Outlook contact', () {
    final json = <String, Object?>{
      'id': 'AAMk1=',
      'changeKey': 'EQAAAB',
      'lastModifiedDateTime': '2026-11-02T11:00:00Z',
      'parentFolderId': 'folder-1',
      'displayName': 'Ann Cole',
      'givenName': 'Ann',
      'surname': 'Cole',
      'title': 'Dr.',
      'generation': 'Jr.',
      'nickName': 'Annie',
      'emailAddresses': [
        {'name': 'Ann', 'address': 'ann@work.example'},
        {'name': 'Ann', 'address': 'ann@home.example'},
      ],
      'mobilePhone': '555 0103',
      'homePhones': ['555 0102'],
      'businessPhones': ['555 0104', '555 0107'],
      'businessAddress': {
        'street': '1 Main St\r\nSuite 5',
        'city': 'Springfield',
        'state': 'IL',
        'postalCode': '62701',
        'countryOrRegion': 'USA',
      },
      'homeAddress': <String, Object?>{},
      'companyName': 'Hadco',
      'birthday': '1980-02-29T11:59:00Z',
      'personalNotes': 'Line one\r\nLine two',
      'spouseName': 'Bob',
      'children': ['Cy'],
      'manager': 'Ed',
      'assistantName': 'Fay',
      'businessHomePage': 'https://work.example/',
      'imAddresses': ['ann.im'],
      'singleValueExtendedProperties': [
        {
          'id': graphLinkPropertyId.toUpperCase(),
          'value': 'people/c1',
        },
      ],
    };

    test('takes each detail and the hidden tag', () {
      final h = GraphContact.fromJson(json);
      expect(h.id, 'AAMk1=');
      expect(h.changeKey, 'EQAAAB');
      expect(h.folderId, 'folder-1');
      expect(h.updatedAt, DateTime.utc(2026, 11, 2, 11));
      expect(h.tag, 'people/c1', reason: 'the id is matched without case');
      final d = h.details;
      expect(
        d.name,
        ContactName.of(
          given: 'Ann',
          family: 'Cole',
          prefix: 'Dr.',
          suffix: 'Jr.',
        ),
      );
      expect(d.list(ContactField.emails), [
        'ann@work.example',
        'ann@home.example',
      ]);
      expect(d.list(ContactField.workPhones), ['555 0104', '555 0107']);
      expect(
        d.address(ContactField.workAddress)!.street,
        '1 Main St\r\nSuite 5',
      );
      expect(
        d.address(ContactField.homeAddress),
        isNull,
        reason: 'empty is missing',
      );
      expect(d.birthday, const ContactBirthday(year: 1980, month: 2, day: 29));
      expect(d.notes, const ContactNotes('Line one\r\nLine two'));
      expect(d.text(ContactField.webPage), 'https://work.example/');
    });

    test('a contact with no name parts travels as its display name', () {
      final d = syncedFromGraph({'displayName': 'The Plumber'});
      expect(d.name, ContactName.of(display: 'The Plumber'));
    });

    test('a display name that is an email or the company is no name', () {
      final byEmail = syncedFromGraph({
        'displayName': 'Ann@X.example',
        'emailAddresses': [
          {'address': 'ann@x.example'},
        ],
      });
      expect(byEmail.name, isNull);
      final byCompany = syncedFromGraph({
        'displayName': 'HADCO',
        'companyName': 'Hadco',
      });
      expect(byCompany.name, isNull);
      final google = syncedFromPerson({
        'names': [
          contact({'displayName': 'ann@x.example'}),
        ],
        'emailAddresses': [
          contact({'value': 'ann@x.example'}),
        ],
      });
      expect(google.name, isNull);
    });

    test('a removed or sparse delta item says so', () {
      final removed = GraphContact.fromJson({
        'id': 'AAMk1=',
        '@removed': {'reason': 'deleted'},
      });
      expect(removed.removed, isTrue);
      final sparse = GraphContact.fromJson({
        'id': 'AAMk1=',
        'givenName': 'Ann',
      });
      expect(sparse.readWhole, isFalse);
      expect(sparse.missing, contains('surname'));
      expect(sparse.missing, contains('emailAddresses'));
      final whole = GraphContact.fromJson({
        'id': 'AAMk1=',
        for (final p in graphSyncedProperties) p: null,
      });
      expect(whole.readWhole, isTrue);
      expect(whole.removed, isFalse);
    });

    test('birthdays from midnight UTC, 11:59 UTC and local midnights', () {
      const day = ContactBirthday(year: 1990, month: 5, day: 5);
      expect(birthdayFromGraph('1990-05-05T00:00:00Z'), day);
      expect(birthdayFromGraph('1990-05-05T11:59:00Z'), day);
      // Local midnight in UTC+2 and UTC-7, kept as UTC.
      expect(birthdayFromGraph('1990-05-04T22:00:00Z'), day);
      expect(birthdayFromGraph('1990-05-05T07:00:00Z'), day);
      expect(birthdayFromGraph('1990-05-05T00:00:00+10:00'), day);
    });

    test('a year before 1700 is no year', () {
      expect(
        birthdayFromGraph('1604-07-04T11:59:00Z'),
        const ContactBirthday(month: 7, day: 4),
      );
      expect(birthdayFromGraph('1700-07-04T11:59:00Z')!.year, 1700);
    });

    test('a birthday is written at 11:59 UTC, and never without a year', () {
      expect(
        birthdayToGraph(const ContactBirthday(year: 1990, month: 5, day: 5)),
        '1990-05-05T11:59:00Z',
      );
      expect(birthdayToGraph(const ContactBirthday(month: 5, day: 5)), isNull);
      // Round trip.
      final back = birthdayFromGraph(
        birthdayToGraph(const ContactBirthday(year: 2001, month: 12, day: 31)),
      );
      expect(back, const ContactBirthday(year: 2001, month: 12, day: 31));
    });
  });

  group('writing into Gmail', () {
    Map<String, Object?> base() => {
      'resourceName': 'people/c1',
      'etag': 'etag-1',
      'metadata': {
        'sources': [
          {'type': 'CONTACT', 'etag': 'src-etag'},
        ],
      },
      'names': [
        contact({
          'givenName': 'Ann',
          'familyName': 'Cole',
          'unstructuredName': 'Ann Cole',
          'displayName': 'Ann Cole',
          'displayNameLastFirst': 'Cole, Ann',
        }),
      ],
      'emailAddresses': [
        contact({
          'value': 'a1@x.example',
          'type': 'home',
          'formattedType': 'Home',
        }),
        contact({
          'value': 'a2@x.example',
          'type': 'custom',
          'formattedType': 'Lab',
        }),
        contact({'value': 'a3@x.example', 'type': 'work'}),
        contact({'value': 'a4@x.example', 'type': 'other'}),
      ],
      'phoneNumbers': [
        contact({'value': '555 0101', 'type': 'homeFax'}),
        contact({
          'value': '555 0102',
          'type': 'home',
          'canonicalForm': '+15550102',
        }),
        contact({'value': '555 0103', 'type': 'mobile'}),
      ],
      'addresses': [
        contact({
          'type': 'home',
          'streetAddress': '2 Home Rd',
          'extendedAddress': 'Flat 3',
          'poBox': 'PO 9',
          'city': 'Leeds',
          'country': 'UK',
          'countryCode': 'GB',
          'formattedValue': '2 Home Rd\nFlat 3\nLeeds',
        }),
      ],
      'organizations': [
        contact({
          'name': 'Hadco',
          'title': 'Lead',
          'startDate': {'year': 2020},
        }),
      ],
      'biographies': [
        contact({'value': '<b>Old</b>', 'contentType': 'TEXT_HTML'}),
      ],
      'birthdays': [
        contact({
          'date': {'month': 7, 'day': 4},
        }),
      ],
      'nicknames': [
        contact({'value': 'Annie'}),
      ],
      'urls': [
        contact({'value': 'https://blog.example', 'type': 'blog'}),
      ],
    };

    test('names only the changed groups, rebuilt from the full list', () {
      final person = base();
      final current = syncedFromPerson(person);
      final target = current.withValue(ContactField.emails, [
        'a1@x.example',
        'a2@x.example',
        'a3@x.example',
        'a4@x.example',
        'new@x.example',
      ]);
      final update = rebuild(person, target, {ContactField.emails});
      expect(update.updatePersonFields, ['emailAddresses']);
      expect(update.person['etag'], 'etag-1');
      expect(update.person['names'], person['names'], reason: 'untouched');
      final emails = update.person['emailAddresses'] as List;
      expect(emails, hasLength(5));
      expect((emails[1] as Map)['formattedType'], 'Lab', reason: 'label kept');
      expect(emails.last, {'value': 'new@x.example', 'type': 'other'});
    });

    test('a value replaced in an Outlook slot changes that entry in place', () {
      final person = base();
      final target = syncedFromPerson(person).withValue(ContactField.emails, [
        'a1@x.example',
        'b2@x.example',
        'a3@x.example',
        'a4@x.example',
      ]);
      final update = rebuild(
        person,
        target,
        {ContactField.emails},
        replaced: {
          ContactField.emails: {'a2@x.example': 'b2@x.example'},
        },
      );
      final emails = (update.person['emailAddresses'] as List).cast<Map>();
      expect(emails.map((e) => e['value']), [
        'a1@x.example',
        'b2@x.example',
        'a3@x.example',
        'a4@x.example',
      ]);
      expect(emails[1]['type'], 'custom');
      expect(emails[1]['formattedType'], 'Lab');
    });

    test('a removed value goes; one Outlook cannot hold stays', () {
      final person = base();
      final target = syncedFromPerson(person).withValue(ContactField.emails, [
        'a1@x.example',
        'a3@x.example',
        'a4@x.example',
      ]);
      final emails = (rebuild(
        person,
        target,
        {ContactField.emails},
      ).person['emailAddresses'] as List).cast<Map>();
      expect(emails.map((e) => e['value']), [
        'a1@x.example',
        'a3@x.example',
        'a4@x.example',
      ]);
    });

    test('a value added since the plan read Gmail survives the write', () {
      // The plan read e1-e3 and adds e5 from Outlook; meanwhile Ron added
      // e4 in Gmail, which the fresh Person has.
      final fresh = {
        'emailAddresses': [
          for (final e in ['e1@x', 'e2@x', 'e3@x', 'e4@x'])
            contact({'value': e}),
        ],
      };
      final seen = SyncedContact({
        ContactField.emails: ['e1@x', 'e2@x', 'e3@x'],
      });
      final target = seen.withValue(ContactField.emails, [
        'e1@x',
        'e2@x',
        'e3@x',
        'e5@x',
      ]);
      final emails = (rebuild(
        fresh,
        target,
        {ContactField.emails},
        seen: seen,
      ).person['emailAddresses'] as List).map((e) => (e as Map)['value']);
      expect(emails, ['e1@x', 'e2@x', 'e3@x', 'e4@x', 'e5@x']);
      // A value the plan saw and dropped still goes.
      final dropped = (rebuild(
        fresh,
        seen.withValue(ContactField.emails, ['e1@x', 'e3@x']),
        {ContactField.emails},
        seen: seen,
      ).person['emailAddresses'] as List).map((e) => (e as Map)['value']);
      expect(dropped, ['e1@x', 'e3@x', 'e4@x']);
    });

    test('a phone with no digits is never removed', () {
      final phones = (rebuild(
        {
          'phoneNumbers': [
            contact({'value': 'ask reception', 'type': 'home'}),
            contact({'value': '555 0102', 'type': 'home'}),
          ],
        },
        SyncedContact({ContactField.homePhones: ['555 0102']}),
        {ContactField.homePhones},
      ).person['phoneNumbers'] as List).map((e) => (e as Map)['value']);
      expect(phones, ['ask reception', '555 0102']);
    });

    test('phones: other types stay where they are', () {
      final person = base();
      final target = syncedFromPerson(person)
          .withValue(ContactField.homePhones, ['555 0102', '555 0199'])
          .withValue(ContactField.mobile, '555 0300');
      final update = rebuild(
        person,
        target,
        {ContactField.homePhones, ContactField.mobile},
        normaliser: norm,
      );
      expect(update.updatePersonFields, ['phoneNumbers']);
      final phones = (update.person['phoneNumbers'] as List).cast<Map>();
      expect(phones.map((p) => '${p['type']} ${p['value']}'), [
        'homeFax 555 0101',
        'home 555 0102',
        'mobile 555 0300',
        'home 555 0199',
      ]);
    });

    test('a rewritten name leaves out the unstructured name', () {
      final person = base();
      final target = SyncedContact({
        ContactField.name: ContactName.of(given: 'Ann', family: 'Smith'),
      });
      final names = (rebuild(
        person,
        target,
        {ContactField.name},
      ).person['names'] as List).cast<Map>();
      expect(names.single['familyName'], 'Smith');
      expect(names.single.containsKey('unstructuredName'), isFalse);
      expect(names.single.containsKey('displayName'), isFalse);
      expect(names.single['metadata'], isNotNull);
    });

    test('a name with no parts is written as the unstructured name', () {
      final names = (rebuild(
        base(),
        SyncedContact({
          ContactField.name: ContactName.of(display: 'The Plumber'),
        }),
        {ContactField.name},
      ).person['names'] as List).cast<Map>();
      expect(names.single['unstructuredName'], 'The Plumber');
      expect(names.single.containsKey('givenName'), isFalse);
    });

    test('addresses: the extended line kept when the street ends with it', () {
      final person = base();
      final target = SyncedContact({
        ContactField.homeAddress: ContactAddress.of(
          street: '4 New Rd\nFlat 3',
          city: 'Leeds',
          country: 'UK',
        ),
      });
      final address =
          ((rebuild(person, target, {ContactField.homeAddress})
                      .person['addresses']
                  as List)
              .single as Map);
      expect(address['streetAddress'], '4 New Rd');
      expect(address['extendedAddress'], 'Flat 3');
      expect(address['poBox'], 'PO 9');
      expect(address.containsKey('formattedValue'), isFalse);
      expect(address['countryCode'], 'GB', reason: 'country unchanged');
    });

    test('addresses: otherwise the first line is the street', () {
      final person = base();
      final target = SyncedContact({
        ContactField.homeAddress: ContactAddress.of(
          street: '9 Far St\r\nUnit 1\r\nBack door',
          city: 'Paris',
          country: 'France',
        ),
      });
      final address =
          ((rebuild(person, target, {ContactField.homeAddress})
                      .person['addresses']
                  as List)
              .single as Map);
      expect(address['streetAddress'], '9 Far St');
      expect(address['extendedAddress'], 'Unit 1\nBack door');
      expect(address['country'], 'France');
      expect(address['countryCode'], 'FR', reason: 'a changed country');

      final single = SyncedContact({
        ContactField.homeAddress: ContactAddress.of(
          street: '9 Far St',
          country: 'Atlantis',
        ),
      });
      final plain =
          ((rebuild(person, single, {ContactField.homeAddress})
                      .person['addresses']
                  as List)
              .single as Map);
      expect(plain.containsKey('extendedAddress'), isFalse);
      expect(plain.containsKey('countryCode'), isFalse, reason: 'unknown');
    });

    test('notes are written as plain text', () {
      final bios = (rebuild(
        base(),
        SyncedContact({ContactField.notes: const ContactNotes('New\r\nnote')}),
        {ContactField.notes},
      ).person['biographies'] as List).cast<Map>();
      expect(bios.single['value'], 'New\r\nnote');
      expect(bios.single['contentType'], 'TEXT_PLAIN');
    });

    test('Outlook\'s year is added to a year-less birthday', () {
      final bdays = (rebuild(
        base(),
        SyncedContact({
          ContactField.birthday: const ContactBirthday(
            year: 1980,
            month: 7,
            day: 4,
          ),
        }),
        {ContactField.birthday},
      ).person['birthdays'] as List).cast<Map>();
      expect(bdays.single['date'], {'year': 1980, 'month': 7, 'day': 4});
    });

    test('a birthday without a year is never written, and never clears', () {
      final bdays = (rebuild(
        base(),
        SyncedContact({
          ContactField.birthday: const ContactBirthday(month: 1, day: 2),
        }),
        {ContactField.birthday},
      ).person['birthdays'] as List).cast<Map>();
      expect(bdays.single['date'], {'month': 7, 'day': 4});
    });

    test('an organisation keeps what Outlook cannot hold', () {
      final person = base();
      final update = rebuild(
        person,
        SyncedContact({ContactField.department: 'Ops'}),
        {ContactField.company, ContactField.jobTitle, ContactField.department},
      );
      final org = (update.person['organizations'] as List).single as Map;
      expect(org['name'], isNull);
      expect(org['title'], isNull);
      expect(org['department'], 'Ops');
      expect(org['startDate'], {'year': 2020});

      final emptied = rebuild(
        {
          'organizations': [
            contact({'name': 'Hadco'}),
          ],
        },
        SyncedContact.empty,
        {ContactField.company},
      );
      expect(emptied.person['organizations'], isEmpty);
    });

    test('a nickname with no type is the one changed', () {
      final nicks = (rebuild(
        base(),
        SyncedContact({ContactField.nickname: 'Nan'}),
        {ContactField.nickname},
      ).person['nicknames'] as List).cast<Map>();
      expect(nicks.single['value'], 'Nan');
    });

    test('a web page from Outlook joins as work, or keeps the type', () {
      final urls = (rebuild(
        base(),
        SyncedContact({ContactField.webPage: 'https://new.example'}),
        {ContactField.webPage},
      ).person['urls'] as List).cast<Map>();
      expect(urls.single['value'], 'https://new.example');
      expect(urls.single['type'], 'blog');

      final added = (rebuild(
        {'resourceName': 'people/c2'},
        SyncedContact({ContactField.webPage: 'https://new.example'}),
        {ContactField.webPage},
      ).person['urls'] as List).cast<Map>();
      expect(added.single, {'value': 'https://new.example', 'type': 'work'});
    });

    test('several details of one Person field are one field to name', () {
      final update = rebuild(
        base(),
        SyncedContact({
          ContactField.spouse: 'Bob',
          ContactField.children: ['Cy', 'Di'],
        }),
        {ContactField.spouse, ContactField.children, ContactField.nickname},
      );
      expect(update.updatePersonFields, ['nicknames', 'relations']);
      expect(update.updatePersonFieldsParam, 'nicknames,relations');
      final relations = (update.person['relations'] as List).cast<Map>();
      expect(relations.map((r) => '${r['type']} ${r['person']}'), [
        'spouse Bob',
        'child Cy',
        'child Di',
      ]);
    });

    test('a create goes into My Contacts, its tag left to the client', () {
      final body = googleCreateBody(
        SyncedContact({
          ContactField.name: ContactName.of(given: 'Ann', family: 'Cole'),
          ContactField.emails: ['a@x.example', 'b@x.example'],
          ContactField.mobile: '555 0103',
          ContactField.workPhones: ['555 0104'],
          ContactField.company: 'Hadco',
          ContactField.jobTitle: 'Lead',
          ContactField.notes: const ContactNotes('Hi'),
        }),
      );
      expect(body.containsKey('clientData'), isFalse);
      expect(body['memberships'], [
        {
          'contactGroupMembership': {
            'contactGroupResourceName': 'contactGroups/myContacts',
          },
        },
      ]);
      expect(body['names'], [
        {'givenName': 'Ann', 'familyName': 'Cole'},
      ]);
      expect(body['emailAddresses'], [
        {'value': 'a@x.example', 'type': 'other'},
        {'value': 'b@x.example', 'type': 'other'},
      ]);
      expect(body['phoneNumbers'], [
        {'value': '555 0103', 'type': 'mobile'},
        {'value': '555 0104', 'type': 'work'},
      ]);
      expect(body['organizations'], [
        {'name': 'Hadco', 'title': 'Lead'},
      ]);
      expect(body['biographies'], [
        {'value': 'Hi', 'contentType': 'TEXT_PLAIN'},
      ]);
      expect(body.containsKey('birthdays'), isFalse);
    });

    test('a create leaves out a birthday without a year', () {
      final body = googleCreateBody(
        SyncedContact({
          ContactField.birthday: const ContactBirthday(month: 3, day: 4),
        }),
      );
      expect(body.containsKey('birthdays'), isFalse);
      expect(body.containsKey('clientData'), isFalse);
    });

    test('a Restore brings back every writable field and live labels', () {
      final body = googleRestoreBody(
        {
          ...base(),
          'events': [
            contact({
              'date': {'year': 2010, 'month': 6, 'day': 1},
              'type': 'anniversary',
              'formattedType': 'Anniversary',
            }),
          ],
          'userDefined': [
            contact({'key': 'Shoe', 'value': '9'}),
          ],
          'photos': [
            contact({'url': 'https://photo'}),
          ],
          'memberships': [
            {
              'contactGroupMembership': {
                'contactGroupResourceName': 'contactGroups/friends',
              },
            },
            {
              'contactGroupMembership': {
                'contactGroupResourceName': 'contactGroups/gone',
              },
            },
          ],
          'clientData': [
            contact({'key': googleLinkKey, 'value': 'old'}),
            contact({'key': 'other.app', 'value': 'kept'}),
          ],
        },
        labelsThatExist: {'contactGroups/friends'},
      );
      expect(body['events'], [
        {
          'date': {'year': 2010, 'month': 6, 'day': 1},
          'type': 'anniversary',
        },
      ]);
      expect(body['userDefined'], [
        {'key': 'Shoe', 'value': '9'},
      ]);
      expect(body.containsKey('photos'), isFalse);
      expect(body.containsKey('etag'), isFalse);
      expect(
        (body['memberships'] as List).map(
          (m) => ((m as Map)['contactGroupMembership']
              as Map)['contactGroupResourceName'],
        ),
        unorderedEquals(['contactGroups/myContacts', 'contactGroups/friends']),
      );
      expect(body['clientData'], [
        {'key': 'other.app', 'value': 'kept'},
      ], reason: 'the old tag goes; the client adds the new one');
      final name = (body['names'] as List).single as Map;
      expect(name.containsKey('displayName'), isFalse);
      expect(name.containsKey('metadata'), isFalse);
    });
  });

  group('writing into Outlook', () {
    final current = <String, Object?>{
      'id': 'AAMk1=',
      'displayName': 'Ann Cole',
      'givenName': 'Ann',
      'surname': 'Cole',
      'emailAddresses': [
        {'name': 'Ann (work)', 'address': 'Ann@Work.example'},
      ],
    };

    test('a PATCH has the changed properties, lists whole, in slots', () {
      final body = graphContactPatch(
        current,
        SyncedContact({
          ContactField.emails: [
            'ann@work.example',
            'b@x.example',
            'c@x.example',
            'd@x.example',
          ],
          ContactField.homePhones: ['1', '2', '3'],
          ContactField.company: 'Hadco',
        }),
        {ContactField.emails, ContactField.homePhones, ContactField.jobTitle},
      );
      expect(body.keys, unorderedEquals([
        'emailAddresses',
        'homePhones',
        'jobTitle',
        'displayName',
      ]));
      expect(body['emailAddresses'], [
        {'address': 'ann@work.example', 'name': 'Ann (work)'},
        {'address': 'b@x.example', 'name': 'Ann Cole'},
        {'address': 'c@x.example', 'name': 'Ann Cole'},
      ]);
      expect(body['homePhones'], ['1', '2']);
      expect(body['jobTitle'], isNull, reason: 'cleared');
      expect(body['displayName'], 'Ann Cole', reason: 'always resent');
    });

    test('addresses are sent whole; a cleared one with every part empty', () {
      final body = graphContactPatch(
        current,
        SyncedContact({
          ContactField.workAddress: ContactAddress.of(
            street: '1 Main St\nSuite 5',
            city: 'Springfield',
          ),
        }),
        {ContactField.workAddress, ContactField.homeAddress},
      );
      expect(body['businessAddress'], {
        'street': '1 Main St\nSuite 5',
        'city': 'Springfield',
        'state': null,
        'postalCode': null,
        'countryOrRegion': null,
      });
      expect((body['homeAddress'] as Map).values, everyElement(isNull));
    });

    test('a composed display name follows the new parts', () {
      final body = graphContactPatch(
        current,
        SyncedContact({
          ContactField.name: ContactName.of(given: 'Ann', family: 'Smith'),
        }),
        {ContactField.name},
      );
      expect(body['surname'], 'Smith');
      expect(body['givenName'], 'Ann');
      expect(body['middleName'], isNull);
      expect(body['displayName'], 'Ann Smith');
    });

    test('"Last, First" stays in that form', () {
      final body = graphContactPatch(
        {...current, 'displayName': 'Cole, Ann'},
        SyncedContact({
          ContactField.name: ContactName.of(given: 'Ann', family: 'Smith'),
        }),
        {ContactField.name},
      );
      expect(body['displayName'], 'Smith, Ann');
    });

    test('a display name with the title and middle name keeps that form', () {
      final body = graphContactPatch(
        {
          ...current,
          'displayName': 'Dr. Ann B Cole',
          'title': 'Dr.',
          'middleName': 'B',
        },
        SyncedContact({
          ContactField.name: ContactName.of(
            given: 'Ann',
            middle: 'B',
            family: 'Smith',
            prefix: 'Dr.',
          ),
        }),
        {ContactField.name},
      );
      expect(body['displayName'], 'Dr. Ann B Smith');
    });

    test('Outlook\'s own display name is kept as it is', () {
      final body = graphContactPatch(
        {...current, 'displayName': 'Annie from work'},
        SyncedContact({
          ContactField.name: ContactName.of(given: 'Ann', family: 'Smith'),
        }),
        {ContactField.name},
      );
      expect(body['displayName'], 'Annie from work');
    });

    test('a name with no parts travels as the display name', () {
      final body = graphContactPatch(
        current,
        SyncedContact({
          ContactField.name: ContactName.of(display: 'The Plumber'),
        }),
        {ContactField.name},
      );
      expect(body['displayName'], 'The Plumber');
      expect(body['givenName'], isNull);
      expect(body['surname'], isNull);
    });

    test('notes go as text; a year-less birthday is never sent', () {
      final body = graphContactPatch(
        current,
        SyncedContact({
          ContactField.notes: const ContactNotes(
            '<p>Hi</p><p>there</p>',
            html: true,
          ),
          ContactField.birthday: const ContactBirthday(month: 1, day: 2),
        }),
        {ContactField.notes},
      );
      expect(body['personalNotes'], 'Hi\nthere');
      expect(body.containsKey('birthday'), isFalse);
    });

    test('a create has a composed display name and no tag', () {
      final body = graphCreateBody(
        SyncedContact({
          ContactField.name: ContactName.of(
            given: 'Ann',
            middle: 'B',
            family: 'Cole',
          ),
          ContactField.emails: [
            'a@x.example',
            'b@x.example',
            'c@x.example',
            'd@x.example',
          ],
          ContactField.im: ['1', '2', '3', '4'],
          ContactField.birthday: const ContactBirthday(
            year: 1990,
            month: 5,
            day: 5,
          ),
          ContactField.homeAddress: ContactAddress.of(city: 'Leeds'),
        }),
      );
      expect(body.containsKey('singleValueExtendedProperties'), isFalse);
      expect(body['displayName'], 'Ann B Cole');
      expect((body['emailAddresses'] as List), hasLength(3));
      expect(body['imAddresses'], ['1', '2', '3']);
      expect(body['birthday'], '1990-05-05T11:59:00Z');
      expect(body['homeAddress'], {'city': 'Leeds'});
      expect(body.containsKey('surname'), isTrue);
      expect(body.containsKey('nickName'), isFalse);
    });

    test('a year-less birthday is left out of a create', () {
      final body = graphCreateBody(
        SyncedContact({
          ContactField.birthday: const ContactBirthday(month: 5, day: 5),
        }),
      );
      expect(body.containsKey('birthday'), isFalse);
    });

    test('the tag moves when Gmail re-keys', () {
      expect(graphTagPatch('people/c2'), {
        'singleValueExtendedProperties': [
          {'id': graphLinkPropertyId, 'value': 'people/c2'},
        ],
      });
    });

    test('the two extended properties, by batch C\'s one GUID', () {
      expect(
        graphLinkPropertyId,
        'String {958f81ac-dee9-4f9e-a713-9043484f5b0f} Name MyEmailLink',
      );
      expect(
        graphDevicePropertyId,
        'String {958f81ac-dee9-4f9e-a713-9043484f5b0f} Name MyEmailSyncDevice',
      );
      expect(googleLinkKey, 'myemail.link');
    });

    test('a Restore brings back every writable property', () {
      final body = graphRestoreBody(
        {
          'id': 'gone',
          'changeKey': 'x',
          'displayName': 'Ann',
          'categories': ['Red'],
          'fileAs': 'Cole, Ann',
          'profession': 'Vet',
          'parentFolderId': 'f',
          'singleValueExtendedProperties': [
            {'id': graphLinkPropertyId, 'value': 'old'},
          ],
        },
      );
      expect(body.keys, unorderedEquals([
        'displayName',
        'categories',
        'fileAs',
        'profession',
      ]));
    });
  });

  group('lists merged by value', () {
    ContactListMerge merge({
      required List<String> google,
      List<String> googleBase = const [],
      required List<String> graph,
      List<String> graphBase = const [],
      bool removals = true,
      ContactField field = ContactField.emails,
    }) => mergeContactList(
      field,
      google: google,
      googleBase: googleBase,
      graph: graph,
      graphBase: graphBase,
      normaliser: norm,
      removals: removals,
    );

    test('an addition on each side keeps both', () {
      final m = merge(
        google: ['a@x', 'g@x'],
        googleBase: ['a@x'],
        graph: ['a@x', 'h@x'],
        graphBase: ['a@x'],
      );
      expect(m.google, ['a@x', 'g@x', 'h@x']);
      expect(m.graph, ['a@x', 'h@x', 'g@x']);
      expect(m.removes, isFalse);
    });

    test('a value gone from one side goes from the other', () {
      final m = merge(
        google: ['a@x', 'b@x'],
        googleBase: ['a@x', 'b@x'],
        graph: ['a@x'],
        graphBase: ['a@x', 'b@x'],
      );
      expect(m.google, ['a@x']);
      expect(m.graph, ['a@x']);
      expect(m.removes, isTrue);
    });

    test('a value never copied across is never removed', () {
      // The fourth email never went to Outlook, so Outlook not having it
      // is no reason to remove it.
      final m = merge(
        google: ['a@x', 'b@x', 'c@x', 'd@x'],
        googleBase: ['a@x', 'b@x', 'c@x', 'd@x'],
        graph: ['a@x', 'c@x'],
        graphBase: ['a@x', 'b@x', 'c@x'],
      );
      expect(m.google, ['a@x', 'c@x', 'd@x']);
      expect(m.graph, ['a@x', 'c@x', 'd@x'], reason: 'the free slot filled');
    });

    test('compared without case', () {
      final m = merge(
        google: ['Ann@X.example'],
        googleBase: ['Ann@X.example'],
        graph: ['ann@x.example'],
        graphBase: ['Ann@X.example'],
      );
      expect(m.google, ['Ann@X.example']);
      expect(m.graph, ['ann@x.example']);
      expect(m.removes, isFalse);
    });

    test('a value replaced in an Outlook slot changes in place in Gmail', () {
      final m = merge(
        google: ['a@x', 'b@x', 'z@x'],
        googleBase: ['a@x', 'b@x', 'z@x'],
        graph: ['a@x', 'c@x', 'z@x'],
        graphBase: ['a@x', 'b@x', 'z@x'],
      );
      expect(m.google, ['a@x', 'c@x', 'z@x']);
      expect(m.googleReplaced, {'b@x': 'c@x'});
      expect(m.removes, isTrue);
    });

    test('slots: Outlook takes three, Gmail keeps the overflow', () {
      final m = merge(
        google: ['a@x', 'b@x', 'c@x', 'd@x'],
        graph: const [],
      );
      expect(m.graph, ['a@x', 'b@x', 'c@x']);
      expect(m.google, ['a@x', 'b@x', 'c@x', 'd@x']);
      final phones = merge(
        field: ContactField.homePhones,
        google: ['+1 212 555 0100'],
        graph: ['(212) 555-0100', '212 555 0101'],
      );
      expect(phones.google, ['+1 212 555 0100', '212 555 0101']);
      expect(phones.graph, ['(212) 555-0100', '212 555 0101']);
    });

    test('with removals off, the lists are only joined', () {
      final m = merge(
        google: ['a@x'],
        googleBase: ['a@x', 'b@x'],
        graph: ['a@x', 'b@x'],
        graphBase: ['a@x', 'b@x'],
        removals: false,
      );
      expect(m.google, ['a@x', 'b@x']);
      expect(m.removes, isFalse);
    });
  });

  group('normalised forms', () {
    test('phones as E.164 keys in the pair\'s region', () {
      expect(norm.phoneKey('(212) 555-0100'), '+12125550100');
      expect(norm.phoneKey('+1 212 555 0100'), '+12125550100');
      expect(norm.phoneKey('+44 20 7946 0958'), '+442079460958');
      final uk = ContactNormaliser(region: 'gb');
      expect(uk.phoneKey('020 7946 0958'), '+442079460958');
      expect(norm.phoneKey('no digits'), isNull);
    });

    test('emails lower-cased; text without case and with spaces collapsed', () {
      expect(ContactNormaliser.emailKey(' Ann@X.Example '), 'ann@x.example');
      expect(ContactNormaliser.textKey('  Ann   COLE '), 'ann cole');
      expect(ContactNormaliser.textKey('   '), isNull);
    });

    test('web pages by scheme and host, without a trailing slash', () {
      expect(
        ContactNormaliser.webKey('HTTPS://Example.COM/Path/'),
        'https://example.com/Path',
      );
      expect(ContactNormaliser.webKey('example.com'), 'http://example.com');
    });

    test('addresses part by part, countries as ISO codes, LF streets', () {
      final a = ContactAddress.of(
        street: '1 Main St\r\nSuite 5',
        city: 'Springfield',
        country: 'United States of America',
      );
      final b = ContactAddress.of(
        street: '1 main st\nsuite  5',
        city: 'SPRINGFIELD',
        country: 'US',
      );
      expect(norm.same(ContactField.homeAddress, a, b), isTrue);
      expect(countryCodeFor('Great Britain'), 'GB');
      expect(countryCodeFor('U.K.'), 'GB');
      expect(countryCodeFor('Narnia'), isNull);
    });

    test('notes as text with LF line ends', () {
      expect(
        norm.same(
          ContactField.notes,
          const ContactNotes('<div>One</div><div>Two</div>', html: true),
          const ContactNotes('One\r\nTwo'),
        ),
        isTrue,
      );
    });

    test('a capitals fix is not equivalent, though it is the same', () {
      expect(norm.same(ContactField.company, 'hadco', 'Hadco'), isTrue);
      expect(norm.equivalent(ContactField.company, 'hadco', 'Hadco'), isFalse);
      expect(norm.equivalent(ContactField.company, ' Hadco ', 'Hadco'), isTrue);
      expect(
        norm.equivalent(ContactField.mobile, '(212) 555-0100', '+12125550100'),
        isTrue,
      );
    });

    test('a year-less birthday is the same day as a full one', () {
      expect(
        norm.same(
          ContactField.birthday,
          const ContactBirthday(month: 7, day: 4),
          const ContactBirthday(year: 1980, month: 7, day: 4),
        ),
        isTrue,
      );
      expect(
        norm.same(
          ContactField.birthday,
          const ContactBirthday(month: 7, day: 5),
          const ContactBirthday(year: 1980, month: 7, day: 4),
        ),
        isFalse,
      );
    });

    test('a region is required, and an unknown one refused', () {
      expect(() => ContactNormaliser(region: 'ZZ'), throwsArgumentError);
      expect(ContactNormaliser.isRegion('us'), isTrue);
      expect(ContactNormaliser.isRegion('Narnia'), isFalse);
    });

    test('a year written over the same day without one is a change', () {
      const yearless = ContactBirthday(month: 7, day: 4);
      const full = ContactBirthday(year: 1980, month: 7, day: 4);
      expect(norm.equivalent(ContactField.birthday, full, yearless), isFalse);
      expect(norm.equivalent(ContactField.birthday, yearless, full), isTrue);
      expect(norm.equivalent(ContactField.birthday, full, full), isTrue);
    });

    test('family names agree when equal, or when one side has none', () {
      expect(
        ContactNormaliser.namesAgree(
          ContactName.of(given: 'Ann', family: 'Cole'),
          ContactName.of(given: 'Annie', family: 'COLE'),
        ),
        isTrue,
      );
      expect(
        ContactNormaliser.namesAgree(
          ContactName.of(given: 'Ann'),
          ContactName.of(given: 'Ann', family: 'Cole'),
        ),
        isTrue,
      );
      expect(
        ContactNormaliser.namesAgree(
          ContactName.of(family: 'Cole'),
          ContactName.of(family: 'Smith'),
        ),
        isFalse,
      );
    });
  });

  test('no value shows in a toString, for the logs', () {
    final printed = [
      ContactName.of(given: 'Zebedee', family: 'Quorn'),
      ContactName.of(display: 'Zebedee Quorn'),
      ContactAddress.of(street: '9 Quorn Lane', city: 'Zebton'),
      const ContactBirthday(year: 1977, month: 11, day: 23),
      const ContactNotes('Zebedee'),
      SyncedContact({ContactField.mobile: '555 0199'}),
    ].map((v) => v.toString()).join(' ');
    for (final secret in ['Zebedee', 'Quorn', 'Zebton', '1977', '23', '0199']) {
      expect(printed, isNot(contains(secret)));
    }
  });

  test('a base round-trips through JSON', () {
    final d = SyncedContact({
      ContactField.name: ContactName.of(given: 'Ann', family: 'Cole'),
      ContactField.emails: ['a@x'],
      ContactField.homeAddress: ContactAddress.of(
        street: '1\n2',
        country: 'UK',
      ),
      ContactField.birthday: const ContactBirthday(month: 1, day: 2),
      ContactField.notes: const ContactNotes('<b>x</b>', html: true),
      ContactField.mobile: '1',
      ContactField.company: '   ',
    });
    expect(
      d.values.containsKey(ContactField.company),
      isFalse,
      reason: 'empty',
    );
    expect(SyncedContact.fromJson(d.toJson()), d);
    expect(SyncedContact.fromJson({'unknownLater': 1, 'mobile': '1'}).text(
      ContactField.mobile,
    ), '1');
  });
}
