import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/folder_list_store.dart';
import 'package:myemail/data/imap/imap_transport.dart';
import 'package:myemail/domain/folder_role.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// The folder list kept in preferences, which the app reads at start-up and
/// before every delete (to find Trash).
///
/// Every other test uses the in-memory store, so what is actually written
/// to the device, and what happens when it cannot be read back, was never
/// run.
void main() {
  late SharedPreferencesWithCache prefs;
  late PrefsFolderListStore store;

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    store = PrefsFolderListStore(prefs);
  });

  test('every role and the server-managed mark come back as written',
      () async {
    final folders = [
      for (final (i, role) in FolderRole.values.indexed)
        RemoteFolder(
          path: 'Folder $i',
          role: role,
          isServerManaged: i.isEven,
          unread: i,
          total: i * 10,
        ),
    ];

    await store.write('acct', folders);
    final back = store.read('acct')!;

    expect([for (final f in back) f.path], [for (final f in folders) f.path]);
    expect([for (final f in back) f.role], FolderRole.values);
    expect([for (final f in back) f.isServerManaged],
        [for (final f in folders) f.isServerManaged]);
    expect([for (final f in back) f.unread], [for (final f in folders) f.unread]);
    expect([for (final f in back) f.total], [for (final f in folders) f.total]);
  });

  test('nothing stored reads as nothing', () {
    expect(store.read('acct'), isNull);
  });

  group('a stored list that cannot be read is treated as none', () {
    // Each of these used to throw out of read(), and every delete on the
    // account failed with the raw error.
    Future<void> stored(String raw) =>
        prefs.setString('folders.v1.acct', raw);

    test('a role this build does not know', () async {
      await stored('[{"path":"INBOX","role":"somethingNew"}]');
      expect(store.read('acct'), isNull);
    });

    test('an entry with no path', () async {
      await stored('[{"role":"inbox"}]');
      expect(store.read('acct'), isNull);
    });

    test('an entry of the wrong kind', () async {
      await stored('["INBOX"]');
      expect(store.read('acct'), isNull);
    });

    test('JSON that is not a list', () async {
      await stored('{"path":"INBOX","role":"inbox"}');
      expect(store.read('acct'), isNull);
    });

    test('text that is not JSON', () async {
      await stored('not json');
      expect(store.read('acct'), isNull);
    });
  });
}
