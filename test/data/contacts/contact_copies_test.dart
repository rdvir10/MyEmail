import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/contacts/contact_copies.dart';
import 'package:myemail/domain/synced_contact.dart';

/// The merge of the copies of one person in Hadco's Contacts into the
/// synced one: every Graph contact property's rule, both ways, Outlook's
/// room, photos, Ron's answers and the fingerprint.
void main() {
  final norm = ContactNormaliser(region: 'US');

  // Copies of one person, joined by the mobile they share unless a test
  // gives them another, or none.
  OutlookCopy copy(
    String id, [
    Map<String, Object?> json = const {},
    String? photo,
  ]) => OutlookCopy(
    id: id,
    json: {
      'id': id,
      'givenName': 'Ann',
      'surname': 'Cole',
      'mobilePhone': '+1 212 555 0100',
      ...json,
    },
    photo: photo,
  );

  CopiesMerge merge(
    OutlookCopy kept,
    List<OutlookCopy> others, {
    String? keep,
    bool keepsPhoto = false,
  }) => mergeCopies(
    kept,
    others,
    keep: keep,
    keepsPhoto: keepsPhoto,
    norm: norm,
  );

  Map<String, Object?> email(String address, [String? name]) => {
    'name': name ?? address,
    'address': address,
  };

  Map<String, Object?> address({
    String? street,
    String? city,
    String? state,
    String? postalCode,
    String? country,
  }) => {
    'street': street,
    'city': city,
    'state': state,
    'postalCode': postalCode,
    'countryOrRegion': country,
  };

  group('not compared', () {
    test('ids, times, the folder, the names Outlook makes, annotations', () {
      final kept = copy('A', {
        'changeKey': 'k-1',
        'createdDateTime': '2020-01-01T00:00:00Z',
        'lastModifiedDateTime': '2026-11-01T00:00:00Z',
        'parentFolderId': 'F-1',
        'displayName': 'Ann Cole',
        'fileAs': 'Cole, Ann',
        '@odata.etag': 'W/"1"',
        'emailAddresses': [email('ann@x.example', 'Ann Cole')],
      });
      final other = copy('B', {
        'changeKey': 'k-2',
        'createdDateTime': '2021-01-01T00:00:00Z',
        'lastModifiedDateTime': '2026-11-02T00:00:00Z',
        'parentFolderId': 'F-2',
        'displayName': 'Cole, Ann (Hadco)',
        'fileAs': 'Ann Cole',
        '@odata.etag': 'W/"2"',
        '@odata.context': 'https://graph.microsoft.com/v1.0/contacts',
        // Outlook's own name for the email.
        'emailAddresses': [email('ANN@x.example', 'ann@x.example')],
      });
      final merged = merge(kept, [other]);
      expect(merged.outcome, CopiesOutcome.same);
      expect(merged.patch, isEmpty);
      expect(merged.adds, isEmpty);
      expect(merged.differences, isEmpty);
      expect(merged.fingerprint, '');
    });

    test('the name parts: the synced copy\'s stay', () {
      final merged = merge(copy('A'), [
        copy('B', {
          'givenName': 'ANN',
          'middleName': 'Beth',
          'surname': 'Cole',
          'generation': 'Jr.',
        }),
      ]);
      expect(merged.outcome, CopiesOutcome.same);
      expect(merged.patch, isEmpty);
    });

    test('no other copy: nothing to merge', () {
      final merged = merge(copy('A', {'jobTitle': 'Buyer'}), const []);
      expect(merged.outcome, CopiesOutcome.same);
      expect(merged.patch, isEmpty);
    });

    test('a copy given twice, or the synced one among the others, counts '
        'once', () {
      final merged = merge(copy('A'), [
        copy('B', {'jobTitle': 'Buyer'}),
        copy('B', {'jobTitle': 'Clerk'}),
        copy('A', {'jobTitle': 'Manager'}),
      ]);
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.adds, [
        const CopiesDetail(label: 'Job title', value: 'Buyer'),
      ]);
    });
  });

  group('single text', () {
    const texts = {
      'title': 'Title',
      'nickName': 'Nickname',
      'initials': 'Initials',
      'companyName': 'Company',
      'department': 'Department',
      'jobTitle': 'Job title',
      'officeLocation': 'Office',
      'profession': 'Profession',
      'manager': 'Manager',
      'assistantName': 'Assistant',
      'spouseName': 'Spouse',
      'businessHomePage': 'Web page',
      'yomiGivenName': 'Phonetic first name',
      'yomiSurname': 'Phonetic last name',
      'yomiCompanyName': 'Phonetic company',
    };
    for (final MapEntry(key: property, value: label) in texts.entries) {
      test('$property: the same, taken, or a difference', () {
        // Case and runs of spaces aside, the same.
        final same = merge(copy('A', {property: 'Acme  Steel'}), [
          copy('B', {property: ' acme steel '}),
          copy('C', {property: ''}),
          copy('D'),
        ]);
        expect(same.outcome, CopiesOutcome.same);
        expect(same.patch, isEmpty);
        // The synced copy has none: it takes the others' one value.
        final taken = merge(copy('A', {property: '  '}), [
          copy('B', {property: 'Acme Steel'}),
          copy('C', {property: 'ACME STEEL'}),
          copy('D'),
        ]);
        expect(taken.outcome, CopiesOutcome.adds);
        expect(taken.patch, {property: 'Acme Steel'});
        expect(taken.adds, [CopiesDetail(label: label, value: 'Acme Steel')]);
        expect(taken.differences, isEmpty);
        // Another value: a difference, each copy's shown.
        final differs = merge(copy('A', {property: 'Acme'}), [
          copy('B', {property: 'Hadco'}),
          copy('C'),
        ]);
        expect(differs.outcome, CopiesOutcome.differs);
        expect(differs.patch, isEmpty);
        expect(differs.differences, [
          CopiesDifference(
            label: label,
            kept: 'Acme',
            others: const {'B': 'Hadco', 'C': null},
          ),
        ]);
        expect(differs.fingerprint, isNotEmpty);
      });
    }

    test('two values on the others, none on the synced copy: a difference',
        () {
      final merged = merge(copy('A'), [
        copy('B', {'jobTitle': 'Buyer'}),
        copy('C', {'jobTitle': 'Manager'}),
      ]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(merged.differences.single.kept, isNull);
      expect(merged.differences.single.others, {
        'B': 'Buyer',
        'C': 'Manager',
      });
    });
  });

  group('notes', () {
    test('the same, or held in the synced copy\'s: the same', () {
      final merged = merge(
        copy('A', {'personalNotes': 'Met at the fair.\nTwo dogs.'}),
        [
          copy('B', {'personalNotes': 'met at the  fair. two dogs.'}),
          copy('C', {'personalNotes': 'Two dogs.'}),
        ],
      );
      expect(merged.outcome, CopiesOutcome.same);
    });

    test('holding the synced copy\'s and the others\': the longer taken',
        () {
      final merged = merge(copy('A', {'personalNotes': 'Two dogs.'}), [
        copy('B', {'personalNotes': 'Met at the fair. Two dogs.'}),
        copy('C', {'personalNotes': 'Met at the fair.'}),
      ]);
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.patch, {'personalNotes': 'Met at the fair. Two dogs.'});
      expect(merged.adds, [
        const CopiesDetail(label: 'Notes', value: 'Met at the fair. Two dogs.'),
      ]);
      // With none of its own, the synced copy takes the one holding all.
      final none = merge(copy('A'), [
        copy('B', {'personalNotes': 'Two dogs.'}),
        copy('C', {'personalNotes': 'Two dogs. A cat.'}),
      ]);
      expect(none.patch, {'personalNotes': 'Two dogs. A cat.'});
    });

    test('held only as whole sentences or lines', () {
      CopiesOutcome held(String mine, String theirs) => merge(
        copy('A', {'personalNotes': mine}),
        [
          copy('B', {'personalNotes': theirs}),
        ],
      ).outcome;
      // A line, a sentence, or a run of them, punctuation aside.
      const same = CopiesOutcome.same;
      expect(held('Met at the fair.\nLikes golf.', 'likes golf'), same);
      expect(held('Met at the fair. Likes golf!', 'Likes golf.'), same);
      expect(
        held(
          'Met at the fair. Likes golf. Two dogs.',
          'Met at the fair. Likes golf.',
        ),
        same,
      );
      // Words inside a sentence, or a word inside a word: not held.
      const differs = CopiesOutcome.differs;
      expect(held('Not a VIP', 'VIP'), differs);
      expect(held('Do not call', 'Call'), differs);
      expect(held('Met at the fair.', 'the fair'), differs);
      expect(held("Martin's partner", 'art'), differs);
      // Nor, the other way, is the longer taken.
      expect(held('VIP', 'Not a VIP'), differs);
    });

    test('notes neither holds: a difference, a long note not shown', () {
      final merged = merge(copy('A', {'personalNotes': 'Two dogs.'}), [
        copy('B', {'personalNotes': 'A cat.'}),
        // C holds the synced copy's, as a line, but not B's.
        copy('C', {'personalNotes': 'Moved to Ohio.\nTwo dogs.'}),
        copy('D', {'personalNotes': 'x' * 61}),
      ]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(merged.differences, [
        const CopiesDifference(
          label: 'Notes',
          kept: 'Two dogs.',
          others: {
            'B': 'A cat.',
            'C': '(long note)',
            'D': '(long note)',
          },
        ),
      ]);
    });
  });

  group('birthday', () {
    test('by its day', () {
      final same = merge(copy('A', {'birthday': '1980-07-04T11:59:00Z'}), [
        copy('B', {'birthday': '1980-07-04T00:00:00Z'}),
      ]);
      expect(same.outcome, CopiesOutcome.same);
      final taken = merge(copy('A'), [
        copy('B', {'birthday': '1980-07-04T11:59:00Z'}),
      ]);
      expect(taken.patch, {'birthday': '1980-07-04T11:59:00Z'});
      expect(taken.adds, [
        const CopiesDetail(label: 'Birthday', value: '1980-07-04'),
      ]);
      final differs = merge(copy('A', {'birthday': '1980-07-04T11:59:00Z'}), [
        copy('B', {'birthday': '1980-07-05T11:59:00Z'}),
      ]);
      expect(differs.differences, [
        const CopiesDifference(
          label: 'Birthday',
          kept: '1980-07-04',
          others: {'B': '1980-07-05'},
        ),
      ]);
    });

    test('the year another copy has, on the same day, is taken', () {
      // Outlook keeps a birthday without a year in 1604.
      final merged = merge(copy('A', {'birthday': '1604-07-04T11:59:00Z'}), [
        copy('B', {'birthday': '1980-07-04T11:59:00Z'}),
      ]);
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.patch, {'birthday': '1980-07-04T11:59:00Z'});
      // The other way round, the synced copy's holds it already.
      final kept = merge(copy('A', {'birthday': '1980-07-04T11:59:00Z'}), [
        copy('B', {'birthday': '1604-07-04T11:59:00Z'}),
      ]);
      expect(kept.outcome, CopiesOutcome.same);
    });
  });

  group('mobile phone', () {
    test('by its number', () {
      final same = merge(copy('A', {'mobilePhone': '(212) 555-0100'}), [
        copy('B', {'mobilePhone': '+1 212 555 0100'}),
      ]);
      expect(same.outcome, CopiesOutcome.same);
      // Joined by an email, the synced copy having none: taken from a copy
      // whose mobile another copy has too.
      final joined = {
        'emailAddresses': [email('ann@x.example')],
      };
      final taken = merge(copy('A', {...joined, 'mobilePhone': null}), [
        copy('B', {...joined, 'mobilePhone': '+1 212 555 0199'}),
        copy('C', {'mobilePhone': '(212) 555-0199'}),
      ]);
      expect(taken.outcome, CopiesOutcome.adds);
      expect(taken.patch, {'mobilePhone': '+1 212 555 0199'});
      expect(taken.adds, [
        const CopiesDetail(label: 'Mobile', value: '+1 212 555 0199'),
      ]);
      final differs = merge(copy('A', joined), [
        copy('B', {...joined, 'mobilePhone': '+1 212 555 0199'}),
      ]);
      expect(differs.differences, [
        const CopiesDifference(
          label: 'Mobile',
          kept: '+1 212 555 0100',
          others: {'B': '+1 212 555 0199'},
        ),
      ]);
    });
  });

  group('lists within Outlook\'s room', () {
    for (final (property, label) in [
      ('businessPhones', 'Work phones'),
      ('homePhones', 'Home phones'),
    ]) {
      test('$property: two, by number, the synced copy\'s first', () {
        final same = merge(copy('A', {property: ['(212) 555-0101']}), [
          copy('B', {property: ['+1 212 555 0101']}),
        ]);
        expect(same.outcome, CopiesOutcome.same);
        final added = merge(copy('A', {property: ['(212) 555-0101']}), [
          copy('B', {property: ['+1 212 555 0102', '212-555-0101']}),
        ]);
        expect(added.outcome, CopiesOutcome.adds);
        expect(added.patch, {
          property: ['(212) 555-0101', '+1 212 555 0102'],
        });
        expect(added.adds, [
          CopiesDetail(label: label, value: '+1 212 555 0102'),
        ]);
        // A third number does not fit.
        final over = merge(copy('A', {property: ['(212) 555-0101']}), [
          copy('B', {property: ['+1 212 555 0102']}),
          copy('C', {property: ['+1 212 555 0103']}),
        ]);
        expect(over.outcome, CopiesOutcome.differs);
        expect(over.differences, [
          CopiesDifference(
            label: label,
            kept: '(212) 555-0101',
            others: const {'B': '+1 212 555 0102', 'C': '+1 212 555 0103'},
          ),
        ]);
      });
    }

    test('emailAddresses: three, by address, the synced copy\'s first with '
        'their names', () {
      final kept = copy('A', {
        'emailAddresses': [email('ann@x.example', 'Ann Cole')],
      });
      final added = merge(kept, [
        copy('B', {
          'emailAddresses': [
            email('ANN@x.example'),
            email('ann@home.example', 'Ann at home'),
          ],
        }),
        copy('C', {
          'emailAddresses': [email('ann@y.example')],
        }),
      ]);
      expect(added.outcome, CopiesOutcome.adds);
      expect(added.patch, {
        'emailAddresses': [
          email('ann@x.example', 'Ann Cole'),
          email('ann@home.example', 'Ann at home'),
          email('ann@y.example'),
        ],
      });
      expect(added.adds, [
        const CopiesDetail(label: 'Emails', value: 'ann@home.example'),
        const CopiesDetail(label: 'Emails', value: 'ann@y.example'),
      ]);
      // A fourth does not fit.
      final over = merge(kept, [
        copy('B', {
          'emailAddresses': [
            email('ann@home.example'),
            email('ann@y.example'),
            email('ann@z.example'),
          ],
        }),
      ]);
      expect(over.outcome, CopiesOutcome.differs);
      expect(over.differences, [
        const CopiesDifference(
          label: 'Emails',
          kept: 'ann@x.example',
          others: {'B': 'ann@home.example, ann@y.example, ann@z.example'},
        ),
      ]);
    });

    test('imAddresses: three', () {
      final added = merge(copy('A', {'imAddresses': ['ann@chat.example']}), [
        copy('B', {
          'imAddresses': ['ANN@chat.example', 'sip:ann@x.example', 'ann.c'],
        }),
      ]);
      expect(added.outcome, CopiesOutcome.adds);
      expect(added.patch, {
        'imAddresses': ['ann@chat.example', 'sip:ann@x.example', 'ann.c'],
      });
      final over = merge(copy('A', {'imAddresses': ['ann@chat.example']}), [
        copy('B', {
          'imAddresses': ['sip:ann@x.example', 'ann.c', 'ann.d'],
        }),
      ]);
      expect(over.outcome, CopiesOutcome.differs);
      expect(over.differences.single.label, 'IM names');
    });

    test('an answer fills the room: the chosen copy\'s first, then the '
        'synced copy\'s, then the others\'', () {
      final kept = copy('A', {
        'emailAddresses': [email('a@x.example'), email('b@x.example')],
      });
      final other = copy('B', {
        'emailAddresses': [email('c@x.example'), email('d@x.example')],
      });
      final third = copy('C', {
        'emailAddresses': [email('e@x.example')],
      });
      expect(merge(kept, [other, third]).outcome, CopiesOutcome.differs);
      final mine = merge(kept, [other, third], keep: 'A');
      expect(mine.patch, {
        'emailAddresses': [
          email('a@x.example'),
          email('b@x.example'),
          email('c@x.example'),
        ],
      });
      expect(mine.adds, [
        const CopiesDetail(label: 'Emails', value: 'c@x.example'),
      ]);
      final theirs = merge(kept, [other, third], keep: 'C');
      expect(theirs.patch, {
        'emailAddresses': [
          email('e@x.example'),
          email('a@x.example'),
          email('b@x.example'),
        ],
      });
      expect(merge(kept, [other, third], keep: 'B').patch, {
        'emailAddresses': [
          email('c@x.example'),
          email('d@x.example'),
          email('a@x.example'),
        ],
      });
    });

    test('the others by id, never as given', () {
      final kept = copy('A', {
        'emailAddresses': [email('a@x.example'), email('b@x.example')],
      });
      final b = copy(
        'B',
        {
          'emailAddresses': [email('c@x.example')],
          'companyName': 'Acme Steel',
        },
        'p1',
      );
      final c = copy(
        'C',
        {
          'emailAddresses': [email('d@x.example')],
          'companyName': 'ACME STEEL',
        },
        'p1',
      );
      for (final keep in [null, 'A']) {
        final given = merge(kept, [b, c], keep: keep);
        final turned = merge(kept, [c, b], keep: keep);
        expect(turned.patch, given.patch, reason: keep);
        expect(turned.photoFrom, given.photoFrom, reason: keep);
        expect(turned.fingerprint, given.fingerprint, reason: keep);
      }
      final answered = merge(kept, [c, b], keep: 'A');
      expect(answered.patch, {
        'emailAddresses': [
          email('a@x.example'),
          email('b@x.example'),
          email('c@x.example'),
        ],
        'companyName': 'Acme Steel',
      });
      expect(answered.photoFrom, 'B');
    });

    test('children and categories have no room: never a difference', () {
      final merged = merge(
        copy('A', {
          'children': ['Tom'],
          'categories': ['Customers'],
        }),
        [
          copy('B', {
            'children': ['tom', 'Sue', 'Al', 'Bo'],
            'categories': ['customers', 'Suppliers', 'Steel', 'Ohio'],
          }),
          copy('C', {
            'categories': ['Holiday cards'],
          }),
        ],
      );
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.patch, {
        'children': ['Tom', 'Sue', 'Al', 'Bo'],
        'categories': [
          'Customers',
          'Suppliers',
          'Steel',
          'Ohio',
          'Holiday cards',
        ],
      });
      expect(
        [for (final d in merged.adds) d.label],
        [
          'Children',
          'Children',
          'Children',
          'Categories',
          'Categories',
          'Categories',
          'Categories',
        ],
      );
      final same = merge(copy('A', {'categories': ['Customers']}), [
        copy('B', {'categories': ['CUSTOMERS']}),
      ]);
      expect(same.outcome, CopiesOutcome.same);
    });
  });

  group('addresses', () {
    for (final (property, label) in [
      ('businessAddress', 'Work address'),
      ('homeAddress', 'Home address'),
      ('otherAddress', 'Other address'),
    ]) {
      test('$property: by its words, the country aside', () {
        final kept = copy('A', {
          property: address(
            street: '1200 Industrial Pkwy.\nBuilding 7',
            city: 'Springfield',
            state: 'IL',
            postalCode: '62701',
            country: 'United States',
          ),
        });
        for (final country in [null, 'USA', 'U.S.A.', 'US', 'America']) {
          final same = merge(kept, [
            copy('B', {
              property: address(
                street: '1200 industrial pkwy, building 7',
                city: 'SPRINGFIELD',
                state: 'IL',
                postalCode: '62701',
                country: country,
              ),
            }),
          ]);
          expect(same.outcome, CopiesOutcome.same, reason: '$country');
        }
        // Lines moved between the parts are the same words.
        final moved = merge(kept, [
          copy('B', {
            property: address(
              street: '1200 Industrial Pkwy, Building 7, Springfield IL',
              postalCode: '62701',
            ),
          }),
        ]);
        expect(moved.outcome, CopiesOutcome.same);
        // The synced copy has none: the address taken whole.
        final whole = address(
          street: '1200 Industrial Pkwy.\nBuilding 7',
          city: 'Springfield',
          state: 'IL',
          postalCode: '62701',
        );
        final taken = merge(copy('A', {property: address()}), [
          copy('B', {property: whole}),
        ]);
        expect(taken.outcome, CopiesOutcome.adds);
        expect(taken.patch, {property: whole});
        expect(taken.adds, [
          CopiesDetail(
            label: label,
            value: '1200 Industrial Pkwy., Building 7, Springfield, IL, '
                '62701',
          ),
        ]);
        // Another address: a difference.
        final differs = merge(kept, [
          copy('B', {
            property: address(street: '5 Main St', city: 'Peoria'),
          }),
        ]);
        expect(differs.outcome, CopiesOutcome.differs);
        expect(differs.differences.single.label, label);
        expect(differs.differences.single.others, {'B': '5 Main St, Peoria'});
        // A country of its own is a difference too.
        final canada = merge(kept, [
          copy('B', {
            property: address(
              street: '1200 Industrial Pkwy\nBuilding 7',
              city: 'Springfield',
              state: 'IL',
              postalCode: '62701',
              country: 'Canada',
            ),
          }),
        ]);
        expect(canada.outcome, CopiesOutcome.differs);
      });
    }
  });

  group('the country in an address', () {
    test('only in its own part, or as the last words', () {
      Map<String, Object?> at(Map<String, Object?> a) => {
        'businessAddress': a,
      };
      final plaza = merge(copy('A', at(address(street: '1 Plaza'))), [
        copy('B', at(address(street: '1 America Plaza'))),
      ]);
      expect(plaza.outcome, CopiesOutcome.differs);
      final route = merge(copy('A', at(address(street: '100 Route 1'))), [
        copy('B', at(address(street: '100 US Route 1'))),
      ]);
      expect(route.outcome, CopiesOutcome.differs);
      final last = merge(
        copy(
          'A',
          at(
            address(
              street: '1 Main St\nSpringfield IL 62701',
              country: 'United States of America',
            ),
          ),
        ),
        [
          copy('B', at(address(street: '1 Main St, Springfield IL 62701 USA'))),
          copy('C', at(address(street: '1 Main St\nSpringfield IL 62701 US'))),
        ],
      );
      expect(last.outcome, CopiesOutcome.same);
    });
  });

  group('photo', () {
    test('none, or the same, on the others: the same', () {
      final merged = merge(copy('A', const {}, 'p1'), [
        copy('B'),
        copy('C', const {}, 'p1'),
      ]);
      expect(merged.outcome, CopiesOutcome.same);
      expect(merged.photoFrom, isNull);
    });

    test('the synced copy has none: it takes the first other copy\'s, '
        'in id order', () {
      final merged = merge(copy('A'), [
        copy('B'),
        copy('D', const {}, 'p1'),
        copy('C', const {}, 'p2'),
      ]);
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.photoFrom, 'C');
      expect(merged.patch, isEmpty);
      expect(merged.adds, [
        const CopiesDetail(label: 'Photo', value: 'a photo'),
      ]);
      expect(merged.differences, isEmpty);
    });

    test('never a difference (3.22.1): the synced copy\'s photo stays, '
        'whatever the others\' are', () {
      // Hadco's tablet: nearly every contact has a photo, and no two
      // copies' are alike.
      final mine = merge(copy('A', const {}, 'p1'), [
        copy('B', const {}, 'p2'),
        copy('C', const {}, 'p3'),
      ]);
      expect(mine.outcome, CopiesOutcome.same);
      expect(mine.photoFrom, isNull);
      expect(mine.differences, isEmpty);
      expect(mine.fingerprint, '');
      expect(mine.adds, isEmpty);
    });

    test('an answer never touches the photo: the synced copy keeps its '
        "own, or takes the first other copy's", () {
      final kept = copy('A', {'jobTitle': 'Buyer'}, 'p1');
      final other = copy('B', {'jobTitle': 'Manager'}, 'p2');
      final bare = copy('C', {'jobTitle': 'Clerk'});
      final unanswered = merge(kept, [other, bare]);
      expect([for (final d in unanswered.differences) d.label], [
        'Job title',
      ]);
      for (final keep in [null, 'A', 'B', 'C']) {
        final answered = merge(kept, [other, bare], keep: keep);
        expect(answered.photoFrom, isNull, reason: keep);
        expect(
          answered.adds.where((d) => d.label == 'Photo'),
          isEmpty,
          reason: keep,
        );
      }
      // The synced copy with none: the first other copy's, whatever the
      // answer.
      final none = copy('A', {'jobTitle': 'Buyer'});
      for (final keep in [null, 'A', 'B', 'D']) {
        expect(
          merge(none, [other, copy('D', const {}, 'p3')], keep: keep)
              .photoFrom,
          'B',
          reason: keep,
        );
      }
    });

    test("where the photo was a difference Ron saw (keepsPhoto: a 3.22.0 "
        "listing), another copy's answer brings its photo", () {
      final kept = copy('A', {'jobTitle': 'Buyer'}, 'p1');
      final other = copy('B', {'jobTitle': 'Manager'}, 'p2');
      final bare = copy('C', {'jobTitle': 'Clerk'});
      final theirs = merge(kept, [other, bare], keep: 'B', keepsPhoto: true);
      expect(theirs.photoFrom, 'B');
      expect(theirs.outcome, CopiesOutcome.adds);
      expect(
        theirs.adds.where((d) => d.label == 'Photo'),
        [const CopiesDetail(label: 'Photo', value: 'a photo')],
      );
      // The synced copy's, or a copy with none: the synced copy's stays.
      for (final keep in ['A', 'C']) {
        expect(
          merge(kept, [other, bare], keep: keep, keepsPhoto: true).photoFrom,
          isNull,
          reason: keep,
        );
      }
      // With nothing else differing, too.
      final alike = merge(
        copy('A', const {}, 'p1'),
        [copy('B', const {}, 'p2')],
        keep: 'B',
        keepsPhoto: true,
      );
      expect(alike.outcome, CopiesOutcome.adds);
      expect(alike.photoFrom, 'B');
      expect(alike.fingerprint, '');
      // The synced copy with none: the chosen copy's, not the first.
      final none = copy('A', {'jobTitle': 'Buyer'});
      expect(
        merge(
          none,
          [other, copy('D', const {}, 'p3')],
          keep: 'D',
          keepsPhoto: true,
        ).photoFrom,
        'D',
      );
    });
  });

  group('other details', () {
    test('a property the merge does not know, on another copy: a difference',
        () {
      final merged = merge(copy('A'), [
        copy('B', {'weddingAnniversary': '2001-05-05'}),
      ]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(merged.patch, isEmpty);
      expect(merged.differences, [
        const CopiesDifference(
          label: 'Other details',
          others: {'B': 'weddingAnniversary: 2001-05-05'},
        ),
      ]);
      // Held differently too, a list of parts shown as one line.
      final extended = merge(
        copy('A', {
          'singleValueExtendedProperties': [
            {'id': 'String {x} Name Colour', 'value': 'Blue'},
          ],
        }),
        [
          copy('B', {
            'singleValueExtendedProperties': [
              {'value': 'Red', 'id': 'String {x} Name Colour'},
            ],
          }),
        ],
      );
      expect(extended.differences, [
        const CopiesDifference(
          label: 'Other details',
          kept: 'singleValueExtendedProperties: String {x} Name Colour, Blue',
          others: {
            'B': 'singleValueExtendedProperties: String {x} Name Colour, Red',
          },
        ),
      ]);
    });

    test('the same value, nothing, or on the synced copy alone: the same',
        () {
      final merged = merge(
        copy('A', {
          'gender': 'female',
          'extra': {'a': '1', 'b': '2'},
          'isFavorite': true,
        }),
        [
          copy('B', {
            'gender': 'female',
            'extra': {'b': '2', 'a': '1', 'c': ''},
          }),
          copy('C', {'gender': '', 'extra': null}),
        ],
      );
      expect(merged.outcome, CopiesOutcome.same);
    });
  });

  group('details only Outlook keeps', () {
    // Read as Graph gives them, with a read that asks for them: single-value
    // extended properties, by their MAPI property tags.
    Map<String, Object?> kept(Map<String, Object?> values) => {
      'singleValueExtendedProperties': [
        for (final MapEntry(:key, :value) in values.entries)
          {'id': key, 'value': value},
      ],
    };

    const numbers = {
      'String 0x3A24': 'Business fax',
      'String 0x3A25': 'Home fax',
      'String 0x3A23': 'Other fax',
      'String 0x3A21': 'Pager',
      'String 0x3A1E': 'Car phone',
      'String 0x3A1F': 'Other phone',
      'String 0x3A1A': 'Primary phone',
      'String 0x3A57': 'Company main phone',
      'String 0x3A2E': "Assistant's phone",
      'String 0x3A02': 'Callback',
      'String 0x3A1D': 'Radio phone',
      'String 0x3A2C': 'Telex',
      'String 0x3A4B': 'TTY/TDD phone',
      'String 0x3A2D': 'ISDN',
    };
    for (final MapEntry(key: id, value: label) in numbers.entries) {
      test('$label: the same by its number, taken, or a difference', () {
        final same = merge(copy('A', kept({id: '(212) 555-0199'})), [
          copy('B', kept({id: '+1 212 555 0199'})),
          copy('C'),
        ]);
        expect(same.outcome, CopiesOutcome.same);
        expect(same.patch, isEmpty);
        // Only another copy has it: written to the synced copy as Graph
        // takes it, an extended property by its id.
        final taken = merge(copy('A'), [
          copy('B', kept({id: '+1 212 555 0199'})),
        ]);
        expect(taken.outcome, CopiesOutcome.adds);
        expect(taken.patch, {
          'singleValueExtendedProperties': [
            {'id': id, 'value': '+1 212 555 0199'},
          ],
        });
        expect(taken.adds, [
          CopiesDetail(label: label, value: '+1 212 555 0199'),
        ]);
        final differs = merge(copy('A', kept({id: '+1 212 555 0100'})), [
          copy('B', kept({id: '+1 212 555 0199'})),
        ]);
        expect(differs.outcome, CopiesOutcome.differs);
        expect(differs.patch, isEmpty);
        expect(differs.differences, [
          CopiesDifference(
            label: label,
            kept: '+1 212 555 0100',
            others: const {'B': '+1 212 555 0199'},
          ),
        ]);
      });
    }

    test('texts by their words: personal web page, hobbies, location', () {
      for (final (id, label) in [
        ('String 0x3A50', 'Personal web page'),
        ('String 0x3A43', 'Hobbies'),
        ('String 0x3A0D', 'Location'),
      ]) {
        final same = merge(copy('A', kept({id: 'Golf  and Chess'})), [
          copy('B', kept({id: ' golf and chess '})),
        ]);
        expect(same.outcome, CopiesOutcome.same, reason: label);
        final taken = merge(copy('A'), [
          copy('B', kept({id: 'Golf'})),
        ]);
        expect(taken.patch, {
          'singleValueExtendedProperties': [
            {'id': id, 'value': 'Golf'},
          ],
        }, reason: label);
        expect(taken.adds, [CopiesDetail(label: label, value: 'Golf')]);
        final differs = merge(copy('A', kept({id: 'Golf'})), [
          copy('B', kept({id: 'Chess'})),
        ]);
        expect(differs.differences, [
          CopiesDifference(label: label, kept: 'Golf', others: const {
            'B': 'Chess',
          }),
        ], reason: label);
      }
    });

    test('PO boxes, user fields and ID fields, by their words', () {
      const address = '{00062004-0000-0000-C000-000000000046}';
      for (final (id, label) in [
        ('String $address Id 0x804A', 'Work PO box'),
        ('String 0x3A5E', 'Home PO box'),
        ('String 0x3A64', 'Other PO box'),
        ('String 0x3A00', 'Account'),
        ('String 0x3A4A', 'Customer ID'),
        ('String 0x3A07', 'Government ID'),
        ('String 0x3A10', 'Organizational ID'),
        ('String 0x3A47', 'Referred by'),
        ('String 0x3A0C', 'Language'),
        ('String 0x3A49', 'Computer network name'),
        ('String 0x3A4C', 'FTP site'),
        ('String $address Id 0x804F', 'User 1'),
        ('String $address Id 0x8050', 'User 2'),
        ('String $address Id 0x8051', 'User 3'),
        ('String $address Id 0x8052', 'User 4'),
      ]) {
        final same = merge(copy('A', kept({id: 'Box  12'})), [
          copy('B', kept({id: ' box 12 '})),
        ]);
        expect(same.outcome, CopiesOutcome.same, reason: label);
        final taken = merge(copy('A'), [
          copy('B', kept({id: 'Box 12'})),
        ]);
        expect(taken.patch, {
          'singleValueExtendedProperties': [
            {'id': id, 'value': 'Box 12'},
          ],
        }, reason: label);
        expect(taken.adds, [CopiesDetail(label: label, value: 'Box 12')]);
        final differs = merge(copy('A', kept({id: 'Box 12'})), [
          copy('B', kept({id: 'Box 99'})),
        ]);
        expect(differs.differences, [
          CopiesDifference(label: label, kept: 'Box 12', others: const {
            'B': 'Box 99',
          }),
        ], reason: label);
      }
    });

    test('a named id as Exchange writes it back, the set and the number in '
        'small letters, is the same detail', () {
      final merged = merge(
        copy('A', kept({
          'String {00062004-0000-0000-C000-000000000046} Id 0x804F': 'Gold',
        })),
        [
          copy('B', kept({
            'String {00062004-0000-0000-c000-000000000046} Id 0x804f': 'gold',
          })),
        ],
      );
      expect(merged.outcome, CopiesOutcome.same);
      final taken = merge(copy('A'), [
        copy('B', kept({
          'string {00062004-0000-0000-c000-000000000046} id 0x804a': 'PO 7',
        })),
      ]);
      expect(taken.patch, {
        'singleValueExtendedProperties': [
          {
            'id': 'String {00062004-0000-0000-C000-000000000046} Id 0x804A',
            'value': 'PO 7',
          },
        ],
      });
    });

    test('the anniversary, by its day', () {
      const id = 'SystemTime 0x3A41';
      final same = merge(copy('A', kept({id: '2001-05-05T00:00:00Z'})), [
        copy('B', kept({id: '2001-05-05T11:59:00Z'})),
      ]);
      expect(same.outcome, CopiesOutcome.same);
      final taken = merge(copy('A'), [
        copy('B', kept({id: '2001-05-05T11:59:00Z'})),
      ]);
      expect(taken.patch, {
        'singleValueExtendedProperties': [
          {'id': id, 'value': '2001-05-05T11:59:00Z'},
        ],
      });
      expect(taken.adds, [
        const CopiesDetail(label: 'Anniversary', value: '2001-05-05'),
      ]);
      final differs = merge(copy('A', kept({id: '2001-05-05T11:59:00Z'})), [
        copy('B', kept({id: '2002-05-05T11:59:00Z'})),
      ]);
      expect(differs.differences, [
        const CopiesDifference(
          label: 'Anniversary',
          kept: '2001-05-05',
          others: {'B': '2002-05-05'},
        ),
      ]);
    });

    test('an id as Exchange writes it back, small letters and no leading '
        'zeros, is the same detail', () {
      final same = merge(copy('A', kept({'String 0x3A24': '212 555 0199'})), [
        copy('B', kept({'string 0x3a24': '(212) 555-0199'})),
      ]);
      expect(same.outcome, CopiesOutcome.same);
      final taken = merge(copy('A'), [
        copy('B', kept({'String 0x3a02': '212 555 0199'})),
      ]);
      expect(taken.patch, {
        'singleValueExtendedProperties': [
          {'id': 'String 0x3A02', 'value': '212 555 0199'},
        ],
      });
    });

    test('several at once go in one list; any other extended property is '
        'still Other details', () {
      final merged = merge(copy('A'), [
        copy(
          'B',
          kept({
            'String 0x3A24': '212 555 0101',
            'String {x} Name Colour': 'Red',
            'SystemTime 0x3A41': '2001-05-05T11:59:00Z',
          }),
        ),
      ]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(merged.differences, [
        const CopiesDifference(
          label: 'Other details',
          others: {
            'B': 'singleValueExtendedProperties: String {x} Name Colour, Red',
          },
        ),
      ]);
      // Without it, the two are added in one list.
      final added = merge(copy('A'), [
        copy(
          'B',
          kept({
            'String 0x3A24': '212 555 0101',
            'SystemTime 0x3A41': '2001-05-05T11:59:00Z',
          }),
        ),
      ]);
      expect(added.outcome, CopiesOutcome.adds);
      expect(added.patch, {
        'singleValueExtendedProperties': [
          {'id': 'String 0x3A24', 'value': '212 555 0101'},
          {'id': 'SystemTime 0x3A41', 'value': '2001-05-05T11:59:00Z'},
        ],
      });
    });

    test("Keep these on a copy with another extended property (Other "
        'details) and a detail only Outlook keeps writes both, one never in '
        "the other's place", () {
      final merged = merge(copy('A'), [
        copy(
          'B',
          kept({
            'String {x} Name Colour': 'Red',
            'String 0x3A24': '212 555 0101',
          }),
        ),
      ], keep: 'B');
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.patch, {
        'singleValueExtendedProperties': [
          {'id': 'String {x} Name Colour', 'value': 'Red'},
          {'id': 'String 0x3A24', 'value': '212 555 0101'},
        ],
      });
    });

    test("Ron's answer: another copy's takes its value of what differs, the "
        "synced copy's keeps its own", () {
      final a = copy(
        'A',
        kept({'String 0x3A24': '212 555 0100', 'String 0x3A43': 'Golf'}),
      );
      final b = copy(
        'B',
        kept({'String 0x3A24': '212 555 0199', 'String 0x3A43': 'golf'}),
      );
      expect(merge(a, [b]).differences, [
        const CopiesDifference(
          label: 'Business fax',
          kept: '212 555 0100',
          others: {'B': '212 555 0199'},
        ),
      ]);
      expect(merge(a, [b], keep: 'B').patch, {
        'singleValueExtendedProperties': [
          {'id': 'String 0x3A24', 'value': '212 555 0199'},
        ],
      });
      final mine = merge(a, [b], keep: 'A');
      expect(mine.outcome, CopiesOutcome.same);
      expect(mine.patch, isEmpty);
    });

    test('from a copy joined only by an email: a fax is taken, but an '
        'anniversary is a difference, as a birthday is', () {
      final joined = {
        'mobilePhone': null,
        'emailAddresses': [email('ann@x.example')],
      };
      final merged = merge(copy('A', joined), [
        copy('B', {
          ...joined,
          ...kept({
            'String 0x3A24': '212 555 0101',
            'SystemTime 0x3A41': '2001-05-05T11:59:00Z',
          }),
        }),
      ]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(merged.differences, [
        const CopiesDifference(
          label: 'Anniversary',
          others: {'B': '2001-05-05'},
        ),
      ]);
      expect(merge(copy('A', joined), [
        copy('B', {
          ...joined,
          ...kept({'String 0x3A24': '212 555 0101'}),
        }),
      ]).outcome, CopiesOutcome.adds);
    });
  });

  group('the email slots of a whole read', () {
    // A whole read repeats the first three emails, Outlook's names and
    // all, as primary, secondary and tertiaryEmailAddress.
    Map<String, Object?> read(List<Map<String, Object?>> emails) => {
      'emailAddresses': emails,
      'primaryEmailAddress': emails.isNotEmpty ? emails[0] : null,
      'secondaryEmailAddress': emails.length > 1 ? emails[1] : null,
      'tertiaryEmailAddress': emails.length > 2 ? emails[2] : null,
    };

    test('they are the copy\'s emails, never written', () {
      final added = merge(copy('A', read([email('ann@x.example')])), [
        copy('B', read([email('ann@x.example'), email('ann@work.example')])),
      ]);
      expect(added.outcome, CopiesOutcome.adds);
      expect(added.patch, {
        'emailAddresses': [email('ann@x.example'), email('ann@work.example')],
      });
      // Outlook's names for them aside, the same.
      final names = merge(
        copy('A', read([email('ann@x.example', 'Ann Cole')])),
        [
          copy('B', read([email('ann@x.example', 'ann@x.example')])),
        ],
      );
      expect(names.outcome, CopiesOutcome.same);
      // In another order, the same.
      final order = merge(
        copy('A', read([email('a@x.example'), email('b@x.example')])),
        [
          copy('B', read([email('b@x.example'), email('a@x.example')])),
        ],
      );
      expect(order.outcome, CopiesOutcome.same);
    });

    test('an address only in a slot is an email, never lost', () {
      final merged = merge(
        copy('A', {
          'emailAddresses': [email('ann@x.example')],
        }),
        [
          copy('B', {
            'emailAddresses': [email('ann@x.example')],
            'secondaryEmailAddress': email('ann@slot.example'),
          }),
        ],
      );
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.patch, {
        'emailAddresses': [email('ann@x.example'), email('ann@slot.example')],
      });
    });

    test('another copy\'s answer leaves the synced copy\'s first email', () {
      final merged = merge(
        copy('A', {
          ...read([email('a@x.example'), email('b@x.example')]),
          'jobTitle': 'Buyer',
        }),
        [
          copy('B', {
            ...read([email('c@x.example')]),
            'jobTitle': 'Manager',
          }),
        ],
        keep: 'B',
      );
      expect(merged.patch, {
        'emailAddresses': [
          email('a@x.example'),
          email('b@x.example'),
          email('c@x.example'),
        ],
        'jobTitle': 'Manager',
      });
    });

    test('a slot that is not an email is a difference', () {
      final merged = merge(copy('A', read([email('ann@x.example')])), [
        copy('B', {
          ...read([email('ann@x.example')]),
          'secondaryEmailAddress': 'ann@slot.example',
        }),
      ]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(merged.differences.single.label, 'Emails');
    });
  });

  group('copies joined by an email or a mobile', () {
    test('another of the name, sharing neither: Same name only', () {
      final ann = copy('A', {
        'mobilePhone': null,
        'emailAddresses': [email('ann@x.example')],
      });
      final other = copy(
        'B',
        {
          'mobilePhone': null,
          'emailAddresses': [email('ann.cole@other.example')],
          'homeAddress': address(street: '9 Elm St', city: 'Oakland'),
          'jobTitle': 'Clerk',
        },
        'p1',
      );
      final copyOfAnn = copy('C', {
        'mobilePhone': null,
        'emailAddresses': [email('ANN@x.example')],
        'jobTitle': 'Buyer',
      });
      final merged = merge(ann, [other, copyOfAnn]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(
        merged.differences.first,
        const CopiesDifference(
          label: 'Same name only',
          others: {'B': 'no email or mobile in common', 'C': null},
        ),
      );
      // Nothing to write, whatever the answer: the synced copy's, the
      // other's, or one joined to it.
      for (final keep in [null, 'A', 'B', 'C']) {
        final answered = merge(ann, [other, copyOfAnn], keep: keep);
        expect(answered.outcome, CopiesOutcome.differs, reason: keep);
        expect(answered.patch, isEmpty, reason: keep);
        expect(answered.photoFrom, isNull, reason: keep);
        expect(answered.adds, isEmpty, reason: keep);
        expect(answered.differences, merged.differences, reason: keep);
        expect(answered.fingerprint, merged.fingerprint, reason: keep);
      }
    });

    test('joined through another copy that is', () {
      // A and B share an email, B and C a mobile.
      final merged = merge(
        copy('A', {
          'mobilePhone': null,
          'emailAddresses': [email('ann@x.example')],
        }),
        [
          copy('C', {'mobilePhone': '+1 212 555 0199', 'jobTitle': 'Buyer'}),
          copy('B', {
            'mobilePhone': '212-555-0199',
            'emailAddresses': [email('ann@x.example')],
          }),
        ],
      );
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.patch['jobTitle'], 'Buyer');
    });

    test('a synced copy with no email or mobile joins none', () {
      final merged = merge(copy('A', {'mobilePhone': null}), [
        copy('B', {'mobilePhone': null, 'jobTitle': 'Buyer'}),
      ]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(merged.differences.first.label, 'Same name only');
    });
  });

  group('a mobile or birthday from a copy joined only by an email', () {
    test('a difference, not taken', () {
      // A mother and her daughter of one name, on the family's email.
      OutlookCopy maria(String id, Map<String, Object?> json) => OutlookCopy(
        id: id,
        json: {
          'id': id,
          'givenName': 'Maria',
          'surname': 'Lopez',
          'emailAddresses': [email('lopez@fam.example')],
          ...json,
        },
      );
      final merged = merge(maria('M', const {}), [
        maria('D', {
          'mobilePhone': '+1 212 555 0199',
          'birthday': '2001-03-02T11:59:00Z',
        }),
      ]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(merged.differences, [
        const CopiesDifference(
          label: 'Mobile',
          others: {'D': '+1 212 555 0199'},
        ),
        const CopiesDifference(label: 'Birthday', others: {'D': '2001-03-02'}),
      ]);
      expect(merged.patch, isEmpty);
    });

    test('taken from a copy whose mobile another copy has', () {
      final joined = {
        'emailAddresses': [email('ann@x.example')],
      };
      final merged = merge(copy('A', {...joined, 'mobilePhone': null}), [
        copy('B', {
          ...joined,
          'mobilePhone': '+1 212 555 0199',
          'birthday': '1980-07-04T11:59:00Z',
        }),
        copy('C', {'mobilePhone': '(212) 555-0199'}),
      ]);
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.patch, {
        'mobilePhone': '+1 212 555 0199',
        'birthday': '1980-07-04T11:59:00Z',
      });
    });
  });

  group('a value a rule cannot read', () {
    test('on another copy: a difference, never dropped', () {
      for (final (json, label, shown)
          in <(Map<String, Object?>, String, String)>[
        ({'jobTitle': 42}, 'Job title', '42'),
        ({'children': 'Tom'}, 'Children', 'Tom'),
        (
          {
            'emailAddresses': ['ann@work.example'],
          },
          'Emails',
          'ann@work.example',
        ),
        (
          {
            'businessAddress': {'street': '1 Main St', 'postalCode': 62704},
          },
          'Work address',
          '62704, 1 Main St',
        ),
        ({'birthday': 'May 4'}, 'Birthday', 'May 4'),
        ({'personalNotes': ['a list']}, 'Notes', 'a list'),
      ]) {
        final merged = merge(copy('A'), [copy('B', json)]);
        expect(merged.outcome, CopiesOutcome.differs, reason: label);
        expect(merged.differences, [
          CopiesDifference(label: label, others: {'B': shown}),
        ], reason: label);
      }
    });

    test('the synced copy\'s own again: the same', () {
      final odd = {'jobTitle': 42, 'birthday': 'May 4', 'children': 'Tom'};
      final merged = merge(copy('A', odd), [copy('B', odd), copy('C')]);
      expect(merged.outcome, CopiesOutcome.same);
    });

    test('on the synced copy, another value elsewhere: a difference', () {
      final merged = merge(copy('A', {'jobTitle': 42}), [
        copy('B', {'jobTitle': 'Buyer'}),
      ]);
      expect(merged.differences, [
        const CopiesDifference(
          label: 'Job title',
          kept: '42',
          others: {'B': 'Buyer'},
        ),
      ]);
      // Nothing elsewhere: left as it is.
      expect(merge(copy('A', {'jobTitle': 42}), [copy('B')]).outcome,
          CopiesOutcome.same);
      // A list of its own not read whole: the others' values not added.
      final list = merge(copy('A', {'children': ['Tom', 7]}), [
        copy('B', {'children': ['Sue']}),
      ]);
      expect(list.outcome, CopiesOutcome.differs);
      expect(list.differences.single.kept, 'Tom, 7');
    });

    test('Ron\'s answer takes it as it is', () {
      final merged = merge(copy('A'), [
        copy('B', {'jobTitle': 42}),
      ], keep: 'B');
      expect(merged.patch, {'jobTitle': 42});
      expect(merged.adds, [
        const CopiesDetail(label: 'Job title', value: '42'),
      ]);
    });
  });

  test('every property of a Graph contact (v1.0) has its rule', () {
    // A value on another copy where the synced copy has none: none of
    // them is "Other details".
    final values = <String, Object?>{
      'id': 'X',
      'changeKey': 'k',
      'createdDateTime': '2020-01-01T00:00:00Z',
      'lastModifiedDateTime': '2020-01-01T00:00:00Z',
      'parentFolderId': 'F',
      'displayName': 'Ann',
      'fileAs': 'Ann',
      'givenName': 'Ann',
      'middleName': 'B',
      'surname': 'Cole',
      'generation': 'Jr.',
      'title': 'Dr.',
      'nickName': 'Annie',
      'initials': 'A.C.',
      'companyName': 'Acme',
      'department': 'Sales',
      'jobTitle': 'Buyer',
      'officeLocation': 'B2',
      'profession': 'Engineer',
      'manager': 'Bob',
      'assistantName': 'Sue',
      'spouseName': 'Tom',
      'businessHomePage': 'acme.example',
      'yomiGivenName': 'An',
      'yomiSurname': 'Koru',
      'yomiCompanyName': 'Akume',
      'personalNotes': 'Two dogs.',
      'birthday': '1980-07-04T11:59:00Z',
      'mobilePhone': '+1 212 555 0100',
      'businessPhones': ['+1 212 555 0101'],
      'homePhones': ['+1 212 555 0102'],
      'emailAddresses': [email('ann@x.example')],
      'primaryEmailAddress': email('ann@x.example'),
      'secondaryEmailAddress': email('ann@y.example'),
      'tertiaryEmailAddress': email('ann@z.example'),
      'imAddresses': ['ann@chat.example'],
      'children': ['Tom'],
      'categories': ['Customers'],
      'businessAddress': address(city: 'Springfield'),
      'homeAddress': address(city: 'Peoria'),
      'otherAddress': address(city: 'Joliet'),
    };
    expect(values, hasLength(41));
    // Joined by the mobile they share.
    const mobile = {'mobilePhone': '+1 212 555 0100'};
    for (final MapEntry(:key, :value) in values.entries) {
      final merged = merge(
        const OutlookCopy(id: 'A', json: {'id': 'A', ...mobile}),
        [
          OutlookCopy(id: 'B', json: {...mobile, key: value}),
        ],
      );
      expect(merged.differences, isEmpty, reason: key);
    }
  });

  group('Ron\'s answer', () {
    // The synced copy, another copy differing in several details, and a
    // third adding one.
    final kept = copy(
      'A',
      {
        'jobTitle': 'Buyer',
        'personalNotes': 'Two dogs.',
        'emailAddresses': [email('ann@x.example')],
        'homePhones': ['+1 212 555 0101', '+1 212 555 0102'],
      },
      'p1',
    );
    final other = copy(
      'B',
      {
        'jobTitle': 'Purchasing manager',
        'personalNotes': 'A cat.',
        'homePhones': ['+1 212 555 0103'],
        'weddingAnniversary': '2001-05-05',
      },
      'p2',
    );
    final third = copy('C', {
      'department': 'Purchasing',
      'emailAddresses': [email('ann@y.example')],
    });

    test('unanswered: listed, with what any answer adds', () {
      final merged = merge(kept, [other, third]);
      expect(merged.outcome, CopiesOutcome.differs);
      expect(
        [for (final d in merged.differences) d.label],
        ['Home phones', 'Job title', 'Notes', 'Other details'],
      );
      expect(merged.patch, {
        'emailAddresses': [email('ann@x.example'), email('ann@y.example')],
        'department': 'Purchasing',
      });
    });

    test('the synced copy\'s: its details stay, the others\' added', () {
      final unanswered = merge(kept, [other, third]);
      final merged = merge(kept, [other, third], keep: 'A');
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.differences, isEmpty);
      expect(merged.photoFrom, isNull);
      expect(merged.patch, {
        'emailAddresses': [email('ann@x.example'), email('ann@y.example')],
        'department': 'Purchasing',
      });
      expect(merged.fingerprint, unanswered.fingerprint);
      // With nothing to add, the same.
      final alone = merge(kept, [other], keep: 'A');
      expect(alone.outcome, CopiesOutcome.same);
      expect(alone.patch, isEmpty);
      expect(alone.fingerprint, merge(kept, [other]).fingerprint);
    });

    test('another copy\'s: its values win where it has one', () {
      final merged = merge(kept, [other, third], keep: 'B');
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.differences, isEmpty);
      // The synced copy's photo stays: the answer was on the details.
      expect(merged.photoFrom, isNull);
      expect(merged.patch, {
        'emailAddresses': [email('ann@x.example'), email('ann@y.example')],
        'department': 'Purchasing',
        'homePhones': ['+1 212 555 0103', '+1 212 555 0101'],
        'jobTitle': 'Purchasing manager',
        'personalNotes': 'A cat.',
        'weddingAnniversary': '2001-05-05',
      });
      expect(merged.adds, [
        const CopiesDetail(label: 'Emails', value: 'ann@y.example'),
        const CopiesDetail(label: 'Department', value: 'Purchasing'),
        const CopiesDetail(label: 'Home phones', value: '+1 212 555 0103'),
        const CopiesDetail(label: 'Job title', value: 'Purchasing manager'),
        const CopiesDetail(label: 'Notes', value: 'A cat.'),
        const CopiesDetail(
          label: 'Other details',
          value: 'weddingAnniversary: 2001-05-05',
        ),
      ]);
      expect(merged.fingerprint, merge(kept, [other, third]).fingerprint);
    });

    test('a copy with none of a detail leaves the synced copy\'s', () {
      // C has no job title, notes, home phones, photo or anniversary.
      final merged = merge(kept, [other, third], keep: 'C');
      expect(merged.outcome, CopiesOutcome.adds);
      expect(merged.photoFrom, isNull);
      expect(merged.patch, {
        'emailAddresses': [email('ann@x.example'), email('ann@y.example')],
        'department': 'Purchasing',
      });
    });

    test('an answer naming no copy is no answer', () {
      final merged = merge(kept, [other, third], keep: 'Z');
      expect(merged.outcome, CopiesOutcome.differs);
      expect(merged.differences, hasLength(4));
    });

    test('an answer with nothing differing changes nothing', () {
      final plain = merge(kept, [third]);
      final answered = merge(kept, [third], keep: 'C');
      expect(answered.outcome, plain.outcome);
      expect(answered.patch, plain.patch);
      expect(answered.fingerprint, '');
    });
  });

  group('the fingerprint', () {
    final kept = copy('A', {
      'jobTitle': 'Buyer',
      'homePhones': ['+1 212 555 0101', '+1 212 555 0102'],
    });
    final b = copy('B', {
      'jobTitle': 'Manager',
      'homePhones': ['+1 212 555 0103'],
      'officeLocation': 'B2',
    });
    final c = copy('C', {'jobTitle': 'Lead buyer'}, 'p1');

    test('the same differences, in another order: the same', () {
      final first = merge(kept, [b, c]).fingerprint;
      expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
      // The copies the other way round, their properties and lists in
      // another order, their text in other capitals and spaces.
      final again = merge(
        OutlookCopy(
          id: 'A',
          json: {
            'homePhones': ['(212) 555-0102', '(212) 555-0101'],
            'mobilePhone': '(212) 555-0100',
            'surname': 'Cole',
            'jobTitle': ' buyer ',
            'givenName': 'Ann',
            'id': 'A',
          },
        ),
        [
          copy('C', {'jobTitle': 'LEAD  BUYER'}, 'p1'),
          OutlookCopy(
            id: 'B',
            json: {
              'officeLocation': 'B2',
              'homePhones': ['212-555-0103'],
              'mobilePhone': '212.555.0100',
              'jobTitle': 'manager',
            },
          ),
        ],
      ).fingerprint;
      expect(again, first);
    });

    test('another difference, or another copy: another fingerprint', () {
      final first = merge(kept, [b, c]).fingerprint;
      final changed = merge(kept, [
        b,
        copy('C', {'jobTitle': 'Head buyer'}, 'p1'),
      ]).fingerprint;
      expect(changed, isNot(first));
      final photo = merge(kept, [
        b,
        copy('C', {'jobTitle': 'Lead buyer'}, 'p2'),
      ]).fingerprint;
      expect(photo, first, reason: 'one photo among the others is no '
          'difference');
      final more = merge(kept, [b, c, copy('D', {'jobTitle': 'Clerk'})]);
      expect(more.fingerprint, isNot(first));
      // An added detail is no difference: the same fingerprint.
      final added = merge(kept, [
        b,
        copy('C', {'jobTitle': 'Lead buyer', 'department': 'Sales'}, 'p1'),
      ]).fingerprint;
      expect(added, first);
    });

    test('none when nothing differs', () {
      expect(merge(kept, [copy('B', {'department': 'Sales'})]).fingerprint,
          '');
    });
  });

  test('values are shown on one line, cut with an ellipsis', () {
    final long = 'Purchasing and Logistics Coordinator, Second Floor Office '
        'Annex';
    final merged = merge(copy('A', {'jobTitle': 'Buyer'}), [
      copy('B', {'jobTitle': long}),
    ]);
    final shown = merged.differences.single.others['B']!;
    expect(shown, hasLength(60));
    expect(shown, '${long.substring(0, 59).trimRight()}\u2026');
  });

  test('no value, id or photo in a toString', () {
    const secrets = [
      'ann@x.example',
      'Purchasing manager',
      'Two dogs',
      'p1',
      'p2',
      'id-A',
      'id-B',
      '2001-05-05',
    ];
    final kept = OutlookCopy(
      id: 'id-A',
      json: const {
        'id': 'id-A',
        'jobTitle': 'Buyer',
        'emailAddresses': [
          {'address': 'ann@x.example'},
        ],
        'personalNotes': 'Two dogs',
      },
      photo: 'p1',
    );
    final other = OutlookCopy(
      id: 'id-B',
      json: const {
        'id': 'id-B',
        'jobTitle': 'Purchasing manager',
        'weddingAnniversary': '2001-05-05',
      },
      photo: 'p2',
    );
    final merged = merge(kept, [other]);
    final answered = merge(kept, [other], keep: 'id-B');
    final shown = [
      '$kept',
      '$other',
      '$merged',
      '$answered',
      for (final d in merged.differences) '$d',
      for (final d in answered.adds) '$d',
    ];
    for (final text in shown) {
      for (final secret in secrets) {
        expect(text, isNot(contains(secret)), reason: text);
      }
    }
  });
}
