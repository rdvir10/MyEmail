import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'free_busy.dart' show defaultWorkWeek;
import 'mail_message.dart';
import 'search_field.dart';

/// Outlook's search filters, the second row under the search box: what the
/// hits must also be. Applied to the hits the server gave, so turning one
/// on or off asks nothing again.
enum SearchRefinement {
  unread('Unread'),
  flagged('Flagged'),
  attachments('Has attachments'),
  important('Important'),
  thisWeek('This week'),
  large('Large');

  const SearchRefinement(this.label);

  final String label;

  /// Past this, a message is large: Outlook's Large Mail starts at 100 KB,
  /// which on a phone is most mail with a picture in it, so a megabyte.
  static const largeBytes = 1024 * 1024;
}

/// [hits] that are everything [refinements] asks, as of [now], in a week
/// worked on [workWeek] (for This week).
List<MailMessage> refineSearch(
  List<MailMessage> hits,
  Set<SearchRefinement> refinements, {
  required DateTime now,
  Set<int> workWeek = defaultWorkWeek,
}) {
  if (refinements.isEmpty) return hits;
  final weekFrom = weekStartFor(now, workWeek: workWeek);
  bool keeps(MailMessage m, SearchRefinement r) => switch (r) {
        SearchRefinement.unread => !m.isRead,
        SearchRefinement.flagged => m.isFlagged,
        SearchRefinement.attachments => m.hasAttachments,
        SearchRefinement.important => m.importance == Importance.high,
        SearchRefinement.thisWeek => !m.date.toLocal().isBefore(weekFrom),
        SearchRefinement.large => m.sizeBytes > SearchRefinement.largeBytes,
      };
  return [
    for (final m in hits)
      if (refinements.every((r) => keeps(m, r))) m,
  ];
}

/// Midnight on the first day of the week [now] is in: where its run of
/// working days begins, and on a day off, the run before it. Monday for a
/// Monday-to-Friday week, Sunday for a Sunday-to-Thursday one.
DateTime weekStartFor(DateTime now, {Set<int> workWeek = defaultWorkWeek}) {
  final today = DateTime(now.year, now.month, now.day);
  DateTime day(int d) => DateTime(today.year, today.month, today.day + d);
  if (workWeek.isEmpty || workWeek.length == 7) {
    return day(-(today.weekday - DateTime.monday));
  }
  bool worked(int d) => workWeek.contains(day(d).weekday);
  var d = 0;
  while (d > -7 && !worked(d)) {
    d--;
  }
  while (d > -7 && worked(d - 1)) {
    d--;
  }
  return day(d);
}

/// A search kept to run again: Outlook's Search Folders, under the tree's
/// Saved searches. The words, where in a message they are looked for, the
/// filters, and how far: everything, one account, or one folder.
@immutable
class SavedSearch {
  const SavedSearch({
    required this.id,
    required this.name,
    required this.query,
    this.field = SearchField.all,
    this.refinements = const {},
    this.accountId,
    this.folderId,
  });

  final String id;
  final String name;
  final String query;
  final SearchField field;
  final Set<SearchRefinement> refinements;

  /// One account, where it was saved so; null for everything.
  final String? accountId;

  /// One folder, where it was saved so; null for an account or everything.
  final String? folderId;

  SavedSearch renamed(String name) => SavedSearch(
        id: id,
        name: name,
        query: query,
        field: field,
        refinements: refinements,
        accountId: accountId,
        folderId: folderId,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'query': query,
        'field': field.name,
        'refinements': [for (final r in refinements) r.name],
        'accountId': ?accountId,
        'folderId': ?folderId,
      };

  static SavedSearch? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'], query = json['query'];
    if (id is! String || name is! String || query is! String) return null;
    final field = SearchField.values
        .where((f) => f.name == json['field'])
        .firstOrNull;
    final refinements = json['refinements'];
    return SavedSearch(
      id: id,
      name: name,
      query: query,
      field: field ?? SearchField.all,
      refinements: {
        for (final r in refinements is List ? refinements : const [])
          ...SearchRefinement.values.where((v) => v.name == r),
      },
      accountId: json['accountId'] is String ? json['accountId'] as String : null,
      folderId: json['folderId'] is String ? json['folderId'] as String : null,
    );
  }

  static List<SavedSearch> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final json = jsonDecode(raw);
      return [
        for (final s in json is List ? json : const []) ?fromJson(s),
      ];
    } on FormatException {
      return const [];
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SavedSearch &&
      other.id == id &&
      other.name == name &&
      other.query == query &&
      other.field == field &&
      setEquals(other.refinements, refinements) &&
      other.accountId == accountId &&
      other.folderId == folderId;

  @override
  int get hashCode => Object.hash(id, name, query, field,
      Object.hashAllUnordered(refinements), accountId, folderId);
}

/// The tree's id for a saved search's row.
String savedSearchRowId(String id) => 'saved:$id';

/// The saved search a tree row is, or null for a folder.
String? savedSearchIdOf(String rowId) =>
    rowId.startsWith('saved:') ? rowId.substring('saved:'.length) : null;
