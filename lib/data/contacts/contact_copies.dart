import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:cryptography/dart.dart' show DartSha256;
import 'package:flutter/foundation.dart' show immutable;

import '../../domain/synced_contact.dart';
import 'contact_mapping.dart' show birthdayFromGraph;
import 'contact_sync_planner.dart' show contactDetailShownLength;

// The merge of the copies of one person in Hadco's Contacts into the
// synced one (3.22.0): pure rules, no reads and no writes. Hadco holds
// copies of many people from before the first sync, which Outlook cannot
// merge in bulk. The runner reads each copy whole and hashes its photo;
// [mergeCopies] says what the synced copy would gain (a PATCH body and a
// photo), and, where the copies differ, what for Ron to choose. The synced
// copy always stays: the others are deleted once it holds all they hold,
// or as Ron chose.
//
// Values are contact data: shown on the screen and kept with Ron's
// question, never in a log line, a toString or an error.

/// One Outlook copy of a person, read whole.
@immutable
class OutlookCopy {
  const OutlookCopy({required this.id, required this.json, this.photo});

  /// Its immutable Graph id.
  final String id;

  /// The contact as Graph gave it: every property, not the sync's
  /// `$select`.
  final Map<String, Object?> json;

  /// A hash of its photo's bytes; null when it has none.
  final String? photo;

  @override
  String toString() =>
      'OutlookCopy(${json.length} properties${photo == null ? '' : ', photo'})';
}

/// What merging a person's copies into the synced one does.
enum CopiesOutcome {
  /// The other copies hold nothing the synced one lacks: they are deleted.
  same,

  /// They hold details it lacks ([CopiesMerge.patch],
  /// [CopiesMerge.photoFrom]): written to it first, then they are deleted.
  adds,

  /// Some detail differs ([CopiesMerge.differences]): touched only on
  /// Ron's answer.
  differs,
}

/// A detail the synced copy gains, as the screen shows it.
@immutable
class CopiesDetail {
  const CopiesDetail({required this.label, this.value});

  /// The detail's name on the screen: "Emails", "Job title", "Photo".
  final String label;

  /// One line: a list's values joined with ", ", line breaks as ", ", cut
  /// to [contactDetailShownLength] with an ellipsis. A long note is
  /// "(long note)"; a photo "a photo", or "another photo" for a second
  /// one.
  final String? value;

  @override
  bool operator ==(Object other) =>
      other is CopiesDetail && other.label == label && other.value == value;

  @override
  int get hashCode => Object.hash(label, value);

  @override
  String toString() => 'CopiesDetail($label)';
}

/// A detail the copies hold differently, each as the screen shows it
/// (see [CopiesDetail.value]); null where a copy has none.
@immutable
class CopiesDifference {
  const CopiesDifference({
    required this.label,
    this.kept,
    this.others = const {},
  });

  final String label;

  /// The synced copy's.
  final String? kept;

  /// Each other copy's, by its id, in the order the copies were given.
  final Map<String, String?> others;

  @override
  bool operator ==(Object other) =>
      other is CopiesDifference &&
      other.label == label &&
      other.kept == kept &&
      const MapEquality<String, String?>().equals(other.others, others);

  @override
  int get hashCode => Object.hash(
    label,
    kept,
    const MapEquality<String, String?>().hash(others),
  );

  @override
  String toString() => 'CopiesDifference($label, ${others.length} others)';
}

/// What merging a person's copies into the synced one does: what the
/// synced copy gains, or what differs. With [CopiesOutcome.differs],
/// [patch], [photoFrom] and [adds] are what any answer adds besides:
/// nothing is written without one.
@immutable
class CopiesMerge {
  const CopiesMerge({
    required this.outcome,
    this.patch = const {},
    this.photoFrom,
    this.adds = const [],
    this.differences = const [],
    this.fingerprint = '',
  });

  final CopiesOutcome outcome;

  /// The body of the update of the synced copy (`GraphContactsApi.update`):
  /// each property it gains or takes, collections and addresses whole.
  /// Empty when it gains nothing.
  final Map<String, Object?> patch;

  /// The copy whose photo the synced copy takes; null for none.
  final String? photoFrom;

  /// What the synced copy gains, one detail at a time: each value a list
  /// gains on its own.
  final List<CopiesDetail> adds;

  /// What differs, for Ron to choose: empty unless [outcome] is
  /// [CopiesOutcome.differs].
  final List<CopiesDifference> differences;

  /// The differences in a short fixed form, the same for the same
  /// differences however the copies or their values come: an answer is
  /// applied only to the differences Ron saw. Empty when there are none.
  /// With an answer, that of the differences it settled.
  final String fingerprint;

  @override
  String toString() =>
      'CopiesMerge(${outcome.name}, ${patch.length} properties, '
      '${adds.length} added, ${differences.length} differing'
      '${photoFrom == null ? '' : ', photo'})';
}

/// The merge of [others], copies of one person in Hadco's Contacts, into
/// [kept], the synced copy, which always stays.
///
/// Per Graph contact property (v1.0), as `_rules` lists them:
/// - Not compared: ids, times, the folder, the names Outlook makes
///   (`displayName`, `fileAs`), each email's own name, annotations
///   (`@odata.*`), and the name parts, which copies of one person share
///   by construction: the synced copy's stay.
/// - A single value (text, by its words, case and spaces aside; a phone by
///   its number; an address by its words, punctuation, line breaks and the
///   country aside; a birthday by its day): the others' that the synced
///   copy's covers change nothing; with one value that covers the synced
///   copy's and all the others' (the synced copy having none; for notes,
///   the longer holding the others; for a birthday, its year) the synced
///   copy takes it; anything else is a difference.
/// - A list: the synced copy's values first, then each value another copy
///   adds, while within Outlook's room (two work and two home phones,
///   three emails, three IM names); more than fits is a difference.
///   Children and categories have no room: never a difference.
/// - The photo (by its hash): the synced copy takes the others' one photo
///   when it has none; any other photo is a difference.
/// - Any other property with a value on another copy that the synced copy
///   lacks or holds differently: a difference, "Other details", never
///   merged without Ron.
///
/// [keep] is Ron's answer to the differences: [kept]'s id keeps the
/// synced copy's details, another copy's id takes that copy's where it
/// has one (a list whole); the details only some copy has are added
/// either way. The outcome is then same or adds, with no differences, and
/// the [CopiesMerge.fingerprint] that of the differences it settled, so
/// the runner can check they are those Ron saw. An answer naming no copy
/// is no answer. A copy given twice, or [kept] among [others], counts
/// once.
CopiesMerge mergeCopies(
  OutlookCopy kept,
  List<OutlookCopy> others, {
  String? keep,
  required ContactNormaliser norm,
}) {
  final ids = {kept.id};
  final copies = [
    for (final c in others)
      if (ids.add(c.id)) c,
  ];
  final merger = _Merger(kept, copies, norm)..run();
  final chosen = keep == kept.id
      ? kept
      : copies.firstWhereOrNull((c) => c.id == keep);
  return merger.result(chosen);
}

enum _Kind {
  /// Not compared.
  ignored,

  /// A name part: the copies share one full name by construction (copies
  /// of one person), so the synced copy's parts stay.
  namePart,

  /// Text, by its words: case and runs of spaces aside.
  text,

  /// Text, by its words, the longer holding the shorter.
  notes,

  /// A date, by its day.
  birthday,

  /// A phone number, by its number.
  phone,

  /// A list of phone numbers.
  phones,

  /// A list of emails, each by its address.
  emails,

  /// A list of texts.
  texts,

  /// A postal address, by its words.
  address,
}

class _Rule {
  const _Rule(this.kind, [this.label = '', this.room]);

  final _Kind kind;

  /// Its name on the screen.
  final String label;

  /// Outlook's room for a list; null where there is no limit.
  final int? room;
}

/// Every property of a Graph contact (v1.0), with its rule; the details
/// in the order the screen lists them. Any other is "Other details".
final _rules = <String, _Rule>{
  'id': const _Rule(_Kind.ignored),
  'changeKey': const _Rule(_Kind.ignored),
  'createdDateTime': const _Rule(_Kind.ignored),
  'lastModifiedDateTime': const _Rule(_Kind.ignored),
  'parentFolderId': const _Rule(_Kind.ignored),
  'displayName': const _Rule(_Kind.ignored),
  'fileAs': const _Rule(_Kind.ignored),
  'givenName': const _Rule(_Kind.namePart),
  'middleName': const _Rule(_Kind.namePart),
  'surname': const _Rule(_Kind.namePart),
  'generation': const _Rule(_Kind.namePart),
  'nickName': const _Rule(_Kind.text, 'Nickname'),
  'emailAddresses': _Rule(_Kind.emails, 'Emails', ContactField.emails.slots),
  'mobilePhone': const _Rule(_Kind.phone, 'Mobile'),
  'homePhones': _Rule(
    _Kind.phones,
    'Home phones',
    ContactField.homePhones.slots,
  ),
  'businessPhones': _Rule(
    _Kind.phones,
    'Work phones',
    ContactField.workPhones.slots,
  ),
  'homeAddress': const _Rule(_Kind.address, 'Home address'),
  'businessAddress': const _Rule(_Kind.address, 'Work address'),
  'otherAddress': const _Rule(_Kind.address, 'Other address'),
  'companyName': const _Rule(_Kind.text, 'Company'),
  'department': const _Rule(_Kind.text, 'Department'),
  'jobTitle': const _Rule(_Kind.text, 'Job title'),
  'officeLocation': const _Rule(_Kind.text, 'Office'),
  'birthday': const _Rule(_Kind.birthday, 'Birthday'),
  'personalNotes': const _Rule(_Kind.notes, 'Notes'),
  'spouseName': const _Rule(_Kind.text, 'Spouse'),
  'children': const _Rule(_Kind.texts, 'Children'),
  'manager': const _Rule(_Kind.text, 'Manager'),
  'assistantName': const _Rule(_Kind.text, 'Assistant'),
  'businessHomePage': const _Rule(_Kind.text, 'Web page'),
  'imAddresses': _Rule(_Kind.texts, 'IM names', ContactField.im.slots),
  'title': const _Rule(_Kind.text, 'Title'),
  'initials': const _Rule(_Kind.text, 'Initials'),
  'profession': const _Rule(_Kind.text, 'Profession'),
  'yomiGivenName': const _Rule(_Kind.text, 'Phonetic first name'),
  'yomiSurname': const _Rule(_Kind.text, 'Phonetic last name'),
  'yomiCompanyName': const _Rule(_Kind.text, 'Phonetic company'),
  'categories': const _Rule(_Kind.texts, 'Categories'),
};

const _photoLabel = 'Photo';
const _otherLabel = 'Other details';

/// Ways of writing the United States, the longest first: a country
/// dropped, or written another way, is no difference in an address.
const _countryWords = [
  ['the', 'united', 'states', 'of', 'america'],
  ['united', 'states', 'of', 'america'],
  ['the', 'united', 'states'],
  ['united', 'states'],
  ['america'],
  ['usa'],
  ['us'],
  ['u', 's', 'a'],
  ['u', 's'],
];

class _Merger {
  _Merger(this.kept, this.others, this.norm);

  final OutlookCopy kept;
  final List<OutlookCopy> others;
  final ContactNormaliser norm;

  final patch = <String, Object?>{};
  String? photoFrom;
  final adds = <CopiesDetail>[];
  final differences = <CopiesDifference>[];

  /// Each difference in a fixed form, for the fingerprint.
  final fixed = <List<Object?>>[];

  /// What an answer naming a copy does to each difference.
  final answers = <void Function(OutlookCopy chosen)>[];

  void run() {
    for (final MapEntry(key: property, value: rule) in _rules.entries) {
      switch (rule.kind) {
        case _Kind.ignored || _Kind.namePart:
          break;
        case _Kind.text:
          _single<String>(
            property,
            rule,
            read: (v) => ContactNormaliser.textKey(_string(v)),
            shown: (v) => _shown(_string(v)),
          );
        case _Kind.notes:
          _single<String>(
            property,
            rule,
            read: (v) => ContactNormaliser.textKey(_string(v)),
            covers: (a, b) => a.contains(b),
            shown: _shownNotes,
          );
        case _Kind.birthday:
          _single<ContactBirthday>(
            property,
            rule,
            read: (v) => birthdayFromGraph(_string(v)),
            // The same day, with the year if the other has one.
            covers: (a, b) =>
                a.sameDay(b) && (b.year == null || b.year == a.year),
            fixedOf: (b) => b.shown,
            shown: (v) => birthdayFromGraph(_string(v))?.shown,
          );
        case _Kind.phone:
          _single<String>(
            property,
            rule,
            read: (v) => _phoneKey(_string(v)),
            shown: (v) => _shown(_string(v)),
          );
        case _Kind.address:
          _single<String>(
            property,
            rule,
            read: _addressKey,
            shown: _shownAddress,
          );
        case _Kind.phones:
          _list(
            property,
            rule,
            key: (v) => _phoneKey(_string(v)),
            text: (v) => _string(v)?.trim(),
          );
        case _Kind.emails:
          _list(
            property,
            rule,
            key: (v) =>
                ContactNormaliser.emailKey(_string(_map(v)['address'])),
            text: (v) => _string(_map(v)['address'])?.trim(),
          );
        case _Kind.texts:
          _list(
            property,
            rule,
            key: (v) => ContactNormaliser.textKey(_string(v)),
            text: (v) => _string(v)?.trim(),
          );
      }
    }
    _photo();
    _otherDetails();
  }

  CopiesMerge result(OutlookCopy? chosen) {
    final fingerprint = differences.isEmpty ? '' : _fingerprint(fixed);
    if (chosen != null && differences.isNotEmpty) {
      for (final answer in answers) {
        answer(chosen);
      }
      differences.clear();
    }
    return CopiesMerge(
      outcome: differences.isNotEmpty
          ? CopiesOutcome.differs
          : patch.isEmpty && photoFrom == null
          ? CopiesOutcome.same
          : CopiesOutcome.adds,
      patch: Map.unmodifiable(patch),
      photoFrom: photoFrom,
      adds: List.unmodifiable(adds),
      differences: List.unmodifiable(differences),
      fingerprint: fingerprint,
    );
  }

  String? _phoneKey(String? s) =>
      s == null ? null : norm.phoneKey(s) ?? ContactNormaliser.textKey(s);

  void _gains(String property, String label, Object? value, String? shown) {
    patch[property] = value;
    adds.add(CopiesDetail(label: label, value: shown));
  }

  /// A single value, read as [K] to compare: the others' that the synced
  /// copy's [covers] (the same, unless given) change nothing; one that
  /// covers the synced copy's (when it has one) and all the others' is
  /// taken; anything else is a difference.
  void _single<K extends Object>(
    String property,
    _Rule rule, {
    required K? Function(Object?) read,
    bool Function(K a, K b)? covers,
    String Function(K)? fixedOf,
    required String? Function(Object?) shown,
  }) {
    final cover = covers ?? (K a, K b) => a == b;
    final mine = read(kept.json[property]);
    final theirs = [
      for (final c in others)
        if (read(c.json[property]) case final K value)
          if (mine == null || !cover(mine, value)) value,
    ];
    if (theirs.isEmpty) return;
    final taken = others.firstWhereOrNull((c) {
      final value = read(c.json[property]);
      return value != null &&
          (mine == null || cover(value, mine)) &&
          theirs.every((v) => cover(value, v));
    });
    if (taken != null) {
      final value = taken.json[property];
      _gains(property, rule.label, value, shown(value));
      return;
    }
    _differ(
      property,
      rule.label,
      shown: (c) => shown(c.json[property]),
      fixedOf: (c) => switch (read(c.json[property])) {
        null => null,
        final K value => fixedOf?.call(value) ?? '$value',
      },
      answer: (chosen) {
        final value = read(chosen.json[property]);
        if (value == null ||
            (mine != null && cover(mine, value) && cover(value, mine))) {
          return;
        }
        final raw = chosen.json[property];
        _gains(property, rule.label, raw, shown(raw));
      },
    );
  }

  /// A list, its values by [key] (none twice): the synced copy's first,
  /// then each value another copy adds, while within Outlook's room; more
  /// than fits is a difference.
  void _list(
    String property,
    _Rule rule, {
    required String? Function(Object?) key,
    required String? Function(Object?) text,
  }) {
    List<(String, Object?)> items(OutlookCopy c) {
      final seen = <String>{};
      return [
        for (final v in _listOf(c.json[property]))
          if (key(v) case final k? when seen.add(k)) (k, v),
      ];
    }

    String? shown(OutlookCopy c) =>
        _shown([for (final (_, v) in items(c)) ?text(v)].join(', '));

    final mine = items(kept);
    final have = {for (final (k, _) in mine) k};
    final gained = [
      for (final c in others)
        for (final (k, v) in items(c))
          if (have.add(k)) (k, v),
    ];
    if (gained.isEmpty) return;
    final room = rule.room;
    if (room == null || have.length <= room) {
      patch[property] = [for (final (_, v) in [...mine, ...gained]) v];
      for (final (_, v) in gained) {
        adds.add(CopiesDetail(label: rule.label, value: _shown(text(v))));
      }
      return;
    }
    final mineKeys = {for (final (k, _) in mine) k};
    _differ(
      property,
      rule.label,
      shown: shown,
      fixedOf: (c) {
        final keys = [for (final (k, _) in items(c)) k]..sort();
        return keys.isEmpty ? null : keys;
      },
      answer: (chosen) {
        final theirs = items(chosen);
        final keys = {for (final (k, _) in theirs) k};
        if (theirs.isEmpty ||
            const SetEquality<String>().equals(keys, mineKeys)) {
          return;
        }
        patch[property] = [for (final (_, v) in theirs) v];
        for (final (k, v) in theirs) {
          if (mineKeys.contains(k)) continue;
          adds.add(CopiesDetail(label: rule.label, value: _shown(text(v))));
        }
      },
    );
  }

  /// The photo, by its hash: the synced copy takes the others' one photo
  /// when it has none; any other photo is a difference, shown as "a
  /// photo" (the synced copy's, or the first) and "another photo".
  void _photo() {
    final mine = kept.photo;
    final theirs = {
      for (final c in others)
        if (c.photo case final p? when p != mine) p,
    };
    if (theirs.isEmpty) return;
    if (mine == null && theirs.length == 1) {
      photoFrom = others.firstWhere((c) => c.photo == theirs.single).id;
      adds.add(const CopiesDetail(label: _photoLabel, value: 'a photo'));
      return;
    }
    final first = mine ?? theirs.first;
    _differ(
      // Not a property: no Graph property has an `@` in its name.
      '@photo',
      _photoLabel,
      shown: (c) => switch (c.photo) {
        null => null,
        final p when p == first => 'a photo',
        _ => 'another photo',
      },
      fixedOf: (c) => c.photo,
      answer: (chosen) {
        if (chosen.photo == null || chosen.photo == mine) return;
        photoFrom = chosen.id;
        adds.add(const CopiesDetail(label: _photoLabel, value: 'a photo'));
      },
    );
  }

  /// Any property [_rules] does not name, but annotations: a value on
  /// another copy that the synced copy lacks or holds differently is a
  /// difference, never merged without Ron.
  void _otherDetails() {
    final names = {
      for (final c in [kept, ...others])
        for (final name in c.json.keys)
          if (!_rules.containsKey(name) && !name.contains('@')) name,
    }.toList()..sort();
    for (final property in names) {
      String? fixedOf(OutlookCopy c) => _fixedJson(c.json[property]);
      String? shown(OutlookCopy c) => switch (_flat(c.json[property])) {
        null => null,
        final flat => _shown('$property: $flat'),
      };
      final mine = fixedOf(kept);
      if (others.every((c) {
        final theirs = fixedOf(c);
        return theirs == null || theirs == mine;
      })) {
        continue;
      }
      _differ(
        property,
        _otherLabel,
        shown: shown,
        fixedOf: fixedOf,
        answer: (chosen) {
          final theirs = fixedOf(chosen);
          if (theirs == null || theirs == mine) return;
          _gains(property, _otherLabel, chosen.json[property], shown(chosen));
        },
      );
    }
  }

  void _differ(
    String property,
    String label, {
    required String? Function(OutlookCopy) shown,
    required Object? Function(OutlookCopy) fixedOf,
    required void Function(OutlookCopy chosen) answer,
  }) {
    differences.add(
      CopiesDifference(
        label: label,
        kept: shown(kept),
        others: {for (final c in others) c.id: shown(c)},
      ),
    );
    final byId = [...others]..sort((a, b) => a.id.compareTo(b.id));
    fixed.add([
      property,
      [kept.id, fixedOf(kept)],
      for (final c in byId) [c.id, fixedOf(c)],
    ]);
    answers.add(answer);
  }
}

/// The differences' fixed forms, in any order, as a SHA-256 in hex.
String _fingerprint(List<List<Object?>> fixed) {
  final lines = [for (final f in fixed) jsonEncode(f)]..sort();
  final hash = const DartSha256().hashSync(utf8.encode(lines.join('\n')));
  return [
    for (final b in hash.bytes) b.toRadixString(16).padLeft(2, '0'),
  ].join();
}

String? _string(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

List<Object?> _listOf(Object? v) => v is List ? v : const [];

Map<String, Object?> _map(Object? v) => v is Map
    ? {
        for (final e in v.entries)
          if (e.key is String) e.key as String: e.value,
      }
    : const {};

/// [text] as one line, cut to [contactDetailShownLength] with an
/// ellipsis; null when empty.
String? _shown(String? text) {
  if (text == null) return null;
  final line = text.trim().replaceAll(RegExp(r'\s*\r?\n\s*'), ', ');
  if (line.isEmpty) return null;
  if (line.length <= contactDetailShownLength) return line;
  final cut = line.substring(0, contactDetailShownLength - 1);
  return '${cut.trimRight()}\u2026';
}

/// Notes as one line, or "(long note)" for more than a line's worth.
String? _shownNotes(Object? v) {
  final text = _string(v)?.trim();
  if (text == null) return null;
  if (text.contains('\n') || text.length > contactDetailShownLength) {
    return '(long note)';
  }
  return text;
}

ContactAddress? _address(Object? v) {
  final a = _map(v);
  return ContactAddress.of(
    street: _string(a['street']),
    city: _string(a['city']),
    region: _string(a['state']),
    postalCode: _string(a['postalCode']),
    country: _string(a['countryOrRegion']),
  );
}

String? _shownAddress(Object? v) => _shown(_address(v)?.shown);

/// An address's words, in order: case, punctuation, line breaks and the
/// United States however written aside. Null when it has none.
String? _addressKey(Object? v) {
  final a = _address(v);
  if (a == null) return null;
  final words = [
    for (final part in [a.street, a.city, a.region, a.postalCode, a.country])
      if (part != null)
        ...part
            .toLowerCase()
            .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
            .where((w) => w.isNotEmpty),
  ];
  final kept = <String>[];
  for (var i = 0; i < words.length;) {
    final country = _countryWords.firstWhereOrNull(
      (c) =>
          i + c.length <= words.length &&
          const ListEquality<String>().equals(
            words.sublist(i, i + c.length),
            c,
          ),
    );
    if (country != null) {
      i += country.length;
      continue;
    }
    kept.add(words[i]);
    i++;
  }
  return kept.isEmpty ? null : kept.join(' ');
}

/// A value Graph gave, in a fixed form: a map's keys in order, empty
/// parts left out. Null when it holds nothing.
String? _fixedJson(Object? v) {
  final value = _fixedValue(v);
  return value == null ? null : jsonEncode(value);
}

Object? _fixedValue(Object? v) {
  if (v is String) return v.trim().isEmpty ? null : v;
  if (v is List) {
    final items = [for (final e in v) _fixedValue(e)];
    return items.every((e) => e == null) ? null : items;
  }
  if (v is Map) {
    final keys = [for (final k in v.keys) '$k']..sort();
    final entries = {for (final k in keys) k: ?_fixedValue(v[k])};
    return entries.isEmpty ? null : entries;
  }
  return v;
}

/// A value Graph gave as one line of its words: a list's parts, or a
/// map's by their keys, joined with ", ". Null when it holds nothing.
String? _flat(Object? v) {
  final parts = switch (v) {
    null => const <String>[],
    final String s => [s.trim()],
    final List l => [for (final e in l) ?_flat(e)],
    final Map m => [
      for (final k in [for (final k in m.keys) '$k']..sort()) ?_flat(m[k]),
    ],
    _ => ['$v'],
  }.where((p) => p.isNotEmpty);
  return parts.isEmpty ? null : parts.join(', ');
}
