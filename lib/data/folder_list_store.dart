import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/folder_role.dart';
import 'imap/imap_transport.dart';

/// The last folder list seen for each account, so the tree can render at
/// start-up before the server answers, and at all when it cannot.
///
/// Counts are as of the last successful LIST; they are refreshed on the next
/// one. This is small JSON, so it lives in shared_preferences beside the
/// account list rather than in the message database.
abstract class FolderListStore {
  List<RemoteFolder>? read(String accountId);
  Future<void> write(String accountId, List<RemoteFolder> folders);
  Future<void> delete(String accountId);
}

class PrefsFolderListStore implements FolderListStore {
  PrefsFolderListStore(this._prefs);

  final SharedPreferencesWithCache _prefs;

  static String _key(String accountId) => 'folders.v1.$accountId';

  @override
  List<RemoteFolder>? read(String accountId) {
    final raw = _prefs.getString(_key(accountId));
    if (raw == null || raw.isEmpty) return null;
    // Anything wrong with what is stored reads as nothing stored, which the
    // engine already handles by asking the server. An unknown role name
    // throws ArgumentError and a malformed entry TypeError, and letting
    // either out made every delete on the account fail, since finding
    // Trash reads this list first.
    try {
      return decodeFolderList(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String accountId, List<RemoteFolder> folders) =>
      _prefs.setString(_key(accountId), encodeFolderList(folders));

  @override
  Future<void> delete(String accountId) => _prefs.remove(_key(accountId));
}

class MemoryFolderListStore implements FolderListStore {
  final Map<String, List<RemoteFolder>> _lists = {};

  @override
  List<RemoteFolder>? read(String accountId) => _lists[accountId];

  @override
  Future<void> write(String accountId, List<RemoteFolder> folders) async =>
      _lists[accountId] = List.of(folders);

  @override
  Future<void> delete(String accountId) async => _lists.remove(accountId);
}

String encodeFolderList(List<RemoteFolder> folders) => jsonEncode([
      for (final f in folders)
        {
          'path': f.path,
          'role': f.role.name,
          'managed': f.isServerManaged,
          'unread': f.unread,
          'total': f.total,
        },
    ]);

List<RemoteFolder> decodeFolderList(String raw) {
  final list = jsonDecode(raw) as List<dynamic>;
  return [
    for (final e in list.cast<Map<String, dynamic>>())
      RemoteFolder(
        path: e['path'] as String,
        role: FolderRole.values.byName(e['role'] as String),
        isServerManaged: e['managed'] as bool? ?? false,
        unread: e['unread'] as int? ?? 0,
        total: e['total'] as int? ?? 0,
      ),
  ];
}
