import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/contacts/contact_backup.dart';

/// The backup contact sync saves before its first sync changes anything:
/// Gmail's contacts as a vCard file for Google Contacts, Hadco's as
/// Outlook's CSV for Outlook on the web. Each is the way back if the sync
/// goes wrong, so what matters is that nothing in them is lost or mangled
/// on the way back in: names in any script, values with commas and line
/// breaks, birthdays on their own day.
void main() {
  // Hebrew, built from code points so the file's own encoding cannot
  // change them: Dana (dalet nun he) and Levi (lamed vav yod).
  const dana = '\u05D3\u05E0\u05D4';
  const levi = '\u05DC\u05D5\u05D9';

  group('the vCard file', () {
    /// The file's lines with folding undone, as a reader sees them.
    List<String> unfold(String file) {
      expect(file, endsWith('\r\n'));
      final lines = <String>[];
      for (final physical in file.substring(0, file.length - 2).split('\r\n')) {
        if (physical.startsWith(' ')) {
          lines.last += physical.substring(1);
        } else {
          lines.add(physical);
        }
      }
      return lines;
    }

    Map<String, Object?> person(Map<String, Object?> fields) =>
        {'resourceName': 'people/c1', 'etag': 'e', ...fields};

    test('is one card per person, in vCard 3.0, with CRLF line ends', () {
      final file = ContactBackup.vCard([
        person({
          'names': [
            {'givenName': 'Dana', 'familyName': 'Levi'},
          ],
        }),
        person({
          'names': [
            {'displayName': 'Noa Cohen', 'givenName': 'Noa'},
          ],
        }),
      ]);

      expect(file.replaceAll('\r\n', ''), isNot(contains('\n')),
          reason: 'no bare line feeds');
      expect(unfold(file), [
        'BEGIN:VCARD',
        'VERSION:3.0',
        'N:Levi;Dana;;;',
        'FN:Dana Levi',
        'END:VCARD',
        'BEGIN:VCARD',
        'VERSION:3.0',
        'N:;Noa;;;',
        'FN:Noa Cohen',
        'END:VCARD',
      ]);
    });

    test('writes every part of a name, and names in any script', () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'names': [
            {
              'displayName': 'Dr. $dana Levi-Cohen Jr.',
              'honorificPrefix': 'Dr.',
              'givenName': dana,
              'middleName': 'José',
              'familyName': 'Levi-Cohen',
              'honorificSuffix': 'Jr.',
              'phoneticGivenName': 'Dana',
              'phoneticFamilyName': 'Levi',
            },
          ],
          'nicknames': [
            {'value': 'Dee'},
            {'value': 'Dee D', 'type': 'DEFAULT'},
            {'value': 'D, the second', 'type': 'ALTERNATE_NAME'},
            {'value': 'Katz', 'type': 'MAIDEN_NAME'},
          ],
        }),
      ]));

      expect(lines, containsAllInOrder([
        'N:Levi-Cohen;$dana;José;Dr.;Jr.',
        'FN:Dr. $dana Levi-Cohen Jr.',
        'X-PHONETIC-FIRST-NAME:Dana',
        'X-PHONETIC-LAST-NAME:Levi',
        r'item1.NICKNAME:D\, the second',
        'item1.X-ABLabel:Alternate name',
        'X-MAIDENNAME:Katz',
        'NICKNAME:Dee,Dee D',
      ]));
      expect(lines.join(), isNot(contains('CHARSET')),
          reason: 'vCard 3.0 is UTF-8 throughout; CHARSET is 2.1');
    });

    test('escapes commas, semicolons, backslashes and line breaks', () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'names': [
            {'givenName': 'Dana; Noa', 'familyName': r'Levi, \Cohen'},
          ],
          'biographies': [
            {
              'value': 'Met at the fair,\r\nstand 4; ask for C:\\files\n'
                  'Second line',
              'contentType': 'TEXT_PLAIN',
            },
          ],
        }),
      ]));

      expect(lines, contains(r'N:Levi\, \\Cohen;Dana\; Noa;;;'));
      expect(lines, contains(r'FN:Dana\; Noa Levi\, \\Cohen'));
      expect(
        lines,
        contains(r'NOTE:Met at the fair\,\nstand 4\; ask for C:\\files\n'
            'Second line'),
      );
    });

    test('folds a long line at 75 octets, never inside a character', () {
      // Hebrew is two octets a letter and the emoji four: a fold counted
      // in characters, or one that split a letter, would break the file.
      final note = '${'$dana $levi ' * 12}\u{1F382} end';
      final file = ContactBackup.vCard([
        person({
          'names': [
            {'givenName': dana},
          ],
          'biographies': [
            {'value': note},
          ],
        }),
      ]);

      final physical = file.split('\r\n')..removeLast();
      expect(physical.length, greaterThan(5), reason: 'it was folded');
      for (final line in physical) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
        expect(line.runes.every((r) => r != 0xFFFD), isTrue);
      }
      expect(unfold(file), contains('NOTE:$note'),
          reason: 'unfolding gives back the line whole');
    });

    test('writes birthdays with a year, and without one', () {
      String? birthday(Object? date) {
        final lines = unfold(ContactBackup.vCard([
          person({
            'birthdays': [
              {'date': date, 'text': 'some day'},
            ],
          }),
        ]));
        return lines.where((l) => l.startsWith('BDAY')).firstOrNull;
      }

      expect(birthday({'year': 1980, 'month': 5, 'day': 17}),
          'BDAY:1980-05-17');
      expect(birthday({'month': 5, 'day': 7}),
          'BDAY;X-APPLE-OMIT-YEAR=1604:1604-05-07',
          reason: "Apple's form: Google is reported to drop vCard's own "
              '--05-07 without a word (Mozilla bug 1820356)');
      expect(birthday({'year': 0, 'month': 12, 'day': 31}),
          'BDAY;X-APPLE-OMIT-YEAR=1604:1604-12-31');
      expect(birthday(null), isNull, reason: 'text alone is not a date');
    });

    test('keeps a birthday known only as text, to be read', () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'birthdays': [
            {'text': 'Spring, around Pesach; ask'},
          ],
        }),
      ]));

      expect(lines.where((l) => l.startsWith('BDAY')), isEmpty);
      expect(lines, contains(r'X-BIRTHDAY-TEXT:Spring\, around Pesach\; ask'));
    });

    test('one with a date goes as BDAY, and the text beside it is not '
        'written twice', () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'birthdays': [
            {
              'date': {'year': 1980, 'month': 5, 'day': 17},
              'text': '17 May 1980',
            },
          ],
        }),
      ]));

      expect(lines, contains('BDAY:1980-05-17'));
      expect(lines.where((l) => l.startsWith('X-BIRTHDAY-TEXT')), isEmpty);
    });

    test('writes numbers and links as they are, not escaped as text', () {
      // RFC 2426 types TEL as phone-number and URL as uri. A comma in a
      // number is a pause, and escaped it is a different number.
      final lines = unfold(ContactBackup.vCard([
        person({
          'phoneNumbers': [
            {'value': '+1 555 1234,,99#', 'type': 'work'},
            {'value': '03-555\r\n-0101', 'type': 'mobile'},
          ],
          'urls': [
            {'value': 'https://x.example/a,b;c?d=1,2', 'type': 'work'},
            {'value': 'https://x.example/blog', 'type': 'blog'},
          ],
          'calendarUrls': [
            {'url': 'https://cal.example/a,b'},
          ],
        }),
      ]));

      expect(lines, containsAllInOrder([
        'TEL;TYPE=WORK:+1 555 1234,,99#',
        'TEL;TYPE=CELL:03-555-0101',
        'URL;TYPE=WORK:https://x.example/a,b;c?d=1,2',
        'item1.URL:https://x.example/blog',
        'CALURI:https://cal.example/a,b',
      ]));
    });

    test('writes emails, phones and addresses with their types', () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'emailAddresses': [
            {'value': 'dana@home.example', 'type': 'home'},
            {'value': 'dana@work.example', 'type': 'work'},
            {'value': 'dana@other.example'},
            {
              'value': 'dana@club.example',
              'type': 'club',
              'formattedType': 'Club',
            },
          ],
          'phoneNumbers': [
            {'value': '+972 50-123-4567', 'type': 'mobile'},
            {'value': '03-555-0101', 'type': 'home'},
            {'value': '03-555-0102', 'type': 'workFax'},
            {'value': '03-555-0103', 'type': 'pager'},
            {
              'value': '+1 650-555-0104',
              'type': 'googleVoice',
              'formattedType': 'Google Voice',
            },
          ],
          'addresses': [
            {
              'type': 'home',
              'poBox': '12',
              'streetAddress': 'Herzl 1',
              'extendedAddress': 'Flat 3',
              'city': 'Tel Aviv',
              'region': 'Center',
              'postalCode': '6100000',
              'country': 'Israel',
              'countryCode': 'IL',
            },
            {'type': 'work', 'formattedValue': 'Hadco, 5 Main St'},
          ],
        }),
      ]));

      expect(lines, containsAllInOrder([
        'EMAIL;TYPE=INTERNET;TYPE=HOME:dana@home.example',
        'EMAIL;TYPE=INTERNET;TYPE=WORK:dana@work.example',
        'EMAIL;TYPE=INTERNET:dana@other.example',
        'item1.EMAIL;TYPE=INTERNET:dana@club.example',
        'item1.X-ABLabel:Club',
        'TEL;TYPE=CELL:+972 50-123-4567',
        'TEL;TYPE=HOME:03-555-0101',
        'TEL;TYPE=WORK;TYPE=FAX:03-555-0102',
        'TEL;TYPE=PAGER:03-555-0103',
        'item2.TEL:+1 650-555-0104',
        'item2.X-ABLabel:Google Voice',
        'ADR;TYPE=HOME:12;Flat 3;Herzl 1;Tel Aviv;Center;6100000;Israel',
        r'ADR;TYPE=WORK:;;Hadco\, 5 Main St;;;;',
      ]));
    });

    test('writes work, notes, dates, people, pages, IM and custom fields',
        () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'organizations': [
            {
              'name': 'Hadco',
              'department': 'Sales',
              'title': 'Manager',
              'location': 'Floor 3',
            },
            {'name': 'Volunteers', 'title': 'Chair'},
          ],
          'events': [
            {
              'date': {'year': 2010, 'month': 6, 'day': 1},
              'type': 'anniversary',
            },
            {
              'date': {'month': 9, 'day': 2},
              'type': 'aliyah',
              'formattedType': 'Aliyah',
            },
          ],
          'relations': [
            {'person': 'Noa', 'type': 'spouse'},
            {'person': 'Ori', 'type': 'child'},
            {
              'person': 'Gil',
              'type': 'referredBy',
              'formattedType': 'Referred by',
            },
          ],
          'urls': [
            {'value': 'https://dana.example/', 'type': 'homePage'},
            {'value': 'https://hadco.example/dana', 'type': 'work'},
          ],
          'imClients': [
            {'username': 'dana.l', 'protocol': 'skype'},
            {'username': 'dana@chat', 'protocol': 'matrix'},
          ],
          'userDefined': [
            {'key': 'Shirt size', 'value': 'M'},
          ],
          'biographies': [
            {
              'value': '<p>Likes <b>tea</b></p><p>Not coffee</p>',
              'contentType': 'TEXT_HTML',
            },
          ],
        }),
      ]));

      expect(lines, containsAllInOrder([
        'ORG:Hadco;Sales',
        'TITLE:Manager',
        'X-OFFICE:Floor 3',
        'item1.ORG:Volunteers;',
        'item1.TITLE:Chair',
        'item2.X-ABDATE:2010-06-01',
        r'item2.X-ABLabel:_$!<Anniversary>!$_',
        'item3.X-ABDATE;X-APPLE-OMIT-YEAR=1604:1604-09-02',
        'item3.X-ABLabel:Aliyah',
        'item4.X-ABRELATEDNAMES:Noa',
        r'item4.X-ABLabel:_$!<Spouse>!$_',
        'item5.X-ABRELATEDNAMES:Ori',
        r'item5.X-ABLabel:_$!<Child>!$_',
        'item6.X-ABRELATEDNAMES:Gil',
        'item6.X-ABLabel:Referred by',
        'item7.URL:https://dana.example/',
        r'item7.X-ABLabel:_$!<HomePage>!$_',
        'URL;TYPE=WORK:https://hadco.example/dana',
        'X-SKYPE:dana.l',
        'item8.X-IM:dana@chat',
        'item8.X-ABLabel:matrix',
        'item9.X-CUSTOM:M',
        'item9.X-ABLabel:Shirt size',
        r'NOTE:Likes tea\nNot coffee',
      ]));
    });

    test('keeps the smaller details: names on emails, kinds of IM and '
        'work, country codes, locales and Starred', () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'emailAddresses': [
            {
              'value': 'dana@work.example',
              'type': 'work',
              'displayName': 'Dana L. (Hadco)',
            },
            {'value': 'dana@home.example', 'type': 'home'},
          ],
          'addresses': [
            {'type': 'home', 'city': 'Haifa', 'countryCode': 'IL'},
            {
              'type': 'work',
              'city': 'Paris',
              'country': 'France',
              'countryCode': 'FR',
            },
          ],
          'imClients': [
            {'username': 'dana.l', 'protocol': 'skype', 'type': 'work'},
            {
              'username': 'dana.home',
              'protocol': 'jabber',
              'type': 'gaming',
              'formattedType': 'Gaming',
            },
            {
              'username': 'dana@chat',
              'protocol': 'matrix',
              'type': 'home',
            },
          ],
          'organizations': [
            {
              'name': 'Hadco',
              'type': 'work',
              'current': true,
              'startDate': {'year': 2019, 'month': 3},
            },
            {
              'name': 'Technion',
              'type': 'school',
              'current': false,
              'startDate': {'year': 1998},
              'endDate': {'year': 2002, 'month': 6, 'day': 30},
            },
          ],
          'locales': [
            {'value': 'he'},
          ],
          'memberships': [
            {
              'contactGroupMembership': {
                'contactGroupResourceName': 'contactGroups/starred',
              },
            },
            {
              'contactGroupMembership': {
                'contactGroupResourceName': 'contactGroups/myContacts',
              },
            },
          ],
        }),
      ]));

      expect(lines, containsAllInOrder([
        'item1.EMAIL;TYPE=INTERNET;TYPE=WORK:dana@work.example',
        'item1.X-DISPLAY-NAME:Dana L. (Hadco)',
        'EMAIL;TYPE=INTERNET;TYPE=HOME:dana@home.example',
        'ADR;TYPE=HOME:;;;Haifa;;;IL',
        'ADR;TYPE=WORK:;;;Paris;;;France',
        'ORG:Hadco;',
        'X-ORG-START:2019-03',
        'X-ORG-TYPE:work',
        'X-ORG-CURRENT:true',
        'item2.ORG:Technion;',
        'item2.X-ORG-START:1998',
        'item2.X-ORG-END:2002-06-30',
        'item2.X-ORG-TYPE:school',
        'item2.X-ORG-CURRENT:false',
        'X-SKYPE;TYPE=WORK:dana.l',
        'item3.X-JABBER:dana.home',
        'item3.X-ABLabel:Gaming',
        'item4.X-IM;TYPE=HOME:dana@chat',
        'item4.X-ABLabel:matrix',
        'X-LOCALE:he',
        'CATEGORIES:starred',
      ]));
    });

    test('reads an HTML note as text, keeping links and decoding entities',
        () {
      String note(String html) => unfold(ContactBackup.vCard([
            person({
              'biographies': [
                {'value': html, 'contentType': 'TEXT_HTML'},
              ],
            }),
          ])).singleWhere((l) => l.startsWith('NOTE:')).substring(5);

      expect(note('See <a href="https://x.example/p">site</a> first'),
          'See site (https://x.example/p) first',
          reason: 'the link is the point of the note');
      expect(note('<a href="https://x.example">https://x.example</a>'),
          'https://x.example',
          reason: 'not twice when the words are the link');
      expect(note('<a href="mailto:dana@x.example">dana@x.example</a>'),
          'dana@x.example');
      expect(note('Shalom &#1488;&#1489; &amp; it&#8217;s&nbsp;fine'),
          'Shalom \u05D0\u05D1 & it\u2019s fine');
      expect(note('<div>One\n  line</div><div>Two<br>Three</div>'
              '<script>x()</script>'),
          r'One line\nTwo\nThree');
    });

    test("leaves out what came from a Google profile, not Ron's contact", () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'names': [
            {
              'givenName': 'Dana',
              'metadata': {
                'source': {'type': 'CONTACT'},
              },
            },
          ],
          'emailAddresses': [
            {
              'value': 'profile@example.com',
              'metadata': {
                'source': {'type': 'PROFILE'},
              },
            },
            {
              'value': 'dana@example.com',
              'metadata': {
                'source': {'type': 'CONTACT'},
              },
            },
          ],
        }),
      ]));

      expect(lines, contains('EMAIL;TYPE=INTERNET:dana@example.com'));
      expect(lines.join('\n'), isNot(contains('profile@example.com')));
    });

    test('names its labels, and leaves out groups it was not told of', () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'names': [
            {'givenName': 'Dana'},
          ],
          'memberships': [
            {
              'contactGroupMembership': {
                'contactGroupResourceName': 'contactGroups/myContacts',
              },
            },
            {
              'contactGroupMembership': {
                'contactGroupResourceName': 'contactGroups/1a2b',
              },
            },
            {
              'contactGroupMembership': {
                'contactGroupResourceName': 'contactGroups/3c4d',
              },
            },
          ],
        }),
      ], labelNames: {
        'contactGroups/1a2b': 'Family',
        'contactGroups/3c4d': 'Work, old',
      }));

      expect(lines, contains(r'CATEGORIES:Family,Work\, old'));
    });

    test('a person with no name is still shown under something', () {
      final lines = unfold(ContactBackup.vCard([
        person({
          'emailAddresses': [
            {'value': 'nameless@example.com'},
          ],
        }),
      ]));

      expect(lines, contains('FN:nameless@example.com'));
      expect(lines, contains('N:;;;;'));
    });
  });

  group("Outlook's CSV", () {
    /// The rows of a CSV file, as a spreadsheet reads them.
    List<List<String>> parse(String file) {
      final rows = <List<String>>[];
      var row = <String>[];
      final field = StringBuffer();
      var quoted = false;
      for (var i = 0; i < file.length; i++) {
        final c = file[i];
        if (quoted) {
          if (c == '"') {
            if (i + 1 < file.length && file[i + 1] == '"') {
              field.write('"');
              i++;
            } else {
              quoted = false;
            }
          } else {
            field.write(c);
          }
        } else if (c == '"') {
          quoted = true;
        } else if (c == ',') {
          row.add(field.toString());
          field.clear();
        } else if (c == '\r' && file[i + 1] == '\n') {
          row.add(field.toString());
          field.clear();
          rows.add(row);
          row = <String>[];
          i++;
        } else {
          field.write(c);
        }
      }
      expect(row, isEmpty, reason: 'the last row ends in CRLF too');
      return rows;
    }

    Map<String, String> only(String file) {
      final rows = parse(file.substring(1));
      expect(rows, hasLength(2));
      return Map.fromIterables(rows[0], rows[1]);
    }

    test('starts with a byte order mark and the header row', () {
      final file = ContactBackup.outlookCsv(const []);

      expect(file.codeUnitAt(0), 0xFEFF);
      expect(utf8.encode(file).take(3), [0xEF, 0xBB, 0xBF],
          reason: 'what tells Outlook and Excel it is UTF-8');
      final header =
          ContactBackup.outlookHeader.map((h) => '"$h"').join(',');
      expect(file.substring(1), '$header\r\n');
    });

    test("the header is Outlook on the web's, then the desktop's extras, "
        "then the file's own", () {
      expect(ContactBackup.outlookHeader, [
        'First Name', 'Middle Name', 'Last Name', 'Title', 'Suffix', //
        'Nickname', 'Given Yomi', 'Surname Yomi', 'E-mail Address',
        'E-mail 2 Address', 'E-mail 3 Address', 'Home Phone', 'Home Phone 2',
        'Business Phone', 'Business Phone 2', 'Mobile Phone', 'Car Phone',
        'Other Phone', 'Primary Phone', 'Pager', 'Business Fax', 'Home Fax',
        'Other Fax', 'Company Main Phone', 'Callback', 'Radio Phone', 'Telex',
        'TTY/TDD Phone', 'IMAddress', 'Job Title', 'Department', 'Company',
        'Office Location', "Manager's Name", "Assistant's Name",
        "Assistant's Phone", 'Company Yomi', 'Business Street',
        'Business City', 'Business State', 'Business Postal Code',
        'Business Country/Region', 'Home Street', 'Home City', 'Home State',
        'Home Postal Code', 'Home Country/Region', 'Other Street',
        'Other City', 'Other State', 'Other Postal Code',
        'Other Country/Region', 'Personal Web Page', 'Spouse', 'Schools',
        'Hobby', 'Location', 'Web Page', 'Birthday', 'Anniversary', 'Notes',
        'Initials', 'Profession', 'Children', 'Categories',
        'E-mail Display Name', 'E-mail 2 Display Name',
        'E-mail 3 Display Name', 'Display Name', 'File As',
      ]);
    });

    test('puts each detail of a Graph contact in its column', () {
      final row = only(ContactBackup.outlookCsv([
        {
          'id': 'AAMk-1',
          'displayName': 'Dana Levi',
          'fileAs': 'Levi, Dana',
          'givenName': dana,
          'middleName': 'J',
          'surname': levi,
          'title': 'Dr.',
          'generation': 'Jr.',
          'nickName': 'Dee',
          'yomiGivenName': 'Dana',
          'yomiSurname': 'Levi',
          'emailAddresses': [
            {'name': 'Dana', 'address': 'dana@home.example'},
            {'name': 'Dana', 'address': 'dana@work.example'},
            {'address': 'dana@third.example'},
          ],
          'mobilePhone': '+972 50-123-4567',
          'homePhones': ['03-555-0101', '03-555-0102'],
          'businessPhones': ['03-555-0201'],
          'imAddresses': ['dana.l', 'dana@chat'],
          'jobTitle': 'Manager',
          'department': 'Sales',
          'companyName': 'Hadco',
          'officeLocation': 'Floor 3',
          'manager': 'Gil',
          'assistantName': 'Tal',
          'yomiCompanyName': 'Hadco',
          'businessAddress': {
            'street': '5 Main St\r\nSuite 2',
            'city': 'Haifa',
            'state': 'North',
            'postalCode': '3100000',
            'countryOrRegion': 'Israel',
          },
          'homeAddress': {'street': 'Herzl 1', 'city': 'Tel Aviv'},
          'otherAddress': {},
          'spouseName': 'Noa',
          'children': ['Ori', 'Yael'],
          'businessHomePage': 'https://hadco.example/dana',
          'birthday': '1980-05-17T11:59:00Z',
          'personalNotes': 'Likes tea',
          'initials': 'D.L.',
          'profession': 'Engineer',
          'categories': ['Family', 'VIP'],
        },
      ]));

      expect(row['First Name'], dana);
      expect(row['Last Name'], levi);
      expect(row['Middle Name'], 'J');
      expect(row['Title'], 'Dr.');
      expect(row['Suffix'], 'Jr.');
      expect(row['Nickname'], 'Dee');
      expect(row['Given Yomi'], 'Dana');
      expect(row['E-mail Address'], 'dana@home.example');
      expect(row['E-mail 2 Address'], 'dana@work.example');
      expect(row['E-mail 3 Address'], 'dana@third.example');
      expect(row['E-mail Display Name'], 'Dana');
      expect(row['E-mail 2 Display Name'], 'Dana');
      expect(row['E-mail 3 Display Name'], '');
      expect(row['Mobile Phone'], '+972 50-123-4567');
      expect(row['Home Phone'], '03-555-0101');
      expect(row['Home Phone 2'], '03-555-0102');
      expect(row['Business Phone'], '03-555-0201');
      expect(row['Business Phone 2'], '');
      expect(row['IMAddress'], 'dana.l;dana@chat');
      expect(row['Job Title'], 'Manager');
      expect(row['Department'], 'Sales');
      expect(row['Company'], 'Hadco');
      expect(row['Office Location'], 'Floor 3');
      expect(row["Manager's Name"], 'Gil');
      expect(row["Assistant's Name"], 'Tal');
      expect(row['Business Street'], '5 Main St\r\nSuite 2');
      expect(row['Business City'], 'Haifa');
      expect(row['Business Country/Region'], 'Israel');
      expect(row['Home Street'], 'Herzl 1');
      expect(row['Home City'], 'Tel Aviv');
      expect(row['Other Street'], '');
      expect(row['Spouse'], 'Noa');
      expect(row['Children'], 'Ori;Yael');
      expect(row['Web Page'], 'https://hadco.example/dana');
      expect(row['Birthday'], '1980-05-17');
      expect(row['Notes'], 'Likes tea');
      expect(row['Initials'], 'D.L.');
      expect(row['Profession'], 'Engineer');
      expect(row['Categories'], 'Family;VIP');
      expect(row['Display Name'], 'Dana Levi');
      expect(row['File As'], 'Levi, Dana');
    });

    test('a contact with only a display name has it as its name', () {
      // Saved from a sender, imported with nothing but a name, or a
      // company: with no parts, a row without the display name would come
      // back with no name at all.
      final row = only(ContactBackup.outlookCsv([
        {
          'displayName': 'Hadco Supplies',
          'emailAddresses': [
            {'name': 'Hadco Supplies', 'address': 'orders@hadco.example'},
          ],
        },
      ]));

      expect(row['First Name'], 'Hadco Supplies');
      expect(row['Last Name'], '');
      expect(row['Display Name'], 'Hadco Supplies');
    });

    test('a display name of its own is kept beside the parts', () {
      final row = only(ContactBackup.outlookCsv([
        {
          'displayName': 'Dana from accounts',
          'givenName': 'Dana',
          'surname': 'Levi',
        },
      ]));

      expect(row['First Name'], 'Dana',
          reason: 'the parts are the name where there are any');
      expect(row['Last Name'], 'Levi');
      expect(row['Display Name'], 'Dana from accounts');
    });

    test('quotes every field, doubling quotes, so commas and line breaks '
        'stay inside it', () {
      final file = ContactBackup.outlookCsv([
        {
          'givenName': 'Dana "Dee"',
          'surname': 'Levi, Cohen',
          'personalNotes': 'Line one\r\nLine two, "quoted"\nLine three',
        },
      ]);

      expect(file, contains('"Dana ""Dee""","","Levi, Cohen"'));
      final row = only(file);
      expect(row['First Name'], 'Dana "Dee"');
      expect(row['Last Name'], 'Levi, Cohen');
      expect(row['Notes'], 'Line one\r\nLine two, "quoted"\nLine three');
    });

    test('a birthday is its own day, however Graph wrote the time', () {
      String birthday(String? value) =>
          only(ContactBackup.outlookCsv([
            {'givenName': 'Dana', 'birthday': value},
          ]))['Birthday']!;

      expect(birthday('1980-05-17T00:00:00Z'), '1980-05-17');
      expect(birthday('1980-05-17T11:59:00Z'), '1980-05-17',
          reason: 'where Exchange keeps it');
      expect(birthday('1980-05-16T22:00:00Z'), '1980-05-17',
          reason: "midnight in Israel's winter, written as UTC");
      expect(birthday('1980-05-17T00:00:00-05:00'), '1980-05-17',
          reason: 'midnight in New York');
      expect(birthday('1604-03-09T11:59:00Z'), '1604-03-09',
          reason: "Outlook's own year for none, kept for it to read");
      expect(birthday(null), '');
      expect(birthday('not a date'), '');
    });

    test('one row per contact, in the order given', () {
      final rows = parse(ContactBackup.outlookCsv([
        {'givenName': 'Dana'},
        {'givenName': dana},
        {'surname': 'Cohen'},
      ]).substring(1));

      expect(rows, hasLength(4));
      expect(rows.every((r) => r.length == ContactBackup.outlookHeader.length),
          isTrue);
      expect(rows.skip(1).map((r) => r[0]), ['Dana', dana, '']);
    });
  });

  group('the files', () {
    test('are saved with types Android names them by', () {
      final at = DateTime(2026, 11, 20, 9);

      expect(ContactBackup.vCardType, 'text/x-vcard');
      expect(ContactBackup.csvType, 'text/csv');
      expect(ContactBackup.vCardName(at),
          'myemail-google-contacts-2026-11-20.vcf');
      expect(ContactBackup.csvName(at),
          'myemail-outlook-contacts-2026-11-20.csv');
    });
  });
}
