import 'package:flutter/foundation.dart' show immutable;

/// How a detail only Outlook keeps is read and compared.
enum OutlookOnlyKind {
  /// A phone, fax or other number, by its number.
  number,

  /// Text, by its words.
  text,

  /// A date, kept as a time (MAPI's `SystemTime`), by its day.
  date,
}

/// A detail Outlook keeps on a contact that Graph's contact resource
/// (v1.0) has no property for: a fax, the pager and the other phones, a
/// PO box, a user field, the anniversary. Graph reads and writes each only
/// as a single-value extended property, named by its MAPI property tag or,
/// for Outlook's own named ones, its property set and long id ([id]), and
/// gives it only to a read that asks for it by that id
/// (`GraphContactsApi`'s `withOutlookOnly`): a read without it shows none
/// of them, as though the contact had none.
///
/// The merge of Hadco's copies compares them as it does the other
/// details, and Hadco's backup file has a column for each. The sync
/// itself does not copy them to Gmail (PLAN, "What is copied").
@immutable
class OutlookOnlyDetail {
  const OutlookOnlyDetail(
    this.tag,
    this.label,
    this.column, [
    this.kind = OutlookOnlyKind.number,
  ]) : set = null;

  /// One of Outlook's named properties: text, [tag] its long id in the
  /// property set [set].
  const OutlookOnlyDetail.named(this.set, this.tag, this.label, this.column)
    : kind = OutlookOnlyKind.text;

  /// The GUID of a named property's set, as Microsoft's MAPI reference
  /// gives it; null for a property named by its tag.
  final String? set;

  /// Its MAPI property tag, or a named property's long id, as Microsoft's
  /// MAPI reference gives it ([MS-OXPROPS]).
  final int tag;

  /// Its name on the screen: "Business fax".
  final String label;

  /// Its column in Outlook's CSV.
  final String column;

  final OutlookOnlyKind kind;

  /// Its id as Graph takes it: the type and the tag ("String 0x3A24"), or
  /// the type, the set and the long id ("String {00062004-…} Id 0x804F").
  String get id {
    final type = kind == OutlookOnlyKind.date ? 'SystemTime' : 'String';
    final number = tag.toRadixString(16).toUpperCase().padLeft(4, '0');
    return set == null ? '$type 0x$number' : '$type {$set} Id 0x$number';
  }

  @override
  String toString() => 'OutlookOnlyDetail($id)';
}

/// Outlook's property set of contact details (PSETID_Address).
const _address = '00062004-0000-0000-C000-000000000046';

/// The details only Outlook keeps that the merge compares and the backup
/// file holds, in the order the screen lists them, each by the tag or the
/// set and long id Microsoft's MAPI reference gives it: every column of
/// Outlook's CSV that Graph's contact cannot fill; ISDN, the three PO
/// boxes, the ID fields and the four user fields of Outlook's own export;
/// and the customer ID, computer network name and FTP site, which only
/// Outlook's contact form shows.
///
/// Not read, so a copy holding one goes with the others as though it had
/// none, and the backup file has none of them (a known gap): files
/// attached to a contact (Outlook keeps a contact's photo as one, and
/// nearly every copy in Hadco has a photo of its own, 3.22.1); gender,
/// which is not text; billing information and mileage, which would take
/// the read's address past what Microsoft's front ends are known to take
/// (see `GraphContactsApi`); and the rest of Outlook's rarer fields. The
/// CSV's "Schools" has no property in that reference, and stays empty.
const outlookOnlyDetails = [
  OutlookOnlyDetail(0x3A24, 'Business fax', 'Business Fax'),
  OutlookOnlyDetail(0x3A25, 'Home fax', 'Home Fax'),
  // PidTagPrimaryFaxNumber: Outlook's "Other Fax".
  OutlookOnlyDetail(0x3A23, 'Other fax', 'Other Fax'),
  OutlookOnlyDetail(0x3A21, 'Pager', 'Pager'),
  OutlookOnlyDetail(0x3A1E, 'Car phone', 'Car Phone'),
  OutlookOnlyDetail(0x3A1F, 'Other phone', 'Other Phone'),
  OutlookOnlyDetail(0x3A1A, 'Primary phone', 'Primary Phone'),
  OutlookOnlyDetail(0x3A57, 'Company main phone', 'Company Main Phone'),
  OutlookOnlyDetail(0x3A2E, "Assistant's phone", "Assistant's Phone"),
  OutlookOnlyDetail(0x3A02, 'Callback', 'Callback'),
  OutlookOnlyDetail(0x3A1D, 'Radio phone', 'Radio Phone'),
  OutlookOnlyDetail(0x3A2C, 'Telex', 'Telex'),
  OutlookOnlyDetail(0x3A4B, 'TTY/TDD phone', 'TTY/TDD Phone'),
  OutlookOnlyDetail(0x3A2D, 'ISDN', 'ISDN'),
  // PidLidWorkAddressPostOfficeBox.
  OutlookOnlyDetail.named(
    _address,
    0x804A,
    'Work PO box',
    'Business Address PO Box',
  ),
  OutlookOnlyDetail(
    0x3A5E,
    'Home PO box',
    'Home Address PO Box',
    OutlookOnlyKind.text,
  ),
  OutlookOnlyDetail(
    0x3A64,
    'Other PO box',
    'Other Address PO Box',
    OutlookOnlyKind.text,
  ),
  OutlookOnlyDetail(
    0x3A50,
    'Personal web page',
    'Personal Web Page',
    OutlookOnlyKind.text,
  ),
  OutlookOnlyDetail(0x3A43, 'Hobbies', 'Hobby', OutlookOnlyKind.text),
  OutlookOnlyDetail(0x3A0D, 'Location', 'Location', OutlookOnlyKind.text),
  OutlookOnlyDetail(
    0x3A41,
    'Anniversary',
    'Anniversary',
    OutlookOnlyKind.date,
  ),
  OutlookOnlyDetail(0x3A00, 'Account', 'Account', OutlookOnlyKind.text),
  OutlookOnlyDetail(
    0x3A4A,
    'Customer ID',
    'Customer ID',
    OutlookOnlyKind.text,
  ),
  OutlookOnlyDetail(
    0x3A07,
    'Government ID',
    'Government ID Number',
    OutlookOnlyKind.text,
  ),
  OutlookOnlyDetail(
    0x3A10,
    'Organizational ID',
    'Organizational ID Number',
    OutlookOnlyKind.text,
  ),
  // PidTagReferredByName.
  OutlookOnlyDetail(
    0x3A47,
    'Referred by',
    'Referred By',
    OutlookOnlyKind.text,
  ),
  OutlookOnlyDetail(0x3A0C, 'Language', 'Language', OutlookOnlyKind.text),
  OutlookOnlyDetail(
    0x3A49,
    'Computer network name',
    'Computer Network Name',
    OutlookOnlyKind.text,
  ),
  OutlookOnlyDetail(0x3A4C, 'FTP site', 'FTP Site', OutlookOnlyKind.text),
  // PidLidContactUserField1 to 4.
  OutlookOnlyDetail.named(_address, 0x804F, 'User 1', 'User 1'),
  OutlookOnlyDetail.named(_address, 0x8050, 'User 2', 'User 2'),
  OutlookOnlyDetail.named(_address, 0x8051, 'User 3', 'User 3'),
  OutlookOnlyDetail.named(_address, 0x8052, 'User 4', 'User 4'),
];

/// The detail only Outlook keeps that [id] names; null for any other id.
OutlookOnlyDetail? outlookOnlyDetailOf(Object? id) =>
    _byKey[extendedPropertyKey(id)];

final _byKey = {
  for (final d in outlookOnlyDetails) extendedPropertyKey(d.id)!: d,
};

/// The key an extended property's id is matched by, in the tag form or as
/// a named property's set and long id. Exchange answers with an id in a
/// form of its own (letters small, no leading zeros: "String 0x3a24"), so
/// an id is matched by its type, its set and its number, never by its
/// text: each in small letters, the number as Exchange writes it. Null
/// for an id in neither form.
String? extendedPropertyKey(Object? id) {
  if (id is! String) return null;
  String number(String hex) => int.parse(hex, radix: 16).toRadixString(16);
  if (_tagged.firstMatch(id) case final m?) {
    return '${m[1]!.toLowerCase()} 0x${number(m[2]!)}';
  }
  if (_named.firstMatch(id) case final m?) {
    return '${m[1]!.toLowerCase()} {${m[2]!.toLowerCase()}} id '
        '0x${number(m[3]!)}';
  }
  return null;
}

/// An id in the tag form: a type, then the tag in hex.
final _tagged = RegExp(
  r'^\s*([A-Za-z]+)\s+0x([0-9a-f]{1,4})\s*$',
  caseSensitive: false,
);

/// A named property's id by its long id: a type, the set's GUID, then
/// `Id` and the number in hex.
final _named = RegExp(
  r'^\s*([A-Za-z]+)\s+\{([0-9a-f-]{36})\}\s+Id\s+0x([0-9a-f]{1,4})\s*$',
  caseSensitive: false,
);

/// [contact]'s values of the details only Outlook keeps, as Graph gave
/// them, from the `singleValueExtendedProperties` of a read that asked
/// for them; a detail it holds none of is not there.
Map<OutlookOnlyDetail, Object?> outlookOnlyValuesOf(
  Map<String, Object?> contact,
) {
  final props = contact['singleValueExtendedProperties'];
  return {
    for (final p in props is List ? props : const [])
      if (p is Map) ?outlookOnlyDetailOf(p['id']): p['value'],
  };
}
