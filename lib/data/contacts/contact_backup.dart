import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// The two files contact sync's backup is saved as, before the first sync
/// changes anything: the Google account's contacts as a vCard file, which
/// Google Contacts imports, and the Microsoft account's as Outlook's CSV,
/// which Outlook on the web imports.
///
/// Both are written from full listings, raw JSON as each server returned
/// it, so that the files hold everything readable, not only what the sync
/// copies: the fourth email, the fax, the anniversary, the custom field.
/// Photos are not in either.
abstract final class ContactBackup {
  /// The types the files are saved as. Android names a saved file by its
  /// type, so without them both would end in `.json`.
  static const vCardType = 'text/x-vcard';
  static const csvType = 'text/csv';

  static String vCardName(DateTime at) =>
      'myemail-google-contacts-${_day(at)}.vcf';

  static String csvName(DateTime at) =>
      'myemail-outlook-contacts-${_day(at)}.csv';

  static String _day(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  /// vCard 3.0 for Google Contacts, one card per Person in [people], as
  /// the People API returns it.
  ///
  /// Only entries from the contact itself are written: one whose
  /// `metadata.source.type` names another source (a Google profile) is not
  /// Ron's to restore. [labelNames] gives the names of the contact groups
  /// (labels) by resource name, written as CATEGORIES; a membership of a
  /// group not named there is left out, which is how the system groups
  /// stay out. Lines end in CRLF and are folded at 75 octets, as RFC 2425
  /// asks.
  static String vCard(
    Iterable<Map<String, Object?>> people, {
    Map<String, String> labelNames = const {},
  }) {
    final out = StringBuffer();
    for (final person in people) {
      for (final line in _card(person, labelNames)) {
        out
          ..write(_fold(line))
          ..write('\r\n');
      }
    }
    return out.toString();
  }

  /// Outlook's contacts CSV, one row per Graph contact in [contacts].
  ///
  /// The header is Outlook on the web's own export's, followed by the
  /// columns of Outlook's desktop export that hold the rest of what Graph
  /// reads (initials, profession, children and categories, the last two
  /// separated by semicolons, and each email's name), then two of this
  /// file's own, Display Name and File As, so that neither is lost even
  /// where Outlook's import has no place for it. A contact with no name
  /// parts at all (one saved from a sender, or a company) has its display
  /// name as its first name too, or its row would carry no name. Every
  /// field is quoted, as Outlook quotes them; rows end in CRLF; the text
  /// starts with a byte order mark, without which Outlook and Excel read
  /// UTF-8 as the PC's own code page and every accent and Hebrew letter
  /// comes out wrong.
  static String outlookCsv(Iterable<Map<String, Object?>> contacts) {
    final out = StringBuffer('\u{FEFF}');
    out
      ..write(outlookHeader.map(_csvField).join(','))
      ..write('\r\n');
    for (final contact in contacts) {
      final row = _row(contact);
      out
        ..write([for (final column in outlookHeader) row[column] ?? '']
            .map(_csvField)
            .join(','))
        ..write('\r\n');
    }
    return out.toString();
  }

  /// The columns, in order.
  static const outlookHeader = [
    'First Name',
    'Middle Name',
    'Last Name',
    'Title',
    'Suffix',
    'Nickname',
    'Given Yomi',
    'Surname Yomi',
    'E-mail Address',
    'E-mail 2 Address',
    'E-mail 3 Address',
    'Home Phone',
    'Home Phone 2',
    'Business Phone',
    'Business Phone 2',
    'Mobile Phone',
    'Car Phone',
    'Other Phone',
    'Primary Phone',
    'Pager',
    'Business Fax',
    'Home Fax',
    'Other Fax',
    'Company Main Phone',
    'Callback',
    'Radio Phone',
    'Telex',
    'TTY/TDD Phone',
    'IMAddress',
    'Job Title',
    'Department',
    'Company',
    'Office Location',
    "Manager's Name",
    "Assistant's Name",
    "Assistant's Phone",
    'Company Yomi',
    'Business Street',
    'Business City',
    'Business State',
    'Business Postal Code',
    'Business Country/Region',
    'Home Street',
    'Home City',
    'Home State',
    'Home Postal Code',
    'Home Country/Region',
    'Other Street',
    'Other City',
    'Other State',
    'Other Postal Code',
    'Other Country/Region',
    'Personal Web Page',
    'Spouse',
    'Schools',
    'Hobby',
    'Location',
    'Web Page',
    'Birthday',
    'Anniversary',
    'Notes',
    'Initials',
    'Profession',
    'Children',
    'Categories',
    'E-mail Display Name',
    'E-mail 2 Display Name',
    'E-mail 3 Display Name',
    'Display Name',
    'File As',
  ];

  // --- vCard ----------------------------------------------------------------

  static List<String> _card(
    Map<String, Object?> person,
    Map<String, String> labelNames,
  ) {
    final lines = <String>['BEGIN:VCARD', 'VERSION:3.0'];
    var group = 0;

    /// A property in a group of its own, with a label beside it: how a
    /// type vCard has no word for travels, as Google's and Apple's own
    /// exports write it.
    void labelled(String property, String value, String label) {
      group++;
      lines
        ..add('item$group.$property:$value')
        ..add('item$group.X-ABLabel:${_text(label)}');
    }

    final name = _entries(person, 'names').firstOrNull;
    final given = _str(name?['givenName']);
    final family = _str(name?['familyName']);
    lines.add('N:${[
      family,
      given,
      _str(name?['middleName']),
      _str(name?['honorificPrefix']),
      _str(name?['honorificSuffix']),
    ].map(_text).join(';')}');
    lines.add('FN:${_text(_fullName(person, name))}');
    for (final (key, property) in const [
      ('phoneticGivenName', 'X-PHONETIC-FIRST-NAME'),
      ('phoneticMiddleName', 'X-PHONETIC-MIDDLE-NAME'),
      ('phoneticFamilyName', 'X-PHONETIC-LAST-NAME'),
    ]) {
      final value = _str(name?[key]);
      if (value.isNotEmpty) lines.add('$property:${_text(value)}');
    }

    final nicknames = [
      for (final n in _entries(person, 'nicknames'))
        if (_str(n['value']) case final v when v.isNotEmpty) _text(v),
    ];
    if (nicknames.isNotEmpty) lines.add('NICKNAME:${nicknames.join(',')}');

    for (final e in _entries(person, 'emailAddresses')) {
      final value = _str(e['value']);
      if (value.isEmpty) continue;
      final type = _str(e['type']);
      switch (type) {
        case '' || 'other':
          lines.add('EMAIL;TYPE=INTERNET:${_text(value)}');
        case 'home' || 'work':
          lines.add(
              'EMAIL;TYPE=INTERNET;TYPE=${type.toUpperCase()}:${_text(value)}');
        default:
          labelled('EMAIL;TYPE=INTERNET', _text(value), _label(e, type));
      }
    }

    for (final p in _entries(person, 'phoneNumbers')) {
      final value = _str(p['value']);
      if (value.isEmpty) continue;
      final type = _str(p['type']);
      final types = _phoneTypes[type];
      if (types == null) {
        labelled('TEL', _plain(value), _label(p, type));
      } else {
        lines.add('TEL${types.map((t) => ';TYPE=$t').join()}:${_plain(value)}');
      }
    }

    for (final a in _entries(person, 'addresses')) {
      final parts = [
        _str(a['poBox']),
        _str(a['extendedAddress']),
        _str(a['streetAddress']),
        _str(a['city']),
        _str(a['region']),
        _str(a['postalCode']),
        _str(a['country']),
      ];
      if (parts.every((p) => p.isEmpty)) {
        // Only the formatted form: kept as the street, so it is not lost.
        final formatted = _str(a['formattedValue']);
        if (formatted.isEmpty) continue;
        parts[2] = formatted;
      }
      final value = parts.map(_text).join(';');
      final type = _str(a['type']);
      switch (type) {
        case 'home' || 'work':
          lines.add('ADR;TYPE=${type.toUpperCase()}:$value');
        case '' || 'other':
          lines.add('ADR:$value');
        default:
          labelled('ADR', value, _label(a, type));
      }
    }

    var firstOrganisation = true;
    for (final o in _entries(person, 'organizations')) {
      final company = _str(o['name']);
      final department = _str(o['department']);
      final title = _str(o['title']);
      final office = _str(o['location']);
      final role = _str(o['jobDescription']);
      if ([company, department, title, office, role].every((s) => s.isEmpty)) {
        continue;
      }
      // The first goes ungrouped, as an importer looks for it; the rest
      // each in a group, so that each title stays with its company.
      final prefix = firstOrganisation ? '' : 'item${++group}.';
      firstOrganisation = false;
      if (company.isNotEmpty || department.isNotEmpty) {
        lines.add('${prefix}ORG:${[company, department].map(_text).join(';')}');
      }
      if (title.isNotEmpty) lines.add('${prefix}TITLE:${_text(title)}');
      if (role.isNotEmpty) lines.add('${prefix}ROLE:${_text(role)}');
      if (office.isNotEmpty) lines.add('${prefix}X-OFFICE:${_text(office)}');
    }
    for (final o in _entries(person, 'occupations')) {
      final value = _str(o['value']);
      if (value.isNotEmpty) lines.add('ROLE:${_text(value)}');
    }

    // One BDAY, the first birthday with a date. One kept only as text has
    // no vCard form; it goes as an X- property, so that the file, which is
    // Ron's record to read as well as to import, still says it.
    var dated = false;
    for (final b in _entries(person, 'birthdays')) {
      final line = _dated('BDAY', b['date']);
      if (line == null) {
        final text = _str(b['text']);
        if (text.isNotEmpty) lines.add('X-BIRTHDAY-TEXT:${_text(text)}');
      } else if (!dated) {
        lines.add(line);
        dated = true;
      }
    }

    for (final e in _entries(person, 'events')) {
      final line = _dated('X-ABDATE', e['date']);
      if (line == null) continue;
      final type = _str(e['type']);
      final label =
          type == 'anniversary' ? r'_$!<Anniversary>!$_' : _label(e, type);
      group++;
      lines
        ..add('item$group.$line')
        ..add('item$group.X-ABLabel:${_text(label)}');
    }

    for (final r in _entries(person, 'relations')) {
      final who = _str(r['person']);
      if (who.isEmpty) continue;
      final type = _str(r['type']);
      final known = _relationLabels[type];
      labelled('X-ABRELATEDNAMES', _text(who),
          known == null ? _label(r, type) : '_\$!<$known>!\$_');
    }

    for (final u in _entries(person, 'urls')) {
      final value = _str(u['value']);
      if (value.isEmpty) continue;
      final type = _str(u['type']);
      switch (type) {
        case 'home' || 'work':
          lines.add('URL;TYPE=${type.toUpperCase()}:${_plain(value)}');
        case '' || 'other':
          lines.add('URL:${_plain(value)}');
        case 'homePage':
          labelled('URL', _plain(value), r'_$!<HomePage>!$_');
        default:
          labelled('URL', _plain(value), _label(u, type));
      }
    }

    for (final im in _entries(person, 'imClients')) {
      final username = _str(im['username']);
      if (username.isEmpty) continue;
      final protocol = _str(im['protocol']);
      final property = _imProperties[protocol];
      if (property != null) {
        lines.add('$property:${_text(username)}');
      } else {
        final service = _str(im['formattedProtocol']).isNotEmpty
            ? _str(im['formattedProtocol'])
            : protocol;
        labelled('X-IM', _text(username), service.isEmpty ? 'IM' : service);
      }
    }
    for (final s in _entries(person, 'sipAddresses')) {
      final value = _str(s['value']);
      if (value.isNotEmpty) lines.add('X-SIP:${_text(value)}');
    }

    for (final c in _entries(person, 'calendarUrls')) {
      final value = _str(c['url']);
      if (value.isNotEmpty) lines.add('CALURI:${_plain(value)}');
    }

    for (final field in _entries(person, 'userDefined')) {
      final key = _str(field['key']);
      final value = _str(field['value']);
      if (key.isEmpty && value.isEmpty) continue;
      labelled('X-CUSTOM', _text(value), key);
    }

    for (final (key, property) in const [
      ('genders', 'X-GENDER'),
      ('interests', 'X-INTEREST'),
      ('skills', 'X-SKILL'),
      ('locations', 'X-LOCATION'),
      ('miscKeywords', 'X-KEYWORD'),
      ('externalIds', 'X-EXTERNAL-ID'),
      ('fileAses', 'X-FILE-AS'),
    ]) {
      for (final e in _entries(person, key)) {
        final value = _str(e['value']);
        if (value.isNotEmpty) lines.add('$property:${_text(value)}');
      }
    }

    final bio = _entries(person, 'biographies').firstOrNull;
    if (bio != null) {
      final raw = _str(bio['value']);
      final note =
          _str(bio['contentType']) == 'TEXT_HTML' ? _noteText(raw) : raw;
      if (note.isNotEmpty) lines.add('NOTE:${_text(note)}');
    }

    final labels = [
      for (final m in _entries(person, 'memberships'))
        if (m['contactGroupMembership'] case final Map membership)
          if (labelNames[_str(membership['contactGroupResourceName'])]
              case final name? when name.isNotEmpty)
            _text(name),
    ];
    if (labels.isNotEmpty) lines.add('CATEGORIES:${labels.join(',')}');

    lines.add('END:VCARD');
    return lines;
  }

  /// The name the card is shown under: Google's display name, else the
  /// parts, else whatever else identifies the contact. FN is required.
  static String _fullName(
    Map<String, Object?> person,
    Map<String, Object?>? name,
  ) {
    for (final candidate in [
      _str(name?['displayName']),
      _str(name?['unstructuredName']),
      [
        _str(name?['honorificPrefix']),
        _str(name?['givenName']),
        _str(name?['middleName']),
        _str(name?['familyName']),
        _str(name?['honorificSuffix']),
      ].where((s) => s.isNotEmpty).join(' '),
      _str(_entries(person, 'organizations').firstOrNull?['name']),
      _str(_entries(person, 'emailAddresses').firstOrNull?['value']),
      _str(_entries(person, 'phoneNumbers').firstOrNull?['value']),
    ]) {
      if (candidate.isNotEmpty) return candidate;
    }
    return '';
  }

  /// Google's phone types in vCard's words; a type not here goes with a
  /// label instead.
  static const _phoneTypes = {
    '': <String>[],
    'other': <String>[],
    'mobile': ['CELL'],
    'home': ['HOME'],
    'work': ['WORK'],
    'homeFax': ['HOME', 'FAX'],
    'workFax': ['WORK', 'FAX'],
    'otherFax': ['FAX'],
    'pager': ['PAGER'],
    'workMobile': ['WORK', 'CELL'],
    'workPager': ['WORK', 'PAGER'],
    'main': ['MAIN'],
  };

  /// Google's relation types that Apple's address book, and Google's
  /// import, know by a label of their own.
  static const _relationLabels = {
    'spouse': 'Spouse',
    'child': 'Child',
    'mother': 'Mother',
    'father': 'Father',
    'parent': 'Parent',
    'brother': 'Brother',
    'sister': 'Sister',
    'friend': 'Friend',
    'manager': 'Manager',
    'assistant': 'Assistant',
    'partner': 'Partner',
    'domesticPartner': 'Partner',
  };

  /// IM protocols with a property of their own.
  static const _imProperties = {
    'aim': 'X-AIM',
    'msn': 'X-MSN',
    'yahoo': 'X-YAHOO',
    'skype': 'X-SKYPE',
    'qq': 'X-QQ',
    'googleTalk': 'X-GOOGLE-TALK',
    'icq': 'X-ICQ',
    'jabber': 'X-JABBER',
  };

  /// The label an entry shows under: Google's own wording of a custom
  /// type, else the type itself.
  static String _label(Map<String, Object?> entry, String type) {
    final formatted = _str(entry['formattedType']);
    if (formatted.isNotEmpty) return formatted;
    return type.isEmpty ? 'Other' : type;
  }

  /// [property] with a People API date: `BDAY:1980-05-17`, or with no
  /// year Apple's form, `BDAY;X-APPLE-OMIT-YEAR=1604:1604-05-17`. Google
  /// is reported to drop vCard's own `--05-17` without a word, and keeps
  /// Apple's: Thunderbird writes it for that reason (Mozilla bug 1820356).
  /// Null for no date, or one without a month and day.
  static String? _dated(String property, Object? date) {
    if (date is! Map) return null;
    final month = date['month'], day = date['day'], year = date['year'];
    if (month is! int || day is! int || month == 0 || day == 0) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    if (year is int && year > 0) {
      return '$property:${year.toString().padLeft(4, '0')}-${two(month)}-'
          '${two(day)}';
    }
    return '$property;X-APPLE-OMIT-YEAR=1604:1604-${two(month)}-${two(day)}';
  }

  /// An HTML note as the text it shows, read with package:html: every
  /// entity decoded (`&#1488;`, `&#8217;` and the named ones alike), a
  /// line break for `<br>` and after each block, and a link's target kept
  /// after its words, "site (https://...)", unless the words are the
  /// target already. Scripts and styles are left out.
  static String _noteText(String html) {
    final out = StringBuffer();
    void walk(dom.Node node) {
      if (node is dom.Text) {
        // White space in HTML source is a space wherever it falls.
        out.write(node.data.replaceAll(RegExp(r'\s+'), ' '));
        return;
      }
      if (node is! dom.Element) {
        node.nodes.forEach(walk);
        return;
      }
      final tag = node.localName;
      if (tag == 'script' || tag == 'style') return;
      if (tag == 'br') {
        out.write('\n');
        return;
      }
      node.nodes.forEach(walk);
      if (tag == 'a') {
        final href = (node.attributes['href'] ?? '').trim();
        const mailto = 'mailto:';
        final target =
            href.startsWith(mailto) ? href.substring(mailto.length) : href;
        if (target.isNotEmpty && target != node.text.trim()) {
          out.write(' ($target)');
        }
      }
      if (_blocks.contains(tag)) out.write('\n');
    }

    walk(html_parser.parseFragment(html));
    return out
        .toString()
        .replaceAll(RegExp(r' *\n *'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// The elements a line break follows.
  static const _blocks = {
    'p', 'div', 'li', 'tr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', //
    'blockquote', 'pre', 'table', 'ul', 'ol',
  };

  /// A text value escaped as RFC 2426 asks: backslash, comma, semicolon
  /// and line breaks.
  static String _text(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', r'\n')
      .replaceAll(',', r'\,')
      .replaceAll(';', r'\;');

  /// A phone number or a URI as it is: RFC 2426 types TEL as
  /// phone-number and URL as uri, not text, so nothing in them is escaped
  /// (a pause in a number is a comma, and a URL may well have one). Only
  /// line breaks go, which neither can hold and which would end the line.
  static String _plain(String value) => value.replaceAll(RegExp(r'[\r\n]'), '');

  /// [line] folded so that no line is longer than 75 octets, each
  /// continuation starting with a space, and never inside a character.
  static String _fold(String line) {
    if (utf8.encode(line).length <= 75) return line;
    final out = StringBuffer();
    var octets = 0;
    for (final rune in line.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (octets + size > 75) {
        out.write('\r\n ');
        octets = 1;
      }
      out.write(char);
      octets += size;
    }
    return out.toString();
  }

  /// A field's entries that come from the contact itself.
  static List<Map<String, Object?>> _entries(
    Map<String, Object?> person,
    String field,
  ) {
    final list = person[field];
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map && _fromContact(e)) e.cast<String, Object?>(),
    ];
  }

  static bool _fromContact(Map<Object?, Object?> entry) {
    final metadata = entry['metadata'];
    if (metadata is! Map) return true;
    final source = metadata['source'];
    if (source is! Map) return true;
    final type = source['type'];
    return type == null || type == 'CONTACT';
  }

  // --- Outlook's CSV --------------------------------------------------------

  static Map<String, String> _row(Map<String, Object?> c) {
    final given = _str(c['givenName']);
    final middle = _str(c['middleName']);
    final surname = _str(c['surname']);
    final displayName = _str(c['displayName']);
    final row = <String, String>{
      'First Name': given.isEmpty && middle.isEmpty && surname.isEmpty
          ? displayName
          : given,
      'Middle Name': middle,
      'Last Name': surname,
      'Title': _str(c['title']),
      'Suffix': _str(c['generation']),
      'Nickname': _str(c['nickName']),
      'Given Yomi': _str(c['yomiGivenName']),
      'Surname Yomi': _str(c['yomiSurname']),
      'Mobile Phone': _str(c['mobilePhone']),
      // Outlook's import takes one; every one is kept, rather than any
      // being lost.
      'IMAddress': _strings(c['imAddresses']).join(';'),
      'Job Title': _str(c['jobTitle']),
      'Department': _str(c['department']),
      'Company': _str(c['companyName']),
      'Office Location': _str(c['officeLocation']),
      "Manager's Name": _str(c['manager']),
      "Assistant's Name": _str(c['assistantName']),
      'Company Yomi': _str(c['yomiCompanyName']),
      'Spouse': _str(c['spouseName']),
      'Web Page': _str(c['businessHomePage']),
      'Birthday': _birthday(c['birthday']),
      'Notes': _str(c['personalNotes']),
      'Initials': _str(c['initials']),
      'Profession': _str(c['profession']),
      'Children': _strings(c['children']).join(';'),
      'Categories': _strings(c['categories']).join(';'),
      'Display Name': displayName,
      'File As': _str(c['fileAs']),
    };
    final emails = [
      if (c['emailAddresses'] case final List list)
        for (final e in list)
          if (e is Map && _str(e['address']).isNotEmpty) e,
    ];
    for (final (i, (address, name)) in const [
      ('E-mail Address', 'E-mail Display Name'),
      ('E-mail 2 Address', 'E-mail 2 Display Name'),
      ('E-mail 3 Address', 'E-mail 3 Display Name'),
    ].indexed) {
      if (i >= emails.length) break;
      row[address] = _str(emails[i]['address']);
      row[name] = _str(emails[i]['name']);
    }
    final home = _strings(c['homePhones']);
    final business = _strings(c['businessPhones']);
    for (final (list, first, second) in [
      (home, 'Home Phone', 'Home Phone 2'),
      (business, 'Business Phone', 'Business Phone 2'),
    ]) {
      if (list.isNotEmpty) row[first] = list[0];
      if (list.length > 1) row[second] = list[1];
    }
    for (final (key, kind) in const [
      ('businessAddress', 'Business'),
      ('homeAddress', 'Home'),
      ('otherAddress', 'Other'),
    ]) {
      final a = c[key];
      if (a is! Map) continue;
      row['$kind Street'] = _str(a['street']);
      row['$kind City'] = _str(a['city']);
      row['$kind State'] = _str(a['state']);
      row['$kind Postal Code'] = _str(a['postalCode']);
      row['$kind Country/Region'] = _str(a['countryOrRegion']);
    }
    return row;
  }

  /// A Graph birthday as the date it is: the UTC date of the value plus
  /// twelve hours, which is right whether it was written at midnight UTC,
  /// at 11:59 UTC as Exchange keeps it, or at midnight in a zone either
  /// side of UTC. Written as YYYY-MM-DD, which no reader takes for another
  /// day; a year before 1700 is Outlook's way of saying none, and is kept
  /// as it is for Outlook to read the same way.
  static String _birthday(Object? value) {
    final at = DateTime.tryParse(_str(value));
    if (at == null) return '';
    final day = at.toUtc().add(const Duration(hours: 12));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-'
        '${two(day.day)}';
  }

  static String _csvField(String value) => '"${value.replaceAll('"', '""')}"';

  // --- reading the JSON -----------------------------------------------------

  static String _str(Object? value) => value is String ? value : '';

  static List<String> _strings(Object? value) => [
        if (value is List)
          for (final v in value)
            if (v is String && v.isNotEmpty) v,
      ];
}
