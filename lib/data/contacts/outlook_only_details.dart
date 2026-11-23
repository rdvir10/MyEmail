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
/// (v1.0) has no property for: a fax, the pager and the other phones, the
/// anniversary, the personal web page. Graph reads and writes each only
/// as a single-value extended property named by its MAPI property tag
/// ([id]), and gives it only to a read that asks for it by that id
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
  ]);

  /// Its MAPI property tag, as Microsoft's MAPI reference gives it
  /// ([MS-OXPROPS]).
  final int tag;

  /// Its name on the screen: "Business fax".
  final String label;

  /// Its column in Outlook's CSV.
  final String column;

  final OutlookOnlyKind kind;

  /// Its id as Graph takes it, the type and the tag: "String 0x3A24".
  String get id =>
      '${kind == OutlookOnlyKind.date ? 'SystemTime' : 'String'} '
      '0x${tag.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  @override
  String toString() => 'OutlookOnlyDetail($id)';
}

/// The details only Outlook keeps that the merge compares and the backup
/// file holds, in the order the screen lists them: every column of
/// Outlook's CSV that Graph's contact cannot fill, and ISDN, each by the
/// tag Microsoft's MAPI reference gives it. The CSV's "Schools" has no
/// property there, and stays empty. Not the contact's attachments:
/// Outlook keeps a contact's photo as one, and nearly every copy in Hadco
/// has a photo of its own (3.22.1).
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
];

/// The detail only Outlook keeps that [id] names; null for any other id.
OutlookOnlyDetail? outlookOnlyDetailOf(Object? id) =>
    _byKey[extendedPropertyKey(id)];

final _byKey = {
  for (final d in outlookOnlyDetails) extendedPropertyKey(d.id)!: d,
};

/// The key an extended property's id in the tag form is matched by.
/// Exchange answers with an id in a form of its own (the tag in small
/// letters, no leading zeros: "String 0x3a24"), so an id is matched by
/// its type and its number, never by its text: the type in small letters
/// and the tag as Exchange writes it. Null for an id in no such form.
String? extendedPropertyKey(Object? id) {
  if (id is! String) return null;
  final m = _tagged.firstMatch(id);
  if (m == null) return null;
  final tag = int.parse(m[2]!, radix: 16).toRadixString(16);
  return '${m[1]!.toLowerCase()} 0x$tag';
}

/// An id in the tag form: a type, then the tag in hex.
final _tagged = RegExp(
  r'^\s*([A-Za-z]+)\s+0x([0-9a-f]{1,4})\s*$',
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
