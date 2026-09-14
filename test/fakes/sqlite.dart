/// SQLite for tests on this machine.
///
/// sqlite3 3.x ships as a Dart native asset: its build hook fetches a
/// prebuilt library for the host, and Flutter 3.47 has native assets enabled,
/// so `flutter test` needs no DLL on the PATH and no loader override. This
/// helper exists only as the one place to put a platform workaround if a
/// future host ever needs one; today it has nothing to do.
bool ensureSqlite3() => true;
