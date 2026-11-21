import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../domain/synced_contact.dart';

// How a contact's synced details are read from, and written into, Gmail's
// contacts (a People API Person) and a Microsoft 365 contact (a Graph
// contact), as the contact sync plan's "What is copied" sets out. Pure:
// raw JSON maps in, raw JSON maps out. The wire clients send them.

/// The Person fields every People API call of the sync asks for, as
/// `personFields` (or `readMask`), with `sources=READ_SOURCE_TYPE_CONTACT`.
/// A change to the list changes [googleContactFieldsVersion], and a
/// stored sync token of another version is not used.
const googleContactFields =
    'names,nicknames,emailAddresses,phoneNumbers,addresses,organizations,'
    'birthdays,biographies,relations,urls,imClients,memberships,clientData,'
    'metadata';
const googleContactFieldsVersion = 1;

/// The Graph contact properties the sync asks for with `$select`, and
/// their version, kept with the delta link.
const graphContactSelect =
    'id,changeKey,lastModifiedDateTime,parentFolderId,displayName,'
    'givenName,middleName,surname,title,generation,yomiGivenName,yomiSurname,'
    'nickName,emailAddresses,mobilePhone,homePhones,businessPhones,'
    'homeAddress,businessAddress,otherAddress,companyName,department,'
    'jobTitle,officeLocation,birthday,personalNotes,spouseName,children,'
    'manager,assistantName,businessHomePage,imAddresses';
const graphContactSelectVersion = 1;

/// The `clientData` key of the hidden tag on a Gmail contact the sync
/// made: the id of the Outlook contact it copies.
const googleLinkKey = 'myemail.link';

/// MyEmail's own property set, for the extended properties it keeps on
/// Outlook contacts and the Contacts folder. Fixed for ever: each named
/// property uses up a slot in the mailbox, so the names below never
/// change either.
const myEmailPropertySet = '{958f81ac-dee9-4f9e-a713-9043484f5b0f}';

/// The hidden tag on an Outlook contact the sync made: the resource name
/// of the Gmail contact it copies.
const graphLinkPropertyId = 'String $myEmailPropertySet Name MyEmailLink';

/// The device claim, on the Contacts folder.
const graphDevicePropertyId =
    'String $myEmailPropertySet Name MyEmailSyncDevice';

/// The label every contact the sync makes in Gmail goes into.
const googleMyContacts = 'contactGroups/myContacts';

// ---------------------------------------------------------------------------
// Reading.

/// A Gmail contact as a listing returned it.
@immutable
class GoogleContact {
  const GoogleContact({
    required this.resourceName,
    required this.details,
    this.etag,
    this.updatedAt,
    this.tag,
    this.deleted = false,
    this.previousNames = const [],
    this.person = const {},
  });

  /// Its `people/c…` name.
  final String resourceName;

  /// Its version: the etag of the contact's own source
  /// ([googleContactEtag]), which `updateContact` checks and which every
  /// stored Gmail version is. Not the Person's top-level etag, which is
  /// the HTTP entity tag of one answer and changes with the fields asked
  /// for. Null when the read carried no contact source.
  final String? etag;

  /// The contact source's `updateTime`: when it was last changed.
  final DateTime? updatedAt;

  /// The hidden tag: the Outlook contact the sync copied it from.
  final String? tag;

  /// A sync-token listing's `metadata.deleted`.
  final bool deleted;

  /// `metadata.previousResourceNames`: names it had before Google re-keyed
  /// it, or before Ron merged contacts into it.
  final List<String> previousNames;

  final SyncedContact details;

  /// The Person as read, which a write rebuilds.
  final Map<String, Object?> person;

  factory GoogleContact.fromPerson(Map<String, Object?> person) {
    final metadata = _map(person['metadata']);
    final source = _contactSource(person);
    return GoogleContact(
      resourceName: _string(person['resourceName']) ?? '',
      etag: _string(source?['etag']),
      updatedAt: DateTime.tryParse(_string(source?['updateTime']) ?? ''),
      tag: googleTag(person),
      deleted: metadata['deleted'] == true,
      previousNames: _list(
        metadata['previousResourceNames'],
      ).whereType<String>().toList(),
      details: syncedFromPerson(person),
      person: person,
    );
  }
}

/// An Outlook contact as a listing returned it.
@immutable
class GraphContact {
  const GraphContact({
    required this.id,
    required this.details,
    this.changeKey,
    this.updatedAt,
    this.folderId,
    this.tag,
    this.json = const {},
    this.removed = false,
    this.missing = const {},
  });

  /// Its immutable id.
  final String id;

  /// A delta's `@removed` entry: only a reason to look the contact up.
  final bool removed;

  /// Synced properties ([graphSyncedProperties]) the read left out. A
  /// delta item can be sparse, and a property it leaves out is not one
  /// that was cleared: such an item is read whole by id before it is
  /// used, and the planner passes over any that still lacks one.
  final Set<String> missing;

  /// Every synced property was in the read.
  bool get readWhole => missing.isEmpty;
  final String? changeKey;

  /// `lastModifiedDateTime`.
  final DateTime? updatedAt;

  /// `parentFolderId`.
  final String? folderId;

  /// The hidden tag: the Gmail contact the sync copied it from. Graph
  /// returns it only to a request that expands it.
  final String? tag;

  final SyncedContact details;

  /// The contact as read, which a `PATCH` reads its display name from.
  final Map<String, Object?> json;

  factory GraphContact.fromJson(Map<String, Object?> json) => GraphContact(
    id: _string(json['id']) ?? '',
    changeKey: _string(json['changeKey']),
    updatedAt: DateTime.tryParse(_string(json['lastModifiedDateTime']) ?? ''),
    folderId: _string(json['parentFolderId']),
    tag: graphTag(json),
    details: syncedFromGraph(json),
    json: json,
    removed: json.containsKey('@removed'),
    missing: {
      for (final p in graphSyncedProperties)
        if (!json.containsKey(p)) p,
    },
  );
}

/// The properties of [graphContactSelect] that hold synced details: a
/// read that lacks one is not a read of the whole contact.
final graphSyncedProperties = [
  'displayName',
  for (final f in ContactField.values) ...graphProperties(f),
];

/// A Person's version: the etag of its contact source
/// (`metadata.sources[]` of type CONTACT). `updateContact` compares it
/// with the contact's own and answers 400 failedPrecondition when they
/// differ; it is what [GoogleContact.etag], the rows, a write's
/// `version` and a delete's `expectedVersion` hold, so the full read
/// before a delete is compared with the listing on the same terms. Null
/// when the Person carries no contact source.
String? googleContactEtag(Map<String, Object?> person) =>
    _string(_contactSource(person)?['etag']);

Map<String, Object?>? _contactSource(Map<String, Object?> person) =>
    _list(_map(person['metadata'])['sources'])
        .map(_map)
        .firstWhereOrNull((s) => s['type'] == 'CONTACT');

/// The hidden tag in a Person's `clientData`, if it has one.
String? googleTag(Map<String, Object?> person) => _contactEntries(
  person,
  'clientData',
).firstWhereOrNull((e) => e['key'] == googleLinkKey)?['value'] as String?;

/// The hidden tag in an expanded Graph contact, if it has one.
String? graphTag(Map<String, Object?> contact) =>
    _list(contact['singleValueExtendedProperties'])
            .map(_map)
            .firstWhereOrNull(
              (p) =>
                  (_string(p['id']) ?? '').toLowerCase() ==
                  graphLinkPropertyId.toLowerCase(),
            )?['value']
        as String?;

/// A Person's synced details. Only entries from the contact itself count
/// (`metadata.source.type` CONTACT, or no source at all, as a hand-built
/// Person has): Google-profile data cannot be written back, and would look
/// like changes.
SyncedContact syncedFromPerson(Map<String, Object?> person) {
  final names = _contactEntries(person, 'names');
  final name = names.firstOrNull;
  final phones = _contactEntries(person, 'phoneNumbers');
  final relations = _contactEntries(person, 'relations');
  final addresses = _contactEntries(person, 'addresses');
  final organization = _chosenOrganization(
    _contactEntries(person, 'organizations'),
  );
  final birthday = _contactEntries(person, 'birthdays').firstOrNull;
  final notes = _contactEntries(person, 'biographies').firstOrNull;
  final url = _chosenUrl(_contactEntries(person, 'urls'));
  final nickname = _contactEntries(person, 'nicknames').firstWhereOrNull(
    _defaultNickname,
  );
  ContactAddress? address(String type) {
    final entry = addresses.firstWhereOrNull((a) => _type(a) == type);
    return entry == null ? null : _addressFromGoogle(entry);
  }

  final mobile = _mobileIndex(phones);
  String? relation(String type) => _string(
    relations.firstWhereOrNull((r) => _type(r) == type)?['person'],
  );

  return SyncedContact({
    ContactField.name: name == null
        ? null
        : ContactName.of(
            given: _string(name['givenName']),
            middle: _string(name['middleName']),
            family: _string(name['familyName']),
            prefix: _string(name['honorificPrefix']),
            suffix: _string(name['honorificSuffix']),
            phoneticGiven: _string(name['phoneticGivenName']),
            phoneticFamily: _string(name['phoneticFamilyName']),
            // Raw, even when it is an email or the company: see
            // SyncedContact.copyableName.
            display:
                _string(name['unstructuredName']) ??
                _string(name['displayName']),
          ),
    ContactField.nickname: _string(nickname?['value']),
    ContactField.emails: _primaryFirst(
      _contactEntries(person, 'emailAddresses'),
    ).map((e) => _string(e['value'])).nonNulls.toList(),
    ContactField.mobile: mobile == null
        ? null
        : _string(phones[mobile]['value']),
    ContactField.homePhones: [
      for (final p in phones)
        if (_type(p) == 'home') ?_string(p['value']),
    ],
    ContactField.workPhones: [
      for (final p in phones)
        if (_type(p) == 'work') ?_string(p['value']),
    ],
    ContactField.homeAddress: address('home'),
    ContactField.workAddress: address('work'),
    ContactField.otherAddress: address('other'),
    ContactField.company: _string(organization?['name']),
    ContactField.department: _string(organization?['department']),
    ContactField.jobTitle: _string(organization?['title']),
    ContactField.office: _string(organization?['location']),
    ContactField.birthday: birthday == null
        ? null
        : _birthdayFromGoogle(birthday),
    ContactField.notes: notes == null || _string(notes['value']) == null
        ? null
        : ContactNotes(
            notes['value'] as String,
            html: notes['contentType'] == 'TEXT_HTML',
          ),
    ContactField.spouse: relation('spouse'),
    ContactField.children: [
      for (final r in relations)
        if (_type(r) == 'child') ?_string(r['person']),
    ],
    ContactField.manager: relation('manager'),
    ContactField.assistant: relation('assistant'),
    ContactField.webPage: _string(url?['value']),
    ContactField.im: [
      for (final im in _contactEntries(person, 'imClients'))
        ?_string(im['username']),
    ],
  });
}

/// A Graph contact's synced details.
SyncedContact syncedFromGraph(Map<String, Object?> contact) {
  String? s(String key) => _string(contact[key]);
  List<String> strings(String key) =>
      _list(contact[key]).whereType<String>().toList();
  ContactAddress? address(String key) {
    final a = _map(contact[key]);
    return ContactAddress.of(
      street: _string(a['street']),
      city: _string(a['city']),
      region: _string(a['state']),
      postalCode: _string(a['postalCode']),
      country: _string(a['countryOrRegion']),
    );
  }

  final emails = [
    for (final e in _list(contact['emailAddresses']).map(_map))
      ?_string(e['address']),
  ];
  return SyncedContact({
    ContactField.name: ContactName.of(
      given: s('givenName'),
      middle: s('middleName'),
      family: s('surname'),
      prefix: s('title'),
      suffix: s('generation'),
      phoneticGiven: s('yomiGivenName'),
      phoneticFamily: s('yomiSurname'),
      // Raw, even when it is an email or the company: see
      // SyncedContact.copyableName.
      display: s('displayName'),
    ),
    ContactField.nickname: s('nickName'),
    ContactField.emails: emails,
    ContactField.mobile: s('mobilePhone'),
    ContactField.homePhones: strings('homePhones'),
    ContactField.workPhones: strings('businessPhones'),
    ContactField.homeAddress: address('homeAddress'),
    ContactField.workAddress: address('businessAddress'),
    ContactField.otherAddress: address('otherAddress'),
    ContactField.company: s('companyName'),
    ContactField.department: s('department'),
    ContactField.jobTitle: s('jobTitle'),
    ContactField.office: s('officeLocation'),
    ContactField.birthday: birthdayFromGraph(s('birthday')),
    ContactField.notes: s('personalNotes') == null
        ? null
        : ContactNotes(s('personalNotes')!),
    ContactField.spouse: s('spouseName'),
    ContactField.children: strings('children'),
    ContactField.manager: s('manager'),
    ContactField.assistant: s('assistantName'),
    ContactField.webPage: s('businessHomePage'),
    ContactField.im: strings('imAddresses'),
  });
}

/// Outlook's birthday as the day it falls on: the UTC date of the value
/// plus 12 hours, so a birthday kept at 11:59 UTC (as the sync writes
/// it), at midnight UTC, or at local midnight anywhere from UTC-12 to
/// UTC+12 lands on its own day. A year before 1700 is Outlook's way of
/// keeping none.
ContactBirthday? birthdayFromGraph(String? value) {
  if (value == null) return null;
  final at = DateTime.tryParse(value);
  if (at == null) return null;
  final day = at.toUtc().add(const Duration(hours: 12));
  return ContactBirthday(
    year: day.year < 1700 ? null : day.year,
    month: day.month,
    day: day.day,
  );
}

/// A birthday as Outlook keeps it: `YYYY-MM-DDT11:59:00Z`, where Exchange
/// keeps its own. Null for one without a year, which is never written.
String? birthdayToGraph(ContactBirthday? birthday) {
  if (birthday == null || birthday.year == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${birthday.year.toString().padLeft(4, '0')}-'
      '${two(birthday.month)}-${two(birthday.day)}T11:59:00Z';
}

// ---------------------------------------------------------------------------
// Lists.

/// Two lists merged by value, and what each side's list becomes.
@immutable
class ContactListMerge {
  const ContactListMerge({
    required this.google,
    required this.graph,
    this.googleReplaced = const {},
    this.removes = false,
  });

  /// Gmail's list after the merge: every value it keeps, in its order,
  /// then those Outlook added.
  final List<String> google;

  /// Outlook's, within its slots.
  final List<String> graph;

  /// Gmail values that an Outlook slot replaced (old raw value to new),
  /// to be changed in place: see [googlePersonUpdate].
  final Map<String, String> googleReplaced;

  /// Whether a value is removed or replaced on either side, which the
  /// change brake counts.
  final bool removes;
}

/// [field]'s lists merged by value. Every addition from either side is
/// kept, within Outlook's slots, and a value is removed from one side only
/// when it was in that side's base and in the other side's, and has since
/// gone from the other side: a value that was never copied across is never
/// removed. Outlook's list is its current values that Gmail still has, in
/// Outlook's order, with the free slots filled from Gmail in Gmail's order
/// (primary first, as read). A value Outlook put in place of another in
/// the same slot changes that Gmail entry in place.
///
/// With [removals] false (a new pair, or the first sync) the lists are
/// only joined.
ContactListMerge mergeContactList(
  ContactField field, {
  required List<String> google,
  List<String> googleBase = const [],
  required List<String> graph,
  List<String> graphBase = const [],
  required ContactNormaliser normaliser,
  bool removals = true,
}) {
  String? key(String v) => normaliser.itemKey(field, v);
  Set<String> keys(List<String> l) => {for (final v in l) ?key(v)};
  final g = keys(google);
  final gb = keys(googleBase);
  final h = keys(graph);
  final hb = keys(graphBase);
  final fromGoogle = !removals
      ? const <String>{}
      : {
          for (final k in g)
            if (gb.contains(k) && hb.contains(k) && !h.contains(k)) k,
        };
  final fromGraph = !removals
      ? const <String>{}
      : {
          for (final k in h)
            if (hb.contains(k) && gb.contains(k) && !g.contains(k)) k,
        };

  // A slot whose value Outlook replaced: the old one is going from Gmail,
  // and the new one is new everywhere.
  final slotReplacements = <String, String>{};
  for (var i = 0; i < graphBase.length && i < graph.length; i++) {
    final was = key(graphBase[i]);
    final now = key(graph[i]);
    if (was == null || now == null || was == now) continue;
    if (fromGoogle.contains(was) && !hb.contains(now) && !g.contains(now)) {
      slotReplacements[was] = graph[i];
    }
  }

  final newGoogle = <String>[];
  final placed = <String>{};
  final replaced = <String, String>{};
  for (final v in google) {
    final k = key(v);
    if (k != null && fromGoogle.contains(k)) {
      final instead = slotReplacements[k];
      final insteadKey = instead == null ? null : key(instead);
      if (instead != null && insteadKey != null && placed.add(insteadKey)) {
        newGoogle.add(instead);
        replaced[v] = instead;
      }
      continue;
    }
    newGoogle.add(v);
    if (k != null) placed.add(k);
  }
  for (final v in graph) {
    final k = key(v);
    if (k == null || fromGraph.contains(k)) continue;
    if (placed.add(k)) newGoogle.add(v);
  }

  final newGraph = <String>[];
  final inGraph = <String>{};
  for (final v in graph) {
    final k = key(v);
    if (k != null && fromGraph.contains(k)) continue;
    newGraph.add(v);
    if (k != null) inGraph.add(k);
  }
  final slots = field.slots;
  for (final v in newGoogle) {
    if (slots != null && newGraph.length >= slots) break;
    final k = key(v);
    if (k != null && inGraph.add(k)) newGraph.add(v);
  }

  return ContactListMerge(
    google: newGoogle,
    graph: newGraph,
    googleReplaced: replaced,
    removes: fromGoogle.isNotEmpty || fromGraph.isNotEmpty,
  );
}

// ---------------------------------------------------------------------------
// Writing into Gmail.

/// An update to send with `people.updateContact`: the body, and the
/// fields to name in `updatePersonFields`. The body holds the Person's
/// `resourceName`, `metadata.sources` with only its contact source as
/// read (`type`, `id`, `etag`: the version `updateContact` checks), and
/// each Person field in [updatePersonFields], rebuilt; nothing else, not
/// the top-level etag.
@immutable
class GooglePersonUpdate {
  const GooglePersonUpdate(this.person, this.updatePersonFields);

  final Map<String, Object?> person;
  final List<String> updatePersonFields;

  String get updatePersonFieldsParam => updatePersonFields.join(',');
}

/// The Person field each synced detail is kept in.
String googlePersonField(ContactField field) => switch (field) {
  ContactField.name => 'names',
  ContactField.nickname => 'nicknames',
  ContactField.emails => 'emailAddresses',
  ContactField.mobile ||
  ContactField.homePhones ||
  ContactField.workPhones => 'phoneNumbers',
  ContactField.homeAddress ||
  ContactField.workAddress ||
  ContactField.otherAddress => 'addresses',
  ContactField.company ||
  ContactField.department ||
  ContactField.jobTitle ||
  ContactField.office => 'organizations',
  ContactField.birthday => 'birthdays',
  ContactField.notes => 'biographies',
  ContactField.spouse ||
  ContactField.children ||
  ContactField.manager ||
  ContactField.assistant => 'relations',
  ContactField.webPage => 'urls',
  ContactField.im => 'imClients',
};

/// The update setting [fields] of [person] (as last read) to [target]'s
/// values (the body is set out at [GooglePersonUpdate]), and the Person
/// fields that names. Each field is rebuilt from the full current list
/// with only the matched entries changed: types, labels and every value
/// Outlook cannot hold are kept.
///
/// [replaced] says, per list, which value took which value's place in an
/// Outlook slot (old raw value to new): that Gmail entry is changed in
/// place, keeping its position, type and label. Other values missing from
/// the target are removed, and new ones are added at the end, emails as
/// type other.
///
/// A rewritten name leaves out `unstructuredName` so Google rebuilds it; a
/// rewritten address leaves out `formattedValue` for the same reason, and
/// keeps its `poBox`. A rewritten note is plain text.
///
/// [seen] is Gmail's side as the plan read it. A list value in [person]
/// that the plan never saw (neither there nor in [target]) was added
/// since, and is kept: only values the plan saw are ever removed. The
/// runner refuses a Person whose version ([googleContactEtag]) moved
/// anyway (see `ContactWrite.googleUpdate`); this is the second line.
GooglePersonUpdate googlePersonUpdate(
  Map<String, Object?> person,
  SyncedContact target,
  Iterable<ContactField> fields, {
  Map<ContactField, Map<String, String>> replaced = const {},
  required ContactNormaliser normaliser,
  SyncedContact? seen,
}) {
  final norm = normaliser;
  final wanted = fields.toSet();
  final personFields = wanted.map(googlePersonField).toSet();
  // Google checks the contact source's etag, so the body carries that
  // source as read; fields not named are not sent, since they are not
  // written anyway.
  final source = _contactSource(person);
  final rebuilt = <String, Object?>{
    'resourceName': ?person['resourceName'],
    if (source != null)
      'metadata': {
        'sources': [
          {
            for (final key in const ['type', 'id', 'etag'])
              if (source[key] != null) key: source[key],
          },
        ],
      },
  };
  for (final personField in personFields) {
    var entries = _contactEntries(
      person,
      personField,
    ).map((e) => <String, Object?>{...e}).toList();
    for (final field in ContactField.values) {
      if (!wanted.contains(field) || googlePersonField(field) != personField) {
        continue;
      }
      entries = _rebuildGoogle(
        field,
        entries,
        target[field],
        replaced[field] ?? const {},
        norm,
        seen: seen == null
            ? null
            : {
                for (final v in seen.list(field)) ?norm.itemKey(field, v),
              },
      );
    }
    rebuilt[personField] = entries;
  }
  return GooglePersonUpdate(
    rebuilt,
    personFields.toList()..sort(),
  );
}

/// A Person for `people.createContact`, carrying [details], in My
/// Contacts. A display name that is only an email or the company is no
/// name to copy ([SyncedContact.copyableName]). The hidden tag is the
/// wire client's to add (it adds it to every create, and a batch needs one
/// per contact).
Map<String, Object?> googleCreateBody(SyncedContact details) {
  final norm = ContactNormaliser.oneContact();
  final body = <String, Object?>{};
  for (final field in ContactField.values) {
    final value = field == ContactField.name
        ? details.copyableName
        : details[field];
    if (value == null) continue;
    if (field == ContactField.birthday && !details.birthday!.hasYear) continue;
    final personField = googlePersonField(field);
    final entries = ((body[personField] as List?) ?? [])
        .cast<Map<String, Object?>>();
    body[personField] = _rebuildGoogle(field, entries, value, const {}, norm);
  }
  body.removeWhere((_, v) => v is List && v.isEmpty);
  return {
    ...body,
    'memberships': [
      {
        'contactGroupMembership': {
          'contactGroupResourceName': googleMyContacts,
        },
      },
    ],
  };
}

/// The Person fields `updateContact` accepts, which a Restore writes.
const googleWritableFields = [
  'addresses', 'biographies', 'birthdays', 'calendarUrls', 'clientData',
  'emailAddresses', 'events', 'externalIds', 'genders', 'imClients',
  'interests', 'locales', 'locations', 'memberships', 'miscKeywords',
  'names', 'nicknames', 'occupations', 'organizations', 'phoneNumbers',
  'relations', 'sipAddresses', 'urls', 'userDefined',
];

/// A Person for `people.createContact` that brings back [person], a full
/// copy read before the sync deleted it: every field `updateContact`
/// accepts, and its memberships of labels that still exist
/// ([labelsThatExist], resource names). Other apps' `clientData` is kept;
/// the old hidden tag is not, since the wire client adds the new one.
/// Photos do not come back this way.
Map<String, Object?> googleRestoreBody(
  Map<String, Object?> person, {
  Set<String> labelsThatExist = const {},
}) {
  const outputOnly = {
    'metadata', 'formattedType', 'canonicalForm', 'displayName',
    'displayNameLastFirst', 'formattedProtocol', 'contactGroupId',
  };
  Map<String, Object?> clean(Map<String, Object?> entry) => {
    for (final e in entry.entries)
      if (!outputOnly.contains(e.key))
        e.key: e.value is Map
            ? clean(_map(e.value))
            : e.value,
  };

  final body = <String, Object?>{};
  for (final field in googleWritableFields) {
    if (field == 'memberships' || field == 'clientData') continue;
    final entries = _contactEntries(person, field).map(clean).toList();
    if (entries.isNotEmpty) body[field] = entries;
  }
  final clientData = [
    for (final e in _contactEntries(person, 'clientData'))
      if (e['key'] != googleLinkKey) clean(e),
  ];
  if (clientData.isNotEmpty) body['clientData'] = clientData;
  final labels = <String>{
    googleMyContacts,
    for (final m in _list(person['memberships']).map(_map))
      if (_string(_map(m['contactGroupMembership'])['contactGroupResourceName'])
          case final String label)
        if (labelsThatExist.contains(label)) label,
  };
  body['memberships'] = [
    for (final label in labels)
      {
        'contactGroupMembership': {'contactGroupResourceName': label},
      },
  ];
  return body;
}

List<Map<String, Object?>> _rebuildGoogle(
  ContactField field,
  List<Map<String, Object?>> entries,
  Object? value,
  Map<String, String> replaced,
  ContactNormaliser norm, {
  Set<String>? seen,
}) {
  switch (field) {
    case ContactField.name:
      return _single(
        entries,
        entries.isEmpty ? null : 0,
        value,
        (entry, v) => _googleName(entry, v as ContactName),
      );
    case ContactField.nickname:
      return _single(
        entries,
        _indexWhere(entries, _defaultNickname),
        value,
        (entry, v) => {...entry, 'value': v},
      );
    case ContactField.emails:
      return _rebuildList(
        entries,
        (_) => true,
        'value',
        value as List<String>? ?? const [],
        replaced,
        (v) => norm.itemKey(field, v),
        (v) => {'value': v, 'type': 'other'},
        seen: seen,
      );
    case ContactField.mobile:
      return _single(
        entries,
        _mobileIndex(entries),
        value,
        (entry, v) => {...entry, 'value': v}..remove('canonicalForm'),
        newEntry: (v) => {'value': v, 'type': 'mobile'},
      );
    case ContactField.homePhones || ContactField.workPhones:
      final type = field == ContactField.homePhones ? 'home' : 'work';
      return _rebuildList(
        entries,
        (e) => _type(e) == type,
        'value',
        value as List<String>? ?? const [],
        replaced,
        (v) => norm.itemKey(field, v),
        (v) => {'value': v, 'type': type},
        rewrite: (entry, v) => {...entry, 'value': v}..remove('canonicalForm'),
        seen: seen,
      );
    case ContactField.homeAddress ||
        ContactField.workAddress ||
        ContactField.otherAddress:
      final type = switch (field) {
        ContactField.homeAddress => 'home',
        ContactField.workAddress => 'work',
        _ => 'other',
      };
      return _single(
        entries,
        _indexWhere(entries, (e) => _type(e) == type),
        value,
        (entry, v) => _googleAddress(entry, v as ContactAddress),
        newEntry: (v) => _googleAddress({'type': type}, v as ContactAddress),
      );
    case ContactField.company ||
        ContactField.department ||
        ContactField.jobTitle ||
        ContactField.office:
      final key = switch (field) {
        ContactField.company => 'name',
        ContactField.department => 'department',
        ContactField.jobTitle => 'title',
        _ => 'location',
      };
      final index = _chosenOrganizationIndex(entries);
      final result = [...entries];
      if (index == null) {
        if (value != null) result.add({key: value});
        return result;
      }
      final entry = {...result[index]};
      if (value == null) {
        entry.remove(key);
      } else {
        entry[key] = value;
      }
      const bookkeeping = {'metadata', 'type', 'formattedType', 'current'};
      if (entry.keys.every(bookkeeping.contains)) {
        result.removeAt(index);
      } else {
        result[index] = entry;
      }
      return result;
    case ContactField.birthday:
      final birthday = value as ContactBirthday?;
      return _single(
        entries,
        entries.isEmpty ? null : 0,
        // A birthday without a year is never written: Gmail keeps its own.
        birthday == null || birthday.hasYear ? birthday : null,
        (entry, v) {
          final b = v as ContactBirthday;
          return {
            ...entry,
            'date': {'year': b.year, 'month': b.month, 'day': b.day},
          }..remove('text');
        },
        newEntry: (v) {
          final b = v as ContactBirthday;
          return {
            'date': {'year': b.year, 'month': b.month, 'day': b.day},
          };
        },
        keepWhenNull: birthday != null && !birthday.hasYear,
      );
    case ContactField.notes:
      return _single(
        entries,
        entries.isEmpty ? null : 0,
        value,
        (entry, v) => {
          ...entry,
          'value': (v as ContactNotes).text,
          'contentType': 'TEXT_PLAIN',
        },
      );
    case ContactField.spouse ||
        ContactField.manager ||
        ContactField.assistant:
      final type = switch (field) {
        ContactField.spouse => 'spouse',
        ContactField.manager => 'manager',
        _ => 'assistant',
      };
      return _single(
        entries,
        _indexWhere(entries, (e) => _type(e) == type),
        value,
        (entry, v) => {...entry, 'person': v},
        newEntry: (v) => {'person': v, 'type': type},
      );
    case ContactField.children:
      return _rebuildList(
        entries,
        (e) => _type(e) == 'child',
        'person',
        value as List<String>? ?? const [],
        replaced,
        (v) => norm.itemKey(field, v),
        (v) => {'person': v, 'type': 'child'},
        seen: seen,
      );
    case ContactField.webPage:
      final chosen = _chosenUrl(entries);
      return _single(
        entries,
        chosen == null ? null : entries.indexOf(chosen),
        value,
        (entry, v) => {...entry, 'value': v},
        newEntry: (v) => {'value': v, 'type': 'work'},
      );
    case ContactField.im:
      return _rebuildList(
        entries,
        (_) => true,
        'username',
        value as List<String>? ?? const [],
        replaced,
        (v) => norm.itemKey(field, v),
        (v) => {'username': v},
        seen: seen,
      );
  }
}

/// One entry of a list, [index] (null when there is none), set to
/// [value] or, when that is null, removed.
List<Map<String, Object?>> _single(
  List<Map<String, Object?>> entries,
  int? index,
  Object? value,
  Map<String, Object?> Function(Map<String, Object?> entry, Object value) set, {
  Map<String, Object?> Function(Object value)? newEntry,
  bool keepWhenNull = false,
}) {
  final result = [...entries];
  if (value == null) {
    if (index != null && !keepWhenNull) result.removeAt(index);
    return result;
  }
  if (index != null) {
    result[index] = set(result[index], value);
  } else {
    result.add(newEntry != null ? newEntry(value) : set({}, value));
  }
  return result;
}

/// The entries that [member] picks out, made to hold the values of
/// [target] and no others; every other entry is passed over where it is.
List<Map<String, Object?>> _rebuildList(
  List<Map<String, Object?>> entries,
  bool Function(Map<String, Object?>) member,
  String valueKey,
  List<String> target,
  Map<String, String> replaced,
  String? Function(String) key,
  Map<String, Object?> Function(String value) newEntry, {
  Map<String, Object?> Function(Map<String, Object?> entry, String value)?
  rewrite,
  Set<String>? seen,
}) {
  final wanted = {for (final v in target) ?key(v): v};
  final replacedByKey = {
    for (final e in replaced.entries) ?key(e.key): e.value,
  };
  final placed = <String>{};
  final result = <Map<String, Object?>>[];
  for (final entry in entries) {
    if (!member(entry)) {
      result.add(entry);
      continue;
    }
    final k = key(_string(entry[valueKey]) ?? '');
    // A value with no key (a phone with no digits) cannot be compared, so
    // it is never removed; nor is one the plan never saw.
    if (k == null ||
        (seen != null && !seen.contains(k) && !replacedByKey.containsKey(k))) {
      result.add(entry);
      if (k != null) placed.add(k);
      continue;
    }
    if (wanted.containsKey(k)) {
      // Already there, or there twice: either way not Outlook's to remove.
      result.add(entry);
      placed.add(k);
      continue;
    }
    final replacement = replacedByKey[k];
    final replacementKey = replacement == null ? null : key(replacement);
    if (replacement != null &&
        replacementKey != null &&
        wanted.containsKey(replacementKey) &&
        !placed.contains(replacementKey)) {
      final changed = rewrite != null
          ? rewrite(entry, replacement)
          : {...entry, valueKey: replacement};
      result.add(changed);
      placed.add(replacementKey);
    }
  }
  for (final e in wanted.entries) {
    if (placed.add(e.key)) result.add(newEntry(e.value));
  }
  return result;
}

Map<String, Object?> _googleName(Map<String, Object?> entry, ContactName name) {
  const parts = {
    'givenName', 'middleName', 'familyName', 'honorificPrefix',
    'honorificSuffix', 'phoneticGivenName', 'phoneticFamilyName',
    'unstructuredName', 'displayName', 'displayNameLastFirst',
  };
  final result = {
    for (final e in entry.entries)
      if (!parts.contains(e.key)) e.key: e.value,
  };
  if (!name.hasParts) {
    result['unstructuredName'] = name.display;
    return result;
  }
  return {
    ...result,
    'givenName': ?name.given,
    'middleName': ?name.middle,
    'familyName': ?name.family,
    'honorificPrefix': ?name.prefix,
    'honorificSuffix': ?name.suffix,
    'phoneticGivenName': ?name.phoneticGiven,
    'phoneticFamilyName': ?name.phoneticFamily,
  };
}

/// An address entry set to [address]. The street goes back the way Gmail
/// split it: when its last line is Gmail's `extendedAddress` that stays,
/// and the rest is `streetAddress`; otherwise the first line is
/// `streetAddress` and any others `extendedAddress`.
Map<String, Object?> _googleAddress(
  Map<String, Object?> entry,
  ContactAddress address,
) {
  final result = {...entry}..remove('formattedValue');
  final lines = (address.street ?? '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final extended = _string(entry['extendedAddress']);
  String? street;
  String? more;
  if (extended != null && lines.length > 1 && lines.last == extended) {
    street = lines.sublist(0, lines.length - 1).join('\n');
    more = extended;
  } else {
    street = lines.first;
    more = lines.length > 1 ? lines.sublist(1).join('\n') : null;
  }
  void put(String key, String? value) {
    if (value == null || value.trim().isEmpty) {
      result.remove(key);
    } else {
      result[key] = value;
    }
  }

  put('streetAddress', street);
  put('extendedAddress', more);
  put('city', address.city);
  put('region', address.region);
  put('postalCode', address.postalCode);
  final oldCountry = _string(entry['country']) ?? _string(entry['countryCode']);
  final countryChanged =
      ContactNormaliser.countryKey(oldCountry) !=
          ContactNormaliser.countryKey(address.country) ||
      (address.country != null && entry['countryCode'] == null);
  put('country', address.country);
  if (countryChanged) {
    put(
      'countryCode',
      address.country == null ? null : countryCodeFor(address.country!),
    );
  }
  return result;
}

// ---------------------------------------------------------------------------
// Writing into Outlook.

/// The Graph property (or properties) each synced detail is kept in.
List<String> graphProperties(ContactField field) => switch (field) {
  ContactField.name => const [
    'givenName', 'middleName', 'surname', 'title', 'generation',
    'yomiGivenName', 'yomiSurname',
  ],
  ContactField.nickname => const ['nickName'],
  ContactField.emails => const ['emailAddresses'],
  ContactField.mobile => const ['mobilePhone'],
  ContactField.homePhones => const ['homePhones'],
  ContactField.workPhones => const ['businessPhones'],
  ContactField.homeAddress => const ['homeAddress'],
  ContactField.workAddress => const ['businessAddress'],
  ContactField.otherAddress => const ['otherAddress'],
  ContactField.company => const ['companyName'],
  ContactField.department => const ['department'],
  ContactField.jobTitle => const ['jobTitle'],
  ContactField.office => const ['officeLocation'],
  ContactField.birthday => const ['birthday'],
  ContactField.notes => const ['personalNotes'],
  ContactField.spouse => const ['spouseName'],
  ContactField.children => const ['children'],
  ContactField.manager => const ['manager'],
  ContactField.assistant => const ['assistantName'],
  ContactField.webPage => const ['businessHomePage'],
  ContactField.im => const ['imAddresses'],
};

/// The body of a Graph `PATCH` setting [fields] of [current] (the contact
/// as read) to [target]'s values: the changed properties only,
/// collections and addresses whole, and the display name every time,
/// because Graph otherwise makes its own (see [graphDisplayName]). Lists
/// longer than Outlook's slots are cut to them.
Map<String, Object?> graphContactPatch(
  Map<String, Object?> current,
  SyncedContact target,
  Iterable<ContactField> fields,
) {
  final wanted = fields.toSet();
  final body = <String, Object?>{};
  for (final field in ContactField.values) {
    if (!wanted.contains(field)) continue;
    body.addAll(_graphValues(field, target[field], current, target));
  }
  final shown = graphDisplayName(
    current,
    wanted.contains(ContactField.name) ? target.name : null,
    nameChanged: wanted.contains(ContactField.name),
  );
  if (shown != null) body['displayName'] = shown;
  return body;
}

/// The body of a Graph `POST` making a contact with [details]. A display
/// name that is only an email or the company is no name to copy
/// ([SyncedContact.copyableName]). The hidden tag is the wire client's to
/// add.
Map<String, Object?> graphCreateBody(SyncedContact details) {
  final name = details.copyableName;
  final body = <String, Object?>{};
  for (final field in ContactField.values) {
    final value = field == ContactField.name ? name : details[field];
    if (value == null) continue;
    body.addAll(_graphValues(field, value, const {}, details));
  }
  body.removeWhere((_, v) => v == null || (v is List && v.isEmpty));
  for (final e in body.entries.toList()) {
    if (e.value is Map) {
      body[e.key] = {...e.value as Map}..removeWhere((_, v) => v == null);
    }
  }
  final shown = graphDisplayName(const {}, name, nameChanged: true);
  if (shown != null) body['displayName'] = shown;
  return body;
}

/// The `PATCH` body that moves the hidden tag to [tag]: after Gmail
/// re-keyed the contact it names.
Map<String, Object?> graphTagPatch(String tag) => {
  'singleValueExtendedProperties': [
    {'id': graphLinkPropertyId, 'value': tag},
  ],
};

/// Every property of a Graph v1.0 contact that a `POST` takes, which a
/// Restore writes back.
const graphWritableProperties = [
  'assistantName', 'birthday', 'businessAddress', 'businessHomePage',
  'businessPhones', 'categories', 'children', 'companyName', 'department',
  'displayName', 'emailAddresses', 'fileAs', 'generation', 'givenName',
  'homeAddress', 'homePhones', 'imAddresses', 'initials', 'jobTitle',
  'manager', 'middleName', 'mobilePhone', 'nickName', 'officeLocation',
  'otherAddress', 'personalNotes', 'profession', 'spouseName', 'surname',
  'title', 'yomiCompanyName', 'yomiGivenName', 'yomiSurname',
];

/// A Graph `POST` body that brings back [contact], a full copy read
/// before the sync deleted it: every writable v1.0 property. The hidden
/// tag is the wire client's to add. Fax, pager and anniversary do not
/// come back this way.
Map<String, Object?> graphRestoreBody(Map<String, Object?> contact) => {
  for (final key in graphWritableProperties)
    if (contact[key] != null) key: contact[key],
};

/// The display name to send with a `PATCH` or `POST`.
///
/// Outlook's own is resent as it is, unless the name is being changed
/// and Outlook's equals one of the usual compositions of the old name
/// parts (with or without title, middle name and suffix, or "Last,
/// First"): then the new parts are sent in that same form. A contact that
/// had no parts, or no display name, gets the parts in the usual order,
/// middle name and suffix included; a name with no parts travels as its
/// display name.
String? graphDisplayName(
  Map<String, Object?> current,
  ContactName? name, {
  required bool nameChanged,
}) {
  final own = _string(current['displayName']);
  if (!nameChanged || name == null) return own;
  if (!name.hasParts) return name.display;
  final old = syncedFromGraph(current).name;
  if (own == null || old == null || !old.hasParts) {
    return _compose(name, _NameForm.withMiddleSuffix);
  }
  final squashed = own.trim().replaceAll(RegExp(r'\s+'), ' ');
  for (final form in _NameForm.values) {
    if (_compose(old, form) == squashed) {
      return _compose(name, form) ??
          _compose(name, _NameForm.withMiddleSuffix);
    }
  }
  return own;
}

/// The usual compositions, tried in this order: where an old part was
/// empty, several forms give the same text, and the first, the one with
/// the most parts in it, is the one the new parts are put in.
enum _NameForm {
  withMiddleSuffix(middle: true, suffix: true),
  withMiddle(middle: true),
  withSuffix(suffix: true),
  plain(),
  full(title: true, middle: true, suffix: true),
  withTitleMiddle(title: true, middle: true),
  withTitleSuffix(title: true, suffix: true),
  withTitle(title: true),
  lastMiddle(lastFirst: true, middle: true),
  lastPlain(lastFirst: true);

  const _NameForm({
    this.title = false,
    this.middle = false,
    this.suffix = false,
    this.lastFirst = false,
  });

  final bool title;
  final bool middle;
  final bool suffix;
  final bool lastFirst;
}

String? _compose(ContactName name, _NameForm form) {
  String? words(List<String?> parts) {
    final joined = parts.nonNulls
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .join(' ');
    return joined.isEmpty ? null : joined;
  }

  if (form.lastFirst) {
    final first = words([name.given, if (form.middle) name.middle]);
    final last = name.family;
    if (last == null || first == null) return null;
    return '$last, $first';
  }
  return words([
    if (form.title) name.prefix,
    name.given,
    if (form.middle) name.middle,
    name.family,
    if (form.suffix) name.suffix,
  ]);
}

Map<String, Object?> _graphValues(
  ContactField field,
  Object? value,
  Map<String, Object?> current,
  SyncedContact target,
) {
  List<String> slots(Object? v) {
    final list = (v as List<String>?) ?? const [];
    return field.slots == null ? [...list] : list.take(field.slots!).toList();
  }

  Map<String, Object?> address(Object? v) {
    final a = v as ContactAddress?;
    return {
      'street': a?.street,
      'city': a?.city,
      'state': a?.region,
      'postalCode': a?.postalCode,
      'countryOrRegion': a?.country,
    };
  }

  final property = graphProperties(field).first;
  switch (field) {
    case ContactField.name:
      final n = value as ContactName?;
      final parts = n != null && n.hasParts ? n : null;
      return {
        'givenName': parts?.given,
        'middleName': parts?.middle,
        'surname': parts?.family,
        'title': parts?.prefix,
        'generation': parts?.suffix,
        'yomiGivenName': parts?.phoneticGiven,
        'yomiSurname': parts?.phoneticFamily,
      };
    case ContactField.emails:
      // Each address's name is resent with the list: Outlook's own for an
      // address it has, else the contact's name.
      final names = {
        for (final e in _list(current['emailAddresses']).map(_map))
          if (_string(e['address']) case final String a)
            a.trim().toLowerCase(): _string(e['name']),
      };
      final fallback =
          _string(current['displayName']) ??
          target.copyableName?.shown ??
          '';
      return {
        property: [
          for (final a in slots(value))
            {
              'address': a,
              'name':
                  names[a.trim().toLowerCase()] ??
                  (fallback.isEmpty ? a : fallback),
            },
        ],
      };
    case ContactField.homePhones ||
        ContactField.workPhones ||
        ContactField.children ||
        ContactField.im:
      return {property: slots(value)};
    case ContactField.homeAddress ||
        ContactField.workAddress ||
        ContactField.otherAddress:
      return {property: address(value)};
    case ContactField.birthday:
      return {property: birthdayToGraph(value as ContactBirthday?)};
    case ContactField.notes:
      final notes = value as ContactNotes?;
      return {property: notes?.text.replaceAll('\r\n', '\n')};
    default:
      return {property: value as String?};
  }
}

// ---------------------------------------------------------------------------
// Shared.

/// A Person field's entries from the contact itself.
List<Map<String, Object?>> _contactEntries(
  Map<String, Object?> person,
  String field,
) => [
  for (final entry in _list(person[field]).map(_map))
    if (_isContactEntry(entry)) entry,
];

bool _isContactEntry(Map<String, Object?> entry) {
  final source = _map(_map(entry['metadata'])['source']);
  final type = source['type'];
  return type == null || type == 'CONTACT';
}

String? _type(Map<String, Object?> entry) =>
    _string(entry['type'])?.toLowerCase();

bool _defaultNickname(Map<String, Object?> e) {
  final type = _string(e['type']);
  return type == null || type == 'DEFAULT';
}

int? _indexWhere(
  List<Map<String, Object?>> entries,
  bool Function(Map<String, Object?>) test,
) {
  final i = entries.indexWhere(test);
  return i < 0 ? null : i;
}

/// The mobile: the first of type mobile, else the first work mobile.
int? _mobileIndex(List<Map<String, Object?>> phones) =>
    _indexWhere(phones, (p) => _type(p) == 'mobile') ??
    _indexWhere(phones, (p) => _type(p) == 'workmobile');

bool _primary(Map<String, Object?> entry) =>
    _map(entry['metadata'])['primary'] == true;

List<Map<String, Object?>> _primaryFirst(
  List<Map<String, Object?>> entries,
) => [...entries.where(_primary), ...entries.whereNot(_primary)];

/// The organisation synced: the primary one, else the first not marked
/// past. Google Contacts' own editor leaves `current` out, so an
/// organisation without it counts as current.
int? _chosenOrganizationIndex(List<Map<String, Object?>> entries) =>
    _indexWhere(entries, _primary) ??
    _indexWhere(entries, (e) => e['current'] != false);

Map<String, Object?>? _chosenOrganization(List<Map<String, Object?>> entries) {
  final i = _chosenOrganizationIndex(entries);
  return i == null ? null : entries[i];
}

/// The web page synced: the work one, else the home page, else the first.
Map<String, Object?>? _chosenUrl(List<Map<String, Object?>> entries) =>
    entries.firstWhereOrNull((u) => _type(u) == 'work') ??
    entries.firstWhereOrNull((u) => _type(u) == 'homepage') ??
    entries.firstOrNull;

ContactAddress? _addressFromGoogle(Map<String, Object?> entry) {
  final street = _string(entry['streetAddress']);
  final extended = _string(entry['extendedAddress']);
  return ContactAddress.of(
    street: [street, extended].nonNulls.join('\n'),
    city: _string(entry['city']),
    region: _string(entry['region']),
    postalCode: _string(entry['postalCode']),
    country: _string(entry['country']) ?? _string(entry['countryCode']),
  );
}

ContactBirthday? _birthdayFromGoogle(Map<String, Object?> entry) {
  final date = _map(entry['date']);
  final month = date['month'];
  final day = date['day'];
  final year = date['year'];
  if (month is! int || day is! int || month == 0 || day == 0) return null;
  return ContactBirthday(
    year: year is int && year > 0 ? year : null,
    month: month,
    day: day,
  );
}

String? _string(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

Map<String, Object?> _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : const {};

List<Object?> _list(Object? v) => v is List ? v : const [];
