import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:cryptography/dart.dart' show DartSha256;
import 'package:flutter/foundation.dart' show immutable;

import '../../domain/synced_contact.dart';
import 'contact_mapping.dart' show birthdayFromGraph;
import 'contact_sync_planner.dart' show contactDetailShownLength;
import 'outlook_only_details.dart';

// The merge of the copies of one person in Hadco's Contacts into the
// synced one (3.22.0): pure rules, no reads and no writes. Hadco holds
// copies of many people from before the first sync, which Outlook cannot
// merge in bulk. The runner reads each copy whole and notes which have a
// photo; [mergeCopies] says what the synced copy would gain (a PATCH body
// and a photo), and, where the copies differ, what for Ron to choose. The
// synced
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
  /// `$select`, with the details only Outlook keeps among its
  /// `singleValueExtendedProperties` ([outlookOnlyDetails]).
  final Map<String, Object?> json;

  /// Whether it has a photo: any value says it has one, null that it has
  /// none. The photo itself is never compared (3.22.1): nearly every
  /// contact in Hadco has one, and no two copies' bytes are alike.
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
  /// "(long note)"; a photo "a photo".
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
  /// each property it gains or takes, collections and addresses whole, and
  /// the details only Outlook keeps as `singleValueExtendedProperties`,
  /// which Graph's answer to it never shows. Empty when it gains nothing.
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
/// A copy not joined to the synced one by an email or a mobile, directly
/// or through another copy that is, is never merged: two people of one
/// name may be. The person then differs ("Same name only"), whatever
/// [keep] says, with nothing to write.
///
/// Per Graph contact property (v1.0), as `_rules` lists them:
/// - Not compared: ids, times, the folder, the names Outlook makes
///   (`displayName`, `fileAs`), each email's own name, annotations
///   (`@odata.*`), and the name parts, which copies of one person share
///   by construction: the synced copy's stay.
/// - A single value (text, by its words, case and spaces aside; notes by
///   their words, the longer holding the shorter as a whole sentence or
///   line, or a run of them; a phone by its number; an address by its
///   words, punctuation and line breaks aside, and the United States in
///   the country or as the last words; a birthday by its day): the
///   others' that the synced copy's covers change nothing; with one
///   value that covers the synced copy's and all the others' (the
///   synced copy having none; for notes, the longer holding the others;
///   for a birthday, its year) the synced copy takes it; anything else
///   is a difference. A mobile or a birthday it would take from copies
///   sharing no mobile with another copy (joined only by an email, as a
///   family's copies may be) is a difference too.
/// - A list: the synced copy's values first, then each value another copy
///   adds, while within Outlook's room (two work and two home phones,
///   three emails, three IM names); more than fits is a difference.
///   Children and categories have no room: never a difference. A whole
///   read repeats the first three emails in three slots
///   (`primaryEmailAddress` and on): their addresses are the copy's
///   emails too, and they are never written.
/// - The photo is never a difference (3.22.1, Ron's choice): the synced
///   copy's photo, where it has one, stays, and the others' go with their
///   copies; where it has none, it takes the photo of the first other copy
///   that has one, in id order ([CopiesMerge.photoFrom], an add, "Photo").
///   An answer does not touch the photo, but where [keepsPhoto] says the
///   photo was among the differences Ron saw.
/// - The details only Outlook keeps ([outlookOnlyDetails]: the faxes, the
///   pager and the other phones, the PO boxes, the ID and user fields, the
///   anniversary), which a whole read brings among its extended
///   properties: each a single value, as above, a number by its number, a
///   text by its words, the anniversary by its day and as a birthday is
///   taken. One the synced copy takes is written as Graph takes it, an
///   extended property by its id. What no read brings (files attached to
///   a contact, gender, billing, mileage) the rules cannot see: a copy
///   holding only such goes as the same.
/// - Any other property with a value on another copy that the synced copy
///   lacks or holds differently (another extended property among them): a
///   difference, "Other details", never merged without Ron.
/// - A value a rule cannot read (text that is not text, a date that is
///   not one, an email that is not Graph's shape) is a difference, unless
///   it is the synced copy's own again: never dropped.
///
/// [keep] is Ron's answer to the differences: [kept]'s id keeps the
/// synced copy's details, another copy's id takes that copy's where it
/// has one; a list takes the chosen copy's values first, then the synced
/// copy's, then the others', while within the room. With [keepsPhoto]
/// (an answer given on a listing 3.22.0 made, where the photo was among
/// the differences shown), another copy's id also takes that copy's
/// photo, when it has one, in place of the synced copy's, whether or not
/// anything else differs now; without, an answer never touches the photo,
/// and the synced copy's own stays, never written over unasked. The
/// details only some copy has are added either way. The outcome is then same or adds, with
/// no differences, and the [CopiesMerge.fingerprint] that of the
/// differences it settled, so the runner can check they are those Ron
/// saw. An answer naming no copy is no answer. A copy given twice, or
/// [kept] among [others], counts once. The other copies are taken by id,
/// never as given: which of them fills a list's room, or gives a value
/// they hold alike in other forms.
CopiesMerge mergeCopies(
  OutlookCopy kept,
  List<OutlookCopy> others, {
  String? keep,
  bool keepsPhoto = false,
  required ContactNormaliser norm,
}) {
  final ids = {kept.id};
  final copies = [
    for (final c in others)
      if (ids.add(c.id)) _lifted(c),
  ];
  final merger = _Merger(_lifted(kept), copies, norm)..run();
  final chosen = keep == kept.id
      ? merger.kept
      : copies.firstWhereOrNull((c) => c.id == keep);
  return merger.result(chosen, keepsPhoto: keepsPhoto);
}

/// [c] with each detail only Outlook keeps that it was read with (among
/// its `singleValueExtendedProperties`) as a property of its own, named by
/// the detail's id, which [_rules] knows; any other extended property
/// stays in the list, for "Other details". Exchange keeps a property once
/// on a contact.
OutlookCopy _lifted(OutlookCopy c) {
  final props = c.json['singleValueExtendedProperties'];
  if (props is! List) return c;
  final json = {...c.json}..remove('singleValueExtendedProperties');
  final rest = <Object?>[];
  for (final p in props) {
    final detail = p is Map ? outlookOnlyDetailOf(p['id']) : null;
    if (detail == null) {
      rest.add(p);
    } else {
      json[detail.id] = (p as Map)['value'];
    }
  }
  if (rest.isNotEmpty) json['singleValueExtendedProperties'] = rest;
  return OutlookCopy(id: c.id, json: json, photo: c.photo);
}

enum _Kind {
  /// Not compared.
  ignored,

  /// A name part: the copies share one full name by construction (copies
  /// of one person), so the synced copy's parts stay.
  namePart,

  /// One of the slots a whole read repeats the first three emails in:
  /// read with the emails, never written.
  emailSlot,

  /// Text, by its words: case and runs of spaces aside.
  text,

  /// Text by its words, the longer holding the shorter.
  notes,

  /// A date, by its day.
  birthday,

  /// A phone number, by its number.
  phone,

  /// A number only Outlook keeps (a fax, the pager), by its number: unlike
  /// the mobile, never one a family's copies may share.
  number,

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

/// Every property of a Graph contact (v1.0), with its rule, then each
/// detail only Outlook keeps, by its id ([_lifted]); the details in the
/// order the screen lists them. Any other is "Other details".
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
  for (final slot in _emailSlots) slot: const _Rule(_Kind.emailSlot),
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
  for (final d in outlookOnlyDetails)
    d.id: _Rule(switch (d.kind) {
      OutlookOnlyKind.number => _Kind.number,
      OutlookOnlyKind.text => _Kind.text,
      // A date of the person's own, as the birthday.
      OutlookOnlyKind.date => _Kind.birthday,
    }, d.label),
};

/// The ids of the details only Outlook keeps, as [_lifted] names them.
final _outlookOnly = {for (final d in outlookOnlyDetails) d.id};

/// The slots a whole read repeats the first three emails in, each an
/// email (a name and an address) or nothing.
const _emailSlots = [
  'primaryEmailAddress',
  'secondaryEmailAddress',
  'tertiaryEmailAddress',
];

/// Where a copy's emails are read from: the list, then the slots.
const _emailsFrom = ['emailAddresses', ..._emailSlots];

/// The parts of an address Graph writes.
const _addressParts = {
  'street',
  'city',
  'state',
  'postalCode',
  'countryOrRegion',
};

const _photoLabel = 'Photo';
const _otherLabel = 'Other details';
const _joinLabel = 'Same name only';
const _notJoined = 'no email or mobile in common';

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

/// A copy's value for one property as a rule reads it: its [value], or,
/// when it has one that the rule cannot read, [odd]. Neither: none.
class _Cell<K extends Object> {
  const _Cell(this.raw, this.value, {this.odd = false});

  final Object? raw;
  final K? value;
  final bool odd;

  bool get none => value == null && !odd;
}

/// A copy's list as a rule reads it: its values by their keys, none
/// twice, and those it cannot read ([odd]).
class _Items {
  _Items(this.raw);

  /// The properties it was read from, as they were.
  final Object? raw;
  final items = <(String, Object?)>[];
  final odd = <Object?>[];

  bool get none => items.isEmpty && odd.isEmpty;
  List<String> get keys => [for (final (k, _) in items) k];
}

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

  /// A copy is not joined to the synced one: nothing is merged.
  var unjoined = false;

  /// The other copies by id: where a value comes from, or which fill a
  /// list's room, never hangs on the order they were given in.
  late final List<OutlookCopy> _byId = [...others]
    ..sort((a, b) => a.id.compareTo(b.id));

  List<OutlookCopy> get _all => [kept, ...others];

  /// Each copy's mobile, by its number; null for none.
  late final Map<String, String?> _mobiles = {
    for (final c in _all)
      c.id: _cell<String>(c.json['mobilePhone'], _mobileKey).value,
  };

  void run() {
    _joined();
    for (final MapEntry(key: property, value: rule) in _rules.entries) {
      switch (rule.kind) {
        case _Kind.ignored || _Kind.namePart || _Kind.emailSlot:
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
            read: _notesKey,
            covers: _notesCover,
            fixedOf: (k) => k.replaceAll('\n', ' '),
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
            sharedMobile: true,
          );
        case _Kind.phone:
          _single<String>(
            property,
            rule,
            read: _mobileKey,
            shown: (v) => _shown(_string(v)),
            sharedMobile: true,
          );
        case _Kind.number:
          _single<String>(
            property,
            rule,
            read: _mobileKey,
            shown: (v) => _shown(_string(v)),
          );
        case _Kind.address:
          _single<String>(
            property,
            rule,
            read: (v) => switch (_readAddress(v)) {
              null => null,
              final address => _addressKey(address),
            },
            // An address of no words but the country's holds nothing.
            covers: (a, b) => a == b || b.isEmpty,
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
            from: _emailsFrom,
            key: _emailKey,
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

  CopiesMerge result(OutlookCopy? chosen, {bool keepsPhoto = false}) {
    final fingerprint = differences.isEmpty ? '' : _fingerprint(fixed);
    // With a copy not joined, the person differs whatever the answer, and
    // nothing is written: an answer cannot say two people are one.
    if (unjoined) {
      return CopiesMerge(
        outcome: CopiesOutcome.differs,
        differences: List.unmodifiable(differences),
        fingerprint: fingerprint,
      );
    }
    if (chosen != null && differences.isNotEmpty) {
      for (final answer in answers) {
        answer(chosen);
      }
      differences.clear();
    }
    // Keep these on another copy, where the photo was among the
    // differences Ron saw, brings its photo, when it has one, in place of
    // the synced copy's: whether or not anything else differs now.
    if (keepsPhoto &&
        chosen != null &&
        chosen.id != kept.id &&
        chosen.photo != null &&
        photoFrom != chosen.id) {
      if (photoFrom == null) {
        adds.add(const CopiesDetail(label: _photoLabel, value: 'a photo'));
      }
      photoFrom = chosen.id;
    }
    // The details only Outlook keeps go as Graph takes them: extended
    // properties, by their ids.
    final body = <String, Object?>{};
    final extended = <Map<String, Object?>>[];
    for (final MapEntry(:key, :value) in patch.entries) {
      if (_outlookOnly.contains(key)) {
        extended.add({'id': key, 'value': value});
      } else {
        body[key] = value;
      }
    }
    if (extended.isNotEmpty) body['singleValueExtendedProperties'] = extended;
    return CopiesMerge(
      outcome: differences.isNotEmpty
          ? CopiesOutcome.differs
          : body.isEmpty && photoFrom == null
          ? CopiesOutcome.same
          : CopiesOutcome.adds,
      patch: Map.unmodifiable(body),
      photoFrom: photoFrom,
      adds: List.unmodifiable(adds),
      differences: List.unmodifiable(differences),
      fingerprint: fingerprint,
    );
  }

  String? _phoneKey(String? s) =>
      s == null ? null : norm.phoneKey(s) ?? ContactNormaliser.textKey(s);

  String? _mobileKey(Object? v) => _phoneKey(_string(v));

  /// Whether [c]'s mobile is another copy's too.
  bool _sharesMobile(OutlookCopy c) {
    final mobile = _mobiles[c.id];
    return mobile != null &&
        _all.any((o) => o.id != c.id && _mobiles[o.id] == mobile);
  }

  void _gains(String property, String label, Object? value, String? shown) {
    patch[property] = value;
    adds.add(CopiesDetail(label: label, value: shown));
  }

  /// The copies joined to the synced one by an email or a mobile, directly
  /// or through another copy that is. With any other, however alike, the
  /// person is never merged, whatever the answer ([unjoined]): a
  /// difference, "Same name only".
  void _joined() {
    Set<String> keys(OutlookCopy c) => {
      for (final k in _itemsOf(c, _emailsFrom, _emailKey).keys) 'email $k',
      if (_mobiles[c.id] case final mobile?) 'mobile $mobile',
    };

    final joined = {kept.id};
    final reached = keys(kept);
    for (var grew = true; grew;) {
      grew = false;
      for (final c in others) {
        if (joined.contains(c.id)) continue;
        final theirs = keys(c);
        if (!theirs.any(reached.contains)) continue;
        joined.add(c.id);
        reached.addAll(theirs);
        grew = true;
      }
    }
    if (others.every((c) => joined.contains(c.id))) return;
    unjoined = true;
    String? shown(OutlookCopy c) => joined.contains(c.id) ? null : _notJoined;
    _differ(
      '@joined',
      _joinLabel,
      shown: shown,
      fixedOf: shown,
      answer: (_) {},
    );
  }

  /// A single value, read as [K] to compare: the others' that the synced
  /// copy's [covers] (the same, unless given) change nothing; one that
  /// covers the synced copy's (when it has one) and all the others' is
  /// taken, but, with [sharedMobile], only from a copy whose mobile
  /// another copy has too; anything else is a difference, as is a value
  /// [read] cannot read that is not the synced copy's own again.
  void _single<K extends Object>(
    String property,
    _Rule rule, {
    required K? Function(Object?) read,
    bool Function(K a, K b)? covers,
    String Function(K)? fixedOf,
    required String? Function(Object?) shown,
    bool sharedMobile = false,
  }) {
    final cover = covers ?? (K a, K b) => a == b;
    bool same(K a, K b) => cover(a, b) && cover(b, a);
    final mine = _cell(kept.json[property], read);
    final cells = {
      for (final c in others) c.id: _cell(c.json[property], read),
    };
    _Cell<K> cellOf(OutlookCopy c) => c.id == kept.id ? mine : cells[c.id]!;
    String? shownOf(_Cell<K> cell) =>
        cell.odd ? _shown(_flat(cell.raw)) : shown(cell.raw);

    void differ() => _differ(
      property,
      rule.label,
      shown: (c) => shownOf(cellOf(c)),
      fixedOf: (c) {
        final cell = cellOf(c);
        if (cell.none) return null;
        if (cell.odd) return '? ${_fixedJson(cell.raw)}';
        return fixedOf?.call(cell.value!) ?? '${cell.value}';
      },
      answer: (chosen) {
        final cell = cellOf(chosen);
        if (chosen.id == kept.id || cell.none) return;
        if (cell.odd) {
          if (_fixedJson(cell.raw) == _fixedJson(mine.raw)) return;
        } else if (mine.value case final m? when same(m, cell.value!)) {
          return;
        }
        _gains(property, rule.label, cell.raw, shownOf(cell));
      },
    );

    // What the rule cannot read, but the synced copy's own again.
    if (others.any((c) {
      final cell = cells[c.id]!;
      if (cell.odd) return _fixedJson(cell.raw) != _fixedJson(mine.raw);
      return mine.odd && cell.value != null;
    })) {
      differ();
      return;
    }
    final m = mine.value;
    final theirs = [
      for (final c in others)
        if (cells[c.id]!.value case final v?)
          if (m == null || !cover(m, v)) v,
    ];
    if (theirs.isEmpty) return;
    final taken = _byId.firstWhereOrNull((c) {
      final v = cells[c.id]!.value;
      return v != null &&
          (m == null || cover(v, m)) &&
          theirs.every((t) => cover(v, t));
    });
    if (taken != null) {
      final value = cells[taken.id]!.value!;
      final from = [
        for (final c in others)
          if (cells[c.id]!.value case final v? when same(v, value)) c,
      ];
      if (!sharedMobile || from.any(_sharesMobile)) {
        final raw = taken.json[property];
        _gains(property, rule.label, raw, shown(raw));
        return;
      }
    }
    differ();
  }

  /// A list, its values by [key] (none twice), read [from] its property
  /// (and, for emails, their slots): the synced copy's first, then each
  /// value another copy adds, while within Outlook's room; more than fits
  /// is a difference, as is a value [key] cannot read that is not the
  /// synced copy's own again.
  void _list(
    String property,
    _Rule rule, {
    List<String>? from,
    required String? Function(Object?) key,
    required String? Function(Object?) text,
  }) {
    final read = from ?? [property];
    final mine = _itemsOf(kept, read, key);
    final cells = {for (final c in others) c.id: _itemsOf(c, read, key)};
    _Items itemsOf(OutlookCopy c) => c.id == kept.id ? mine : cells[c.id]!;
    String? shown(_Items i) => _shown(
      [for (final (_, v) in i.items) ?text(v), for (final v in i.odd) ?_flat(v)]
          .join(', '),
    );
    final mineKeys = mine.keys.toSet();
    final room = rule.room;

    final odd = others.any((c) {
      final i = cells[c.id]!;
      if (i.odd.isNotEmpty) return _fixedJson(i.raw) != _fixedJson(mine.raw);
      return mine.odd.isNotEmpty && i.keys.any((k) => !mineKeys.contains(k));
    });
    final have = {...mineKeys};
    final gained = [
      for (final c in _byId)
        for (final (k, v) in cells[c.id]!.items)
          if (have.add(k)) (k, v),
    ];
    if (!odd) {
      if (gained.isEmpty) return;
      if (room == null || have.length <= room) {
        patch[property] = [for (final (_, v) in [...mine.items, ...gained]) v];
        for (final (_, v) in gained) {
          adds.add(CopiesDetail(label: rule.label, value: _shown(text(v))));
        }
        return;
      }
    }
    _differ(
      property,
      rule.label,
      shown: (c) => shown(itemsOf(c)),
      fixedOf: (c) {
        final i = itemsOf(c);
        if (i.none) return null;
        return [
          ...i.keys..sort(),
          if (i.odd.isNotEmpty) '? ${_fixedJson(i.odd)}',
        ];
      },
      answer: (chosen) {
        final i = itemsOf(chosen);
        if (i.odd.isNotEmpty) {
          // The chosen copy's list as it is.
          if (chosen.id != kept.id &&
              _fixedJson(i.raw) != _fixedJson(mine.raw)) {
            _gains(property, rule.label, chosen.json[property], shown(i));
          }
          return;
        }
        // Written, the synced copy's own odd values would go.
        if (chosen.id == kept.id && mine.odd.isNotEmpty) return;
        // The chosen copy's values first, then the synced copy's, then the
        // others', while within the room.
        final seen = <String>{};
        final merged = [
          for (final c in [chosen, kept, ..._byId])
            for (final (k, v) in itemsOf(c).items)
              if (seen.add(k)) (k, v),
        ];
        final fits = room == null || merged.length <= room
            ? merged
            : merged.sublist(0, room);
        if (mine.odd.isEmpty &&
            const ListEquality<String>().equals(
              [for (final (k, _) in fits) k],
              mine.keys,
            )) {
          return;
        }
        patch[property] = [for (final (_, v) in fits) v];
        for (final (k, v) in fits) {
          if (mineKeys.contains(k)) continue;
          adds.add(CopiesDetail(label: rule.label, value: _shown(text(v))));
        }
      },
    );
  }

  /// The photo, never a difference: the synced copy's stays where it has
  /// one; where it has none, it takes the first other copy's, in id order,
  /// that has one. An answer naming another copy with a photo takes that
  /// one instead, but only where the photo was among the differences Ron
  /// saw ([result]'s keepsPhoto).
  void _photo() {
    if (kept.photo != null) return;
    final from = _byId.firstWhereOrNull((c) => c.photo != null);
    if (from == null) return;
    photoFrom = from.id;
    adds.add(const CopiesDetail(label: _photoLabel, value: 'a photo'));
  }

  /// Any property [_rules] does not name, but annotations: a value on
  /// another copy that the synced copy lacks or holds differently is a
  /// difference, never merged without Ron.
  void _otherDetails() {
    final names = {
      for (final c in _all)
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
    fixed.add([
      property,
      [kept.id, fixedOf(kept)],
      for (final c in _byId) [c.id, fixedOf(c)],
    ]);
    answers.add(answer);
  }
}

/// [raw] as [read] reads it, unless it holds nothing.
_Cell<K> _cell<K extends Object>(Object? raw, K? Function(Object?) read) {
  if (!_present(raw)) return _Cell<K>(raw, null);
  final value = read(raw);
  return _Cell<K>(raw, value, odd: value == null);
}

/// [c]'s list in [from] (the list's property, then, for emails, their
/// slots, each holding one), its values by [key].
_Items _itemsOf(
  OutlookCopy c,
  List<String> from,
  String? Function(Object?) key,
) {
  final items = _Items([for (final p in from) c.json[p]]);
  final seen = <String>{};
  for (final (i, property) in from.indexed) {
    final raw = c.json[property];
    if (!_present(raw)) continue;
    final values = i > 0 ? [raw] : raw is List ? raw : null;
    if (values == null) {
      items.odd.add(raw);
      continue;
    }
    for (final v in values) {
      if (!_present(v)) continue;
      final k = key(v);
      if (k == null) {
        items.odd.add(v);
      } else if (seen.add(k)) {
        items.items.add((k, v));
      }
    }
  }
  return items;
}

/// An email as Graph writes one, a map of a name and an address, by its
/// address in lower case; null for anything else.
String? _emailKey(Object? v) {
  if (v is! Map) return null;
  for (final MapEntry(:key, :value) in v.entries) {
    if ('$key'.contains('@')) continue;
    if (key == 'name' || key == 'address') {
      if (value != null && value is! String) return null;
    } else if (_present(value)) {
      return null;
    }
  }
  return ContactNormaliser.emailKey(_string(v['address']));
}

/// An address as Graph writes one; null for anything else (a part that
/// is not text, or one Graph does not have).
ContactAddress? _readAddress(Object? v) {
  if (v is! Map) return null;
  for (final MapEntry(:key, :value) in v.entries) {
    if ('$key'.contains('@')) continue;
    if (_addressParts.contains(key)) {
      if (value != null && value is! String) return null;
    } else if (_present(value)) {
      return null;
    }
  }
  return _address(v);
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

Map<String, Object?> _map(Object? v) => v is Map
    ? {
        for (final e in v.entries)
          if (e.key is String) e.key as String: e.value,
      }
    : const {};

/// Whether [v] holds anything: not null, blank text, or an empty list or
/// map (annotations aside).
bool _present(Object? v) => _fixedValue(v) != null;

/// [text]'s words: in lower case, split at anything but letters and
/// digits.
List<String> _words(String? text) => text == null
    ? const []
    : text
          .toLowerCase()
          .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
          .where((w) => w.isNotEmpty)
          .toList();

/// Notes as their sentences and lines, each by its words, one a line;
/// with no word in them, as they are.
String? _notesKey(Object? v) {
  final text = _string(v)?.trim();
  if (text == null) return null;
  final sentences = [
    for (final sentence in text.split(RegExp(r'[.!?]+(?=\s|$)|\r?\n')))
      if (_words(sentence) case final words when words.isNotEmpty)
        words.join(' '),
  ];
  return sentences.isEmpty ? text : sentences.join('\n');
}

/// Whether the notes [a] hold the notes [b] (as [_notesKey] gives them):
/// [b]'s words those of a whole sentence or line of [a], or of a run of
/// them, so that "Likes golf" is held in "Met at the fair. Likes golf.",
/// but "VIP" is not in "Not a VIP".
bool _notesCover(String a, String b) {
  final words = b.replaceAll('\n', ' ');
  final sentences = a.split('\n');
  for (var i = 0; i < sentences.length; i++) {
    var run = '';
    for (var j = i; j < sentences.length; j++) {
      run = j == i ? sentences[j] : '$run ${sentences[j]}';
      if (run.length > words.length) break;
      if (run == words) return true;
    }
  }
  return false;
}

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

/// An address's words, in order: case, punctuation and line breaks
/// aside, and the United States however written, in the country or as
/// the last words. Empty when only the country is left.
String _addressKey(ContactAddress a) {
  final words = [
    for (final part in [a.street, a.city, a.region, a.postalCode])
      ..._words(part),
  ];
  for (var last = _countryAtEnd(words); last > 0; last = _countryAtEnd(words)) {
    words.removeRange(words.length - last, words.length);
  }
  final country = _words(a.country);
  final rest = <String>[];
  for (var i = 0; i < country.length;) {
    final written = _countryWords.firstWhereOrNull(
      (c) => _wordsAt(country, i, c),
    );
    if (written != null) {
      i += written.length;
    } else {
      rest.add(country[i++]);
    }
  }
  return [...words, ...rest].join(' ');
}

/// How many of [words]' last words write the United States; 0 for none.
int _countryAtEnd(List<String> words) =>
    _countryWords
        .firstWhereOrNull(
          (c) =>
              c.length <= words.length &&
              _wordsAt(words, words.length - c.length, c),
        )
        ?.length ??
    0;

/// Whether [words] hold [run] from [at].
bool _wordsAt(List<String> words, int at, List<String> run) =>
    at + run.length <= words.length &&
    const ListEquality<String>().equals(
      words.sublist(at, at + run.length),
      run,
    );

/// A value Graph gave, in a fixed form: a map's keys in order, empty
/// parts and annotations left out. Null when it holds nothing.
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
    final keys = [
      for (final k in v.keys)
        if (!'$k'.contains('@')) '$k',
    ]..sort();
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
