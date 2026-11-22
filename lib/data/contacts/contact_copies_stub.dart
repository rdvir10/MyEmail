import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, mapEquals;

import '../../domain/synced_contact.dart' show ContactNormaliser;

// Stand-ins for the merge rules of the Microsoft side's copies (batch B's
// lib/data/contacts/contact_copies.dart, handout-copies.md), so the runner
// can be written against their names before that file is merged. This
// file goes when it is. Its rules are rough: a property another copy has
// and the synced one lacks is added, one held differently differs.

@immutable
class OutlookCopy {
  const OutlookCopy({required this.id, required this.json, this.photo});

  final String id;
  final Map<String, Object?> json;
  final String? photo;
}

enum CopiesOutcome { same, adds, differs }

@immutable
class CopiesDetail {
  const CopiesDetail({required this.label, this.value});

  final String label;
  final String? value;
}

@immutable
class CopiesDifference {
  const CopiesDifference({
    required this.label,
    this.kept,
    this.others = const {},
  });

  final String label;
  final String? kept;
  final Map<String, String?> others;
}

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
  final Map<String, Object?> patch;
  final String? photoFrom;
  final List<CopiesDetail> adds;
  final List<CopiesDifference> differences;
  final String fingerprint;

  @override
  String toString() => 'CopiesMerge(${outcome.name}, ${adds.length} adds, '
      '${differences.length} differences)';
}

const _notCompared = {
  'id',
  'changeKey',
  'createdDateTime',
  'lastModifiedDateTime',
  'parentFolderId',
  'displayName',
  'fileAs',
  'givenName',
  'middleName',
  'surname',
  'generation',
};

bool _empty(Object? v) =>
    v == null ||
    (v is String && v.trim().isEmpty) ||
    (v is List && v.isEmpty) ||
    (v is Map && v.values.every(_empty));

bool _equal(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b) ||
    (a is Map && b is Map && mapEquals(a, b));

String? _shown(Object? v) => _empty(v) ? null : jsonEncode(v);

CopiesMerge mergeCopies(
  OutlookCopy kept,
  List<OutlookCopy> others, {
  String? keep,
  required ContactNormaliser norm,
}) {
  final patch = <String, Object?>{};
  final adds = <CopiesDetail>[];
  final differences = <CopiesDifference>[];
  final keys = <String>{
    for (final o in others)
      for (final k in o.json.keys)
        if (!_notCompared.contains(k) && !k.startsWith('@odata')) k,
  };
  for (final key in keys.toList()..sort()) {
    final mine = kept.json[key];
    final theirs = {
      for (final o in others)
        if (!_empty(o.json[key])) o.id: o.json[key],
    };
    if (theirs.isEmpty) continue;
    final differ = theirs.values.where((v) => !_equal(v, mine)).toList();
    if (differ.isEmpty) continue;
    if (_empty(mine) &&
        differ.every((v) => _equal(v, differ.first))) {
      patch[key] = differ.first;
      adds.add(CopiesDetail(label: key, value: _shown(differ.first)));
      continue;
    }
    differences.add(
      CopiesDifference(
        label: key,
        kept: _shown(mine),
        others: {
          for (final o in others) o.id: _shown(o.json[key]),
        },
      ),
    );
  }
  String? photoFrom;
  final photos = {
    for (final o in others)
      if (o.photo != null && o.photo != kept.photo) o.photo,
  };
  if (photos.isNotEmpty) {
    if (kept.photo == null && photos.length == 1) {
      photoFrom = others.firstWhere((o) => o.photo == photos.first).id;
      adds.add(const CopiesDetail(label: 'Photo', value: 'a photo'));
    } else {
      differences.add(
        CopiesDifference(
          label: 'Photo',
          kept: kept.photo == null ? null : 'a photo',
          others: {
            for (final o in others)
              o.id: o.photo == null ? null : 'another photo',
          },
        ),
      );
    }
  }
  final fingerprint = differences.isEmpty
      ? ''
      : jsonEncode([
          for (final d in differences) [d.label, d.kept, d.others],
        ]);
  if (differences.isNotEmpty && keep != null) {
    final winner = keep == kept.id
        ? null
        : others.where((o) => o.id == keep).firstOrNull;
    for (final d in differences) {
      if (d.label == 'Photo') {
        if (winner?.photo != null) photoFrom = winner!.id;
        continue;
      }
      if (winner != null && !_empty(winner.json[d.label])) {
        patch[d.label] = winner.json[d.label];
      }
    }
    return CopiesMerge(
      outcome: patch.isEmpty && photoFrom == null
          ? CopiesOutcome.same
          : CopiesOutcome.adds,
      patch: patch,
      photoFrom: photoFrom,
      adds: adds,
      fingerprint: fingerprint,
    );
  }
  return CopiesMerge(
    outcome: differences.isNotEmpty
        ? CopiesOutcome.differs
        : (patch.isEmpty && photoFrom == null
              ? CopiesOutcome.same
              : CopiesOutcome.adds),
    patch: differences.isEmpty ? patch : const {},
    photoFrom: differences.isEmpty ? photoFrom : null,
    adds: adds,
    differences: differences,
    fingerprint: fingerprint,
  );
}
