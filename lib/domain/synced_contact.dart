import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

/// The two address books the contact sync keeps in step: Gmail's contacts
/// (Google's People API) and a Microsoft 365 mailbox's Contacts folder
/// (Microsoft Graph). Named after the services, as the stored rows are
/// (`google_name`, `graph_id`), because the code works with any Microsoft
/// account even though the one Ron syncs is Hadco's.
enum ContactSide {
  google,
  graph;

  ContactSide get other => this == google ? graph : google;
}

/// What sort of value a [ContactField] holds, which decides how it is
/// compared and merged.
enum ContactValueKind {
  /// A [ContactName].
  name,

  /// One line of text.
  text,

  /// One phone number, as typed.
  phone,

  /// One web address.
  webPage,

  /// A [ContactAddress], always sent whole.
  address,

  /// A [ContactBirthday].
  birthday,

  /// [ContactNotes].
  notes,

  /// A list of email addresses.
  emails,

  /// A list of phone numbers.
  phones,

  /// A list of lines of text: IM names, children.
  texts;

  bool get isList => this == emails || this == phones || this == texts;
}

/// The details the sync copies, each compared, merged and written on its
/// own. Lists merge by value; everything else is a single detail, which
/// clashes when both sides change it to different values.
///
/// [slots] is how many values Outlook takes for a list. More are never
/// sent, because what Graph does with more is undocumented; Gmail keeps
/// them.
enum ContactField {
  name(ContactValueKind.name),
  nickname(ContactValueKind.text),
  emails(ContactValueKind.emails, slots: 3),
  mobile(ContactValueKind.phone),
  homePhones(ContactValueKind.phones, slots: 2),
  workPhones(ContactValueKind.phones, slots: 2),
  homeAddress(ContactValueKind.address),
  workAddress(ContactValueKind.address),
  otherAddress(ContactValueKind.address),
  company(ContactValueKind.text),
  department(ContactValueKind.text),
  jobTitle(ContactValueKind.text),
  office(ContactValueKind.text),
  birthday(ContactValueKind.birthday),
  notes(ContactValueKind.notes),
  spouse(ContactValueKind.text),
  children(ContactValueKind.texts),
  manager(ContactValueKind.text),
  assistant(ContactValueKind.text),
  webPage(ContactValueKind.webPage),
  im(ContactValueKind.texts, slots: 3);

  const ContactField(this.kind, {this.slots});

  final ContactValueKind kind;

  /// Outlook's limit for a list; null where there is none.
  final int? slots;

  bool get isList => kind.isList;

  static ContactField? byName(String name) =>
      ContactField.values.firstWhereOrNull((f) => f.name == name);
}

/// A name in parts. A side with no parts at all has a [display] instead
/// (Outlook's `displayName`, Gmail's `unstructuredName`), which travels in
/// their place; where there are parts, [display] is always null, because
/// the shown name is not compared.
@immutable
class ContactName {
  const ContactName._({
    this.given,
    this.middle,
    this.family,
    this.prefix,
    this.suffix,
    this.phoneticGiven,
    this.phoneticFamily,
    this.display,
  });

  /// A name, with every empty part dropped, and [display] kept only when
  /// there are no parts. Null when nothing is left.
  static ContactName? of({
    String? given,
    String? middle,
    String? family,
    String? prefix,
    String? suffix,
    String? phoneticGiven,
    String? phoneticFamily,
    String? display,
  }) {
    final name = ContactName._(
      given: _blankToNull(given),
      middle: _blankToNull(middle),
      family: _blankToNull(family),
      prefix: _blankToNull(prefix),
      suffix: _blankToNull(suffix),
      phoneticGiven: _blankToNull(phoneticGiven),
      phoneticFamily: _blankToNull(phoneticFamily),
    );
    if (name.hasParts) return name;
    final shown = _blankToNull(display);
    return shown == null ? null : ContactName._(display: shown);
  }

  final String? given;
  final String? middle;
  final String? family;

  /// Gmail's `honorificPrefix`, Outlook's `title`.
  final String? prefix;

  /// Gmail's `honorificSuffix`, Outlook's `generation`.
  final String? suffix;

  /// Gmail's `phoneticGivenName`, Outlook's `yomiGivenName`.
  final String? phoneticGiven;

  /// Gmail's `phoneticFamilyName`, Outlook's `yomiSurname`.
  final String? phoneticFamily;

  final String? display;

  bool get hasParts => [
    given,
    middle,
    family,
    prefix,
    suffix,
    phoneticGiven,
    phoneticFamily,
  ].any((p) => p != null);

  /// The name as one line: the parts in the usual order, or [display].
  String get shown => hasParts
      ? [prefix, given, middle, family, suffix].nonNulls.join(' ').trim()
      : display ?? '';

  Map<String, Object?> toJson() => {
    'given': ?given,
    'middle': ?middle,
    'family': ?family,
    'prefix': ?prefix,
    'suffix': ?suffix,
    'phoneticGiven': ?phoneticGiven,
    'phoneticFamily': ?phoneticFamily,
    'display': ?display,
  };

  static ContactName? fromJson(Object? json) {
    if (json is! Map) return null;
    String? s(String key) => json[key] is String ? json[key] as String : null;
    return ContactName.of(
      given: s('given'),
      middle: s('middle'),
      family: s('family'),
      prefix: s('prefix'),
      suffix: s('suffix'),
      phoneticGiven: s('phoneticGiven'),
      phoneticFamily: s('phoneticFamily'),
      display: s('display'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContactName &&
      other.given == given &&
      other.middle == middle &&
      other.family == family &&
      other.prefix == prefix &&
      other.suffix == suffix &&
      other.phoneticGiven == phoneticGiven &&
      other.phoneticFamily == phoneticFamily &&
      other.display == display;

  @override
  int get hashCode => Object.hash(
    given,
    middle,
    family,
    prefix,
    suffix,
    phoneticGiven,
    phoneticFamily,
    display,
  );

  // Never the values themselves, here or below: logs get no names,
  // addresses or dates (the plan's Privacy).
  @override
  String toString() => 'ContactName(${hasParts ? 'parts' : 'shown'})';
}

/// A postal address. [street] may run to several lines: to Outlook it is
/// Gmail's `streetAddress` and, on a line of its own, `extendedAddress`.
@immutable
class ContactAddress {
  const ContactAddress._({
    this.street,
    this.city,
    this.region,
    this.postalCode,
    this.country,
  });

  /// Null when every part is empty.
  static ContactAddress? of({
    String? street,
    String? city,
    String? region,
    String? postalCode,
    String? country,
  }) {
    final address = ContactAddress._(
      street: _blankToNull(street),
      city: _blankToNull(city),
      region: _blankToNull(region),
      postalCode: _blankToNull(postalCode),
      country: _blankToNull(country),
    );
    return [
          address.street,
          address.city,
          address.region,
          address.postalCode,
          address.country,
        ].every((p) => p == null)
        ? null
        : address;
  }

  final String? street;
  final String? city;

  /// Gmail's `region`, Outlook's `state`.
  final String? region;
  final String? postalCode;

  /// As typed: a name or a code. Compared as an ISO code.
  final String? country;

  String get shown => [
    street?.replaceAll(RegExp(r'\r?\n'), ', '),
    city,
    region,
    postalCode,
    country,
  ].nonNulls.join(', ');

  Map<String, Object?> toJson() => {
    'street': ?street,
    'city': ?city,
    'region': ?region,
    'postalCode': ?postalCode,
    'country': ?country,
  };

  static ContactAddress? fromJson(Object? json) {
    if (json is! Map) return null;
    String? s(String key) => json[key] is String ? json[key] as String : null;
    return ContactAddress.of(
      street: s('street'),
      city: s('city'),
      region: s('region'),
      postalCode: s('postalCode'),
      country: s('country'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContactAddress &&
      other.street == street &&
      other.city == city &&
      other.region == region &&
      other.postalCode == postalCode &&
      other.country == country;

  @override
  int get hashCode => Object.hash(street, city, region, postalCode, country);

  @override
  String toString() => 'ContactAddress(${toJson().length} parts)';
}

/// A birthday as the date it falls on. Outlook keeps a time with it,
/// which is read away (see the mapping); a [year] of null is a birthday
/// without a year, which never travels to the other side.
@immutable
class ContactBirthday {
  const ContactBirthday({this.year, required this.month, required this.day});

  final int? year;
  final int month;
  final int day;

  bool get hasYear => year != null;

  /// Whether the two fall on the same day of the year.
  bool sameDay(ContactBirthday other) =>
      other.month == month && other.day == day;

  String get shown {
    String two(int n) => n.toString().padLeft(2, '0');
    return year == null
        ? '--${two(month)}-${two(day)}'
        : '${year.toString().padLeft(4, '0')}-${two(month)}-${two(day)}';
  }

  Map<String, Object?> toJson() => {'year': ?year, 'month': month, 'day': day};

  static ContactBirthday? fromJson(Object? json) {
    if (json is! Map) return null;
    final month = json['month'];
    final day = json['day'];
    final year = json['year'];
    if (month is! int || day is! int) return null;
    return ContactBirthday(
      year: year is int ? year : null,
      month: month,
      day: day,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContactBirthday &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      'ContactBirthday(${hasYear ? 'with a year' : 'without a year'})';
}

/// A contact's notes. Gmail may keep them as HTML ([html]); Outlook's are
/// plain text.
@immutable
class ContactNotes {
  const ContactNotes(this.value, {this.html = false});

  final String value;
  final bool html;

  /// The notes as plain text, line ends as LF.
  String get text => html ? htmlToText(value) : value;

  Map<String, Object?> toJson() => {'value': value, if (html) 'html': true};

  static ContactNotes? fromJson(Object? json) {
    if (json is! Map || json['value'] is! String) return null;
    final value = json['value'] as String;
    if (value.trim().isEmpty) return null;
    return ContactNotes(value, html: json['html'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is ContactNotes && other.value == value && other.html == html;

  @override
  int get hashCode => Object.hash(value, html);

  @override
  String toString() => 'ContactNotes(${html ? 'html' : 'text'})';
}

/// One contact's synced details, raw: as its server returned them, with
/// nothing normalised. A side has changed a detail when its current raw
/// value differs from its stored base, so a fix to capitals or punctuation
/// is a change like any other; the normalised forms of [ContactNormaliser]
/// only tell whether a Gmail value and an Outlook value are the same.
///
/// Empty values are dropped, so empty equals missing. The values are
/// [ContactName], [ContactAddress], [ContactBirthday], [ContactNotes],
/// `String` for the other single details and `List<String>` for lists,
/// as [ContactField.kind] says.
///
/// [toJson] is the form the rows keep as a side's base.
@immutable
class SyncedContact {
  SyncedContact([Map<ContactField, Object?> values = const {}])
    : values = Map.unmodifiable({
        for (final e in values.entries)
          if (_cleaned(e.key, e.value) case final Object v) e.key: v,
      });

  static final empty = SyncedContact();

  final Map<ContactField, Object> values;

  Object? operator [](ContactField field) => values[field];

  /// The name as its server returned it, raw: a display name alone is
  /// kept even when it is one of the contact's own emails or its company
  /// (see [copyableName]).
  ContactName? get name => values[ContactField.name] as ContactName?;

  /// [name] when it is a name to copy: not a display name alone that is
  /// one of the contact's own emails or its company, which Outlook (and
  /// Google) show when a contact has no name, nor one that is a single
  /// word with an `@` in it, an address shown even after the contact's
  /// address changed (Outlook does not always remake it). The test is
  /// made only where a name would be copied to the other side (a fill, a
  /// one-sided change, a create), never on the stored bases, so an edit
  /// to an email or the company never reads as a change of name.
  ContactName? get copyableName {
    final n = name;
    if (n == null || n.hasParts) return n;
    final shown = ContactNormaliser.textKey(n.display);
    if (shown != null && !shown.contains(' ') && shown.contains('@')) {
      return null;
    }
    for (final other in [
      ...list(ContactField.emails),
      ?text(ContactField.company),
    ]) {
      if (ContactNormaliser.textKey(other) == shown) return null;
    }
    return n;
  }

  String? text(ContactField field) =>
      field.isList ? null : values[field] as String?;

  List<String> list(ContactField field) =>
      field.isList ? (values[field] as List<String>?) ?? const [] : const [];

  ContactAddress? address(ContactField field) =>
      values[field] is ContactAddress ? values[field] as ContactAddress : null;

  ContactBirthday? get birthday =>
      values[ContactField.birthday] as ContactBirthday?;

  ContactNotes? get notes => values[ContactField.notes] as ContactNotes?;

  bool get isEmpty => values.isEmpty;

  /// A copy with [field] set to [value] (null clears it).
  SyncedContact withValue(ContactField field, Object? value) =>
      SyncedContact({...values, field: value});

  /// A copy whose [fields] come from [other].
  SyncedContact withFieldsFrom(
    SyncedContact other,
    Iterable<ContactField> fields,
  ) => SyncedContact({
    ...values,
    for (final f in fields) f: other.values[f],
  });

  /// Whether [field] holds the same raw value here and in [other].
  bool sameRaw(SyncedContact other, ContactField field) =>
      rawEquals(values[field], other.values[field]);

  /// What to call the contact on screen: its name, else its nickname,
  /// first email address or company.
  String get title {
    final shown = name?.shown ?? '';
    if (shown.isNotEmpty) return shown;
    return text(ContactField.nickname) ??
        list(ContactField.emails).firstOrNull ??
        text(ContactField.company) ??
        text(ContactField.mobile) ??
        '';
  }

  /// The value of [field] as one line, for Needs a look.
  static String describe(ContactField field, Object? value) => switch (value) {
    null => '',
    final ContactName n => n.shown,
    final ContactAddress a => a.shown,
    final ContactBirthday b => b.shown,
    final ContactNotes n => n.text,
    final List<String> l => l.join(', '),
    final String s => s,
    _ => '',
  };

  Map<String, Object?> toJson() => {
    for (final e in values.entries) e.key.name: valueToJson(e.value),
  };

  static Object? valueToJson(Object? value) => switch (value) {
    final ContactName n => n.toJson(),
    final ContactAddress a => a.toJson(),
    final ContactBirthday b => b.toJson(),
    final ContactNotes n => n.toJson(),
    final List<String> l => [...l],
    _ => value,
  };

  /// [field]'s value from its [toJson] form; null for anything else.
  static Object? valueFromJson(ContactField field, Object? json) =>
      switch (field.kind) {
        ContactValueKind.name => ContactName.fromJson(json),
        ContactValueKind.address => ContactAddress.fromJson(json),
        ContactValueKind.birthday => ContactBirthday.fromJson(json),
        ContactValueKind.notes => ContactNotes.fromJson(json),
        ContactValueKind.emails ||
        ContactValueKind.phones ||
        ContactValueKind.texts =>
          json is List ? json.whereType<String>().toList() : null,
        _ => json is String ? json : null,
      };

  /// A base as [toJson] wrote it. Unknown keys are passed over, so an
  /// older build reading a newer base loses nothing it knows.
  static SyncedContact fromJson(Object? json) {
    if (json is! Map) return empty;
    return SyncedContact({
      for (final e in json.entries)
        if (e.key is String)
          if (ContactField.byName(e.key as String) case final ContactField f)
            f: valueFromJson(f, e.value),
    });
  }

  static Object? _cleaned(ContactField field, Object? value) {
    switch (value) {
      case null:
        return null;
      case final String s:
        if (field.isList) return null;
        return s.trim().isEmpty ? null : s;
      case final List<Object?> l:
        if (!field.isList) return null;
        final kept = [
          for (final v in l)
            if (v is String && v.trim().isNotEmpty) v,
        ];
        return kept.isEmpty ? null : List<String>.unmodifiable(kept);
      case final ContactNotes n:
        return field.kind == ContactValueKind.notes && n.value.trim().isNotEmpty
            ? n
            : null;
      case ContactName():
        return field.kind == ContactValueKind.name ? value : null;
      case ContactAddress():
        return field.kind == ContactValueKind.address ? value : null;
      case ContactBirthday():
        return field.kind == ContactValueKind.birthday ? value : null;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SyncedContact &&
      other.values.length == values.length &&
      ContactField.values.every((f) => sameRaw(other, f));

  @override
  int get hashCode => Object.hashAll(
    ContactField.values.map((f) => _rawHash(values[f])),
  );

  @override
  String toString() => 'SyncedContact(${values.keys.map((f) => f.name)})';
}

/// Raw equality of two values of one field: exact, lists in order.
bool rawEquals(Object? a, Object? b) {
  if (a is List && b is List) return const ListEquality<Object?>().equals(a, b);
  return a == b;
}

int _rawHash(Object? v) =>
    v is List ? const ListEquality<Object?>().hash(v) : v.hashCode;

String? _blankToNull(String? s) => s == null || s.trim().isEmpty ? null : s;

/// The normaliser's version. A change to [ContactNormaliser] changes it,
/// and a pair whose stored version differs takes full listings, so the
/// change means one full comparison rather than a wave of edits: the
/// bases are raw, so a new normaliser alone never reads as a change.
const contactNormaliserVersion = 1;

/// The forms that tell whether a Gmail value and an Outlook value are the
/// same: names and other text without case and with runs of spaces
/// collapsed, emails lower-cased, phones as E.164 keys (one region for
/// both sides, the pair's), addresses part by part with countries as ISO
/// codes, notes as text with LF line ends, web pages with the scheme and
/// host lower-cased and no trailing slash. Empty is the same as missing:
/// every key of an empty value is null.
class ContactNormaliser {
  /// [region] is the pair's phone region, an ISO code such as `US`: the
  /// phone's country when the first sync started. Without one the parser
  /// guesses each number's country from its first digits, and "+1 212 …"
  /// and "212 …" stop being the same number, so it is required; an
  /// unknown code is an [ArgumentError] (see [isRegion]).
  ContactNormaliser({required String region})
    : region = _isoCode(region) ?? (throw ArgumentError.value(region));

  /// For one contact's own lists only, where nothing is compared with the
  /// other side: a create's lists, de-duplicated. Never for matching or
  /// for comparing a Gmail value with an Outlook one.
  ContactNormaliser.oneContact() : region = null;

  /// Numbers written without a country code are read as in it.
  final IsoCode? region;

  /// Whether [code] is a region the parser knows.
  static bool isRegion(String code) => _isoCode(code) != null;

  static IsoCode? _isoCode(String region) {
    final upper = region.trim().toUpperCase();
    return IsoCode.values.firstWhereOrNull((c) => c.name == upper);
  }

  /// Text without case, spaces collapsed.
  static String? textKey(String? s) {
    if (s == null) return null;
    final squashed = s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    return squashed.isEmpty ? null : squashed;
  }

  static String? emailKey(String? s) {
    final key = s?.trim().toLowerCase();
    return key == null || key.isEmpty ? null : key;
  }

  /// A phone number as an E.164 key, `+` and digits, read by the same
  /// pure-Dart parser on both sides; its digits alone when the parser
  /// cannot read it.
  String? phoneKey(String? s) {
    if (s == null) return null;
    final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    try {
      final number = PhoneNumber.parse(s, callerCountry: region);
      if (number.nsn.isNotEmpty) return number.international;
    } catch (_) {
      // Not a number the parser knows: the digits will have to do.
    }
    return s.trimLeft().startsWith('+') ? '+$digits' : digits;
  }

  /// Scheme and host lower-cased, no trailing slash; a page typed without
  /// a scheme is read as http.
  static String? webKey(String? s) {
    if (s == null) return null;
    var url = s.trim();
    if (url.isEmpty) return null;
    if (!url.contains('://')) url = 'http://$url';
    final schemeEnd = url.indexOf('://');
    final rest = url.substring(schemeEnd + 3);
    final hostEnd = rest.indexOf(RegExp(r'[/?#]'));
    final host = hostEnd < 0 ? rest : rest.substring(0, hostEnd);
    final path = hostEnd < 0 ? '' : rest.substring(hostEnd);
    var key =
        '${url.substring(0, schemeEnd).toLowerCase()}://'
        '${host.toLowerCase()}$path';
    while (key.endsWith('/')) {
      key = key.substring(0, key.length - 1);
    }
    return key;
  }

  /// Notes as text: LF line ends, no spaces at the ends of lines, none
  /// around the whole. Case is kept.
  static String? notesKey(ContactNotes? notes) {
    if (notes == null) return null;
    final text = notes.text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trimRight())
        .join('\n')
        .trim();
    return text.isEmpty ? null : text;
  }

  /// A street compared with LF line ends.
  static String? streetKey(String? street) {
    if (street == null) return null;
    final lines = street
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map(textKey)
        .nonNulls;
    final key = lines.join('\n');
    return key.isEmpty ? null : key;
  }

  /// A country as its ISO code where it is known, else its text key.
  static String? countryKey(String? country) {
    final key = textKey(country);
    if (key == null) return null;
    return countryCodeFor(country!) ?? key;
  }

  static String? addressKey(ContactAddress? a) {
    if (a == null) return null;
    final parts = [
      streetKey(a.street),
      textKey(a.city),
      textKey(a.region),
      textKey(a.postalCode)?.replaceAll(' ', ''),
      countryKey(a.country),
    ];
    if (parts.every((p) => p == null)) return null;
    return parts.map((p) => p ?? '').join('|');
  }

  static String? nameKey(ContactName? n) {
    if (n == null) return null;
    if (!n.hasParts) return 'shown:${textKey(n.display)}';
    return 'parts:${[
      n.given,
      n.middle,
      n.family,
      n.prefix,
      n.suffix,
      n.phoneticGiven,
      n.phoneticFamily,
    ].map((p) => textKey(p) ?? '').join('|')}';
  }

  static String? birthdayKey(ContactBirthday? b) => b?.shown;

  /// The comparable form of a single detail; null when it is empty.
  String? key(ContactField field, Object? value) => switch (field.kind) {
    ContactValueKind.name => nameKey(value as ContactName?),
    ContactValueKind.text => textKey(value as String?),
    ContactValueKind.phone => phoneKey(value as String?),
    ContactValueKind.webPage => webKey(value as String?),
    ContactValueKind.address => addressKey(value as ContactAddress?),
    ContactValueKind.birthday => birthdayKey(value as ContactBirthday?),
    ContactValueKind.notes => notesKey(value as ContactNotes?),
    _ => null,
  };

  /// The comparable form of one value in a list.
  String? itemKey(ContactField field, String value) => switch (field.kind) {
    ContactValueKind.emails => emailKey(value),
    ContactValueKind.phones => phoneKey(value),
    _ => textKey(value),
  };

  /// Whether [a] and [b], both values of [field], are the same.
  ///
  /// Two names are compared part by part; where either side has no parts
  /// the shown names are compared. A birthday without a year is the same
  /// as one with a year on the same day: Outlook's year can be added to
  /// Gmail's, and Gmail's missing one never travels. Lists are the same
  /// when they hold the same values, in any order.
  bool same(ContactField field, Object? a, Object? b) {
    if (field.isList) {
      final ka = {
        for (final v in (a as List<String>?) ?? const <String>[])
          ?itemKey(field, v),
      };
      final kb = {
        for (final v in (b as List<String>?) ?? const <String>[])
          ?itemKey(field, v),
      };
      return const SetEquality<String>().equals(ka, kb);
    }
    if (field == ContactField.name && a is ContactName && b is ContactName) {
      if (a.hasParts && b.hasParts) return nameKey(a) == nameKey(b);
      return textKey(a.shown) == textKey(b.shown);
    }
    if (field == ContactField.birthday &&
        a is ContactBirthday &&
        b is ContactBirthday) {
      if (a.hasYear && b.hasYear) return a == b;
      return a.sameDay(b);
    }
    return key(field, a) == key(field, b);
  }

  /// Whether writing [a] over [b] would change nothing: the same text
  /// give or take spaces at the ends and runs of spaces, with capitals
  /// counting, so a fix to them is still copied; phones by their E.164
  /// keys, web pages and countries by their keys, notes as text (so an
  /// HTML note is not replaced by the same words). A birthday with a year
  /// written over the same day without one is a change, since it adds the
  /// year; one without a year over the same day with a year is not (it
  /// never travels anyway). Lists as in [same].
  bool equivalent(ContactField field, Object? a, Object? b) {
    if (a == null || b == null) return a == null && b == null;
    switch (field.kind) {
      case ContactValueKind.birthday:
        final x = a as ContactBirthday;
        final y = b as ContactBirthday;
        if (x.hasYear && !y.hasYear) return false;
        return same(field, x, y);
      case ContactValueKind.name:
        final x = a as ContactName;
        final y = b as ContactName;
        if (!x.hasParts || !y.hasParts) {
          return _spaced(x.shown) == _spaced(y.shown);
        }
        return _spaced(x.given) == _spaced(y.given) &&
            _spaced(x.middle) == _spaced(y.middle) &&
            _spaced(x.family) == _spaced(y.family) &&
            _spaced(x.prefix) == _spaced(y.prefix) &&
            _spaced(x.suffix) == _spaced(y.suffix) &&
            _spaced(x.phoneticGiven) == _spaced(y.phoneticGiven) &&
            _spaced(x.phoneticFamily) == _spaced(y.phoneticFamily);
      case ContactValueKind.text:
        return _spaced(a as String) == _spaced(b as String);
      case ContactValueKind.address:
        final x = a as ContactAddress;
        final y = b as ContactAddress;
        String? street(String? s) => s
            ?.replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n')
            .split('\n')
            .map(_spaced)
            .nonNulls
            .join('\n');
        return street(x.street) == street(y.street) &&
            _spaced(x.city) == _spaced(y.city) &&
            _spaced(x.region) == _spaced(y.region) &&
            _spaced(x.postalCode) == _spaced(y.postalCode) &&
            countryKey(x.country) == countryKey(y.country);
      default:
        return same(field, a, b);
    }
  }

  static String? _spaced(String? s) {
    if (s == null) return null;
    final spaced = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return spaced.isEmpty ? null : spaced;
  }

  /// The family names agree: the same, or one side has none.
  static bool namesAgree(ContactName? a, ContactName? b) {
    final fa = textKey(a?.family);
    final fb = textKey(b?.family);
    if (fa == null || fb == null) return true;
    return fa == fb;
  }

  /// The full name used to spot two contacts that may be one person.
  static String? fullNameKey(ContactName? n) {
    if (n == null) return null;
    return textKey(
      n.hasParts ? [n.given, n.middle, n.family].nonNulls.join(' ') : n.display,
    );
  }
}

/// HTML notes as text: line breaks where the markup breaks lines, LF line
/// ends, the parser's text otherwise.
String htmlToText(String html) {
  final buffer = StringBuffer();
  const blocks = {
    'p', 'div', 'li', 'tr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'blockquote', 'pre', 'ul', 'ol', 'table',
  };
  void walk(dom.Node node) {
    if (node is dom.Text) {
      buffer.write(node.text);
      return;
    }
    if (node is dom.Element) {
      final tag = node.localName;
      if (tag == 'br') {
        buffer.write('\n');
        return;
      }
      if (tag == 'script' || tag == 'style') return;
      final isBlock = blocks.contains(tag);
      if (isBlock && buffer.isNotEmpty && !buffer.toString().endsWith('\n')) {
        buffer.write('\n');
      }
      node.nodes.forEach(walk);
      if (isBlock && !buffer.toString().endsWith('\n')) buffer.write('\n');
      return;
    }
    node.nodes.forEach(walk);
  }

  html_parser.parseFragment(html).nodes.forEach(walk);
  return buffer
      .toString()
      .replaceAll(' ', ' ')
      .replaceAll('\r\n', '\n')
      .replaceAll(RegExp(r'\n+$'), '');
}

/// The ISO code for a country written as a name or a code; null when it
/// is not known. English names and the usual short forms.
String? countryCodeFor(String country) {
  final key = ContactNormaliser.textKey(country)?.replaceAll('.', '');
  if (key == null) return null;
  if (key.length == 2) {
    final upper = key.toUpperCase();
    if (_countryCodes.containsKey(upper)) return upper;
  }
  return _countryNames[key];
}

final Map<String, String> _countryCodes = {
  for (final entry in _countryTable.split('|'))
    entry.substring(0, 2): entry.substring(3).split(';').first,
};

final Map<String, String> _countryNames = {
  for (final entry in _countryTable.split('|'))
    for (final name in entry.substring(3).split(';'))
      name.toLowerCase(): entry.substring(0, 2),
};

/// Code, then its names, the first the one written into Gmail.
const _countryTable =
    'AD:Andorra|AE:United Arab Emirates;UAE|AF:Afghanistan|'
    'AG:Antigua and Barbuda|AI:Anguilla|AL:Albania|AM:Armenia|AO:Angola|'
    'AQ:Antarctica|AR:Argentina|AS:American Samoa|AT:Austria|'
    'AU:Australia|AW:Aruba|AX:Aland Islands|AZ:Azerbaijan|'
    'BA:Bosnia and Herzegovina|BB:Barbados|BD:Bangladesh|BE:Belgium|'
    'BF:Burkina Faso|BG:Bulgaria|BH:Bahrain|BI:Burundi|BJ:Benin|'
    'BL:Saint Barthelemy|BM:Bermuda|BN:Brunei|BO:Bolivia|'
    'BQ:Caribbean Netherlands|BR:Brazil|BS:Bahamas;The Bahamas|'
    'BT:Bhutan|BW:Botswana|BY:Belarus|BZ:Belize|CA:Canada|'
    'CC:Cocos Islands|CD:Democratic Republic of the Congo;DR Congo|'
    'CF:Central African Republic|CG:Republic of the Congo;Congo|'
    'CH:Switzerland|CI:Ivory Coast;Cote d\'Ivoire|CK:Cook Islands|'
    'CL:Chile|CM:Cameroon|CN:China|CO:Colombia|CR:Costa Rica|CU:Cuba|'
    'CV:Cape Verde;Cabo Verde|CW:Curacao|CX:Christmas Island|'
    'CY:Cyprus|CZ:Czechia;Czech Republic|DE:Germany;Deutschland|'
    'DJ:Djibouti|DK:Denmark|DM:Dominica|DO:Dominican Republic|'
    'DZ:Algeria|EC:Ecuador|EE:Estonia|EG:Egypt|ER:Eritrea|'
    'ES:Spain;Espana|ET:Ethiopia|FI:Finland|FJ:Fiji|'
    'FK:Falkland Islands|FM:Micronesia|FO:Faroe Islands|FR:France|'
    'GA:Gabon|GB:United Kingdom;UK;Great Britain;Britain;England;'
    'Scotland;Wales;Northern Ireland|GD:Grenada|GE:Georgia|'
    'GF:French Guiana|GG:Guernsey|GH:Ghana|GI:Gibraltar|GL:Greenland|'
    'GM:Gambia;The Gambia|GN:Guinea|GP:Guadeloupe|GQ:Equatorial Guinea|'
    'GR:Greece|GT:Guatemala|GU:Guam|GW:Guinea-Bissau|GY:Guyana|'
    'HK:Hong Kong|HN:Honduras|HR:Croatia|HT:Haiti|HU:Hungary|'
    'ID:Indonesia|IE:Ireland|IL:Israel|IM:Isle of Man|IN:India|'
    'IQ:Iraq|IR:Iran|IS:Iceland|IT:Italy;Italia|JE:Jersey|JM:Jamaica|'
    'JO:Jordan|JP:Japan|KE:Kenya|KG:Kyrgyzstan|KH:Cambodia|KI:Kiribati|'
    'KM:Comoros|KN:Saint Kitts and Nevis|KP:North Korea|'
    'KR:South Korea;Korea|KW:Kuwait|KY:Cayman Islands|KZ:Kazakhstan|'
    'LA:Laos|LB:Lebanon|LC:Saint Lucia|LI:Liechtenstein|LK:Sri Lanka|'
    'LR:Liberia|LS:Lesotho|LT:Lithuania|LU:Luxembourg|LV:Latvia|'
    'LY:Libya|MA:Morocco|MC:Monaco|MD:Moldova|ME:Montenegro|'
    'MF:Saint Martin|MG:Madagascar|MH:Marshall Islands|'
    'MK:North Macedonia;Macedonia|ML:Mali|MM:Myanmar;Burma|MN:Mongolia|'
    'MO:Macau;Macao|MP:Northern Mariana Islands|MQ:Martinique|'
    'MR:Mauritania|MS:Montserrat|MT:Malta|MU:Mauritius|MV:Maldives|'
    'MW:Malawi|MX:Mexico|MY:Malaysia|MZ:Mozambique|NA:Namibia|'
    'NC:New Caledonia|NE:Niger|NF:Norfolk Island|NG:Nigeria|'
    'NI:Nicaragua|NL:Netherlands;The Netherlands;Holland|NO:Norway|'
    'NP:Nepal|NR:Nauru|NU:Niue|NZ:New Zealand|OM:Oman|PA:Panama|'
    'PE:Peru|PF:French Polynesia|PG:Papua New Guinea|PH:Philippines|'
    'PK:Pakistan|PL:Poland|PM:Saint Pierre and Miquelon|'
    'PN:Pitcairn Islands|PR:Puerto Rico|PS:Palestine|PT:Portugal|'
    'PW:Palau|PY:Paraguay|QA:Qatar|RE:Reunion|RO:Romania|RS:Serbia|'
    'RU:Russia;Russian Federation|RW:Rwanda|SA:Saudi Arabia|'
    'SB:Solomon Islands|SC:Seychelles|SD:Sudan|SE:Sweden|SG:Singapore|'
    'SH:Saint Helena|SI:Slovenia|SJ:Svalbard and Jan Mayen|SK:Slovakia|'
    'SL:Sierra Leone|SM:San Marino|SN:Senegal|SO:Somalia|SR:Suriname|'
    'SS:South Sudan|ST:Sao Tome and Principe|SV:El Salvador|'
    'SX:Sint Maarten|SY:Syria|SZ:Eswatini;Swaziland|'
    'TC:Turks and Caicos Islands|TD:Chad|TG:Togo|TH:Thailand|'
    'TJ:Tajikistan|TK:Tokelau|TL:Timor-Leste;East Timor|'
    'TM:Turkmenistan|TN:Tunisia|TO:Tonga|TR:Turkey;Turkiye|'
    'TT:Trinidad and Tobago|TV:Tuvalu|TW:Taiwan|TZ:Tanzania|'
    'UA:Ukraine|UG:Uganda|US:United States;USA;US;United States of '
    'America;America|UY:Uruguay|UZ:Uzbekistan|VA:Vatican City;Holy See|'
    'VC:Saint Vincent and the Grenadines|VE:Venezuela|'
    'VG:British Virgin Islands|VI:US Virgin Islands|VN:Vietnam;Viet Nam|'
    'VU:Vanuatu|WF:Wallis and Futuna|WS:Samoa|XK:Kosovo|YE:Yemen|'
    'YT:Mayotte|ZA:South Africa|ZM:Zambia|ZW:Zimbabwe';
