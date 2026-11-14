import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small, device-local UI state: which folders are expanded, favourites, the
/// user's folder ordering, the last selected folder.
///
/// This is a handful of id sets, so it lives in shared_preferences rather than
/// the Drift database that the message cache will need. Everything is read
/// synchronously after startup so the tree renders in its remembered shape on
/// the first frame rather than snapping into it a moment later.
abstract class UiStateStore {
  Set<String> readIds(String key);
  Future<void> writeIds(String key, Set<String> ids);

  Map<String, int> readOrder(String key);
  Future<void> writeOrder(String key, Map<String, int> order);

  String? readString(String key);
  Future<void> writeString(String key, String? value);

  /// [key]'s text as the device has it now, whatever this copy holds:
  /// another window of the app may have written it since this one last
  /// looked. Each keeps its own copy, read once at its start.
  ///
  /// Asked for by key, never by reading everything again. That emptied the
  /// one copy the account list and every setting are read from until the
  /// device had answered, and whoever asked for an account meanwhile was
  /// told there was none: "Unknown account" on every account in the folder
  /// list, on some starts of the app.
  Future<String?> readFresh(String key);
}

/// Keys, in one place so the notifiers and the tests agree.
abstract final class UiStateKeys {
  static const expanded = 'tree.expanded';
  static const favorites = 'tree.favorites';
  static const hidden = 'tree.hidden';
  static const collapsedAccounts = 'tree.collapsed-accounts';
  static const order = 'tree.order';
  static const selected = 'tree.selected';
  static const recentMoves = 'move.recents';
  static const quickSteps = 'quicksteps.v1';
  static const signatures = 'signatures.v1';
  // Notification preferences are deliberately NOT here: they are read by the
  // background isolate, which cannot see this store's cache. See SyncStateKeys.
  static const paneWidths = 'panes.v1';

  /// The message list's columns: their widths, and which are put away.
  static const listColumns = 'list.columns.v1';
  static const folderPane = 'panes.folder-visible';
  static const display = 'display.v1';
  static const trustedSenders = 'images.trusted.v1';
  static const attachmentsFolded = 'attachments.folded';
  static const backgroundAsked = 'sync.background-asked';

  /// Conditional formats for the message list, in order of precedence.
  static const rowFormats = 'list.row-formats.v1';

  /// Pinned messages, by id. Not in the backup: the ids are this device's.
  static const pinned = 'list.pinned.v1';

  /// Read-receipt requests answered here, by Message-ID. Not in the backup.
  static const answeredReceipts = 'mail.receipts-answered.v1';

  /// Contact groups, typed into To like one person.
  static const contactGroups = 'compose.groups.v1';

  /// Addresses taken out of the suggestions from mail history.
  static const forgottenAddresses = 'compose.forgotten.v1';

  /// Online meetings made ahead of Send and not yet sent or undone; see
  /// `PreparedMeetingLedger`.
  static const preparedMeetings = 'meetings.prepared.v1';

  /// The days of the week worked, as `DateTime.weekday` numbers: for the
  /// free times put in a message and Next free time.
  static const workWeek = 'meetings.work-week.v1';

  /// Senders blocked and never blocked; see `SenderBlocks`. Read by the
  /// engine as mail arrives, in the background worker too.
  static const senderBlocks = 'junk.senders.v1';

  /// Follow-ups kept on this device: due days where the account keeps none,
  /// and reminders. Not in the backup: a reminder is this phone's.
  static const followUps = 'followups.v1';

  /// The last searches, newest first. Not in the backup.
  static const recentSearches = 'search.recent.v1';

  /// The searches kept in the tree's Saved searches.
  static const savedSearches = 'search.saved.v1';

  /// The accounts whose calendars are in the phone's own calendar, and
  /// when that was last brought up to date; see `PhoneCalendarSync`. Read
  /// by the background worker too. The time is written by both, each
  /// through its own copy of these settings, so it is read with
  /// [UiStateStore.readFresh]. Not in the backup: the calendars are this
  /// phone's.
  static const phoneCalendars = 'calendar.phone.v1';
  static const phoneCalendarsSynced = 'calendar.phone-synced.v1';

  /// The calendar view: Agenda, Day, Week or Month, and the accounts it
  /// leaves out.
  static const calendarView = 'calendar.view.v1';
  static const hiddenCalendars = 'calendar.hidden.v1';

  /// How many days Week shows, and how tall an hour is drawn: this
  /// device's, so not in the backup. See `WeekSpan`.
  static const calendarWeekSpan = 'calendar.week-span.v1';
  static const calendarHourHeight = 'calendar.hour-height.v1';

  /// Whether Day and Week fold their all-day events to a line.
  static const calendarAllDayFolded = 'calendar.all-day-folded.v1';

  /// Declined meetings and the working day; see `CalendarPrefs`. In the
  /// backup.
  static const calendarPrefs = 'calendar.prefs.v1';

  /// The calendars from links (see `InternetCalendar`). In the backup.
  static const internetCalendars = 'calendar.internet.v1';

  /// The meeting reminders and the morning agenda set with Android, and
  /// when they were last brought up to date; see `CalendarUpkeep`. Written
  /// by the background worker and the app, each through its own copy of
  /// these settings, so read with [UiStateStore.readFresh]. Not in the
  /// backup: they are this phone's.
  static const meetingReminders = 'calendar.reminders-set.v1';
  static const agendaSet = 'calendar.agenda-set.v1';
  static const calendarKeptUp = 'calendar.kept-up.v1';

  /// Whether the phone's clock is set to 24 hours, as the app last saw it,
  /// for what the background writes: it has no screen to ask.
  static const clock24h = 'clock.24h.v1';

  /// My Day in the folder pane's place, and the meetings swiped off the
  /// bar over the mail. This device's.
  static const myDay = 'calendar.my-day.v1';
  static const meetingBarDismissed = 'calendar.bar-dismissed.v1';

  /// Settings, Claude (Duet), and what the uploader has sent and when; see
  /// `DuetUploader`. Read by the background worker too. What was sent, when
  /// and how it went are written by the worker and the app, each through
  /// its own copy of these settings, so read with [UiStateStore.readFresh].
  /// Not in the backup: the key that goes with them is a secret of this
  /// phone's.
  static const duet = 'duet.settings.v1';
  static const duetSent = 'duet.sent.v1';
  static const duetLastRun = 'duet.last-run.v1';
  static const duetStatus = 'duet.status.v1';

  /// How many days each Microsoft account's password lasts, by account id,
  /// where it is not `PasswordExpiry.defaultDays`; 0 for never. Not in the
  /// backup: the ids are this device's.
  static const passwordDays = 'accounts.password-days.v1';

  /// When each Microsoft account's password was last changed, in seconds,
  /// where Microsoft keeps no date: put in by hand, or from a sign-out.
  /// Not in the backup.
  static const passwordChanged = 'accounts.password-changed.v1';

  /// The password reminders set with Android, by id, so one no longer
  /// wanted can be taken back.
  static const passwordReminders = 'accounts.password-reminders.v1';
}

/// Backed by shared_preferences, which works on Android and in the browser.
class PrefsUiStateStore implements UiStateStore {
  PrefsUiStateStore(this._prefs);

  final SharedPreferencesWithCache _prefs;

  static Future<PrefsUiStateStore> open() async {
    final prefs = await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    );
    return PrefsUiStateStore(prefs);
  }

  @override
  Future<String?> readFresh(String key) async {
    try {
      // The same store this copy was read from and writes to, asked
      // directly.
      return await SharedPreferencesAsync().getString(key);
    } on TypeError {
      // Kept as something other than text: nothing of ours.
      return null;
    }
  }

  @override
  Set<String> readIds(String key) =>
      (_prefs.getStringList(key) ?? const []).toSet();

  @override
  Future<void> writeIds(String key, Set<String> ids) =>
      _prefs.setStringList(key, ids.toList());

  @override
  Map<String, int> readOrder(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {for (final e in decoded.entries) e.key: e.value as int};
    } on FormatException {
      return const {};
    }
  }

  @override
  Future<void> writeOrder(String key, Map<String, int> order) =>
      _prefs.setString(key, jsonEncode(order));

  @override
  String? readString(String key) => _prefs.getString(key);

  @override
  Future<void> writeString(String key, String? value) =>
      value == null ? _prefs.remove(key) : _prefs.setString(key, value);
}

/// For tests and the default provider value: remembers within one run only.
class MemoryUiStateStore implements UiStateStore {
  final Map<String, Set<String>> _ids = {};
  final Map<String, Map<String, int>> _orders = {};
  final Map<String, String> _strings = {};

  @override
  Future<String?> readFresh(String key) async => readString(key);

  @override
  Set<String> readIds(String key) => Set.of(_ids[key] ?? const {});

  @override
  Future<void> writeIds(String key, Set<String> ids) async =>
      _ids[key] = Set.of(ids);

  @override
  Map<String, int> readOrder(String key) => Map.of(_orders[key] ?? const {});

  @override
  Future<void> writeOrder(String key, Map<String, int> order) async =>
      _orders[key] = Map.of(order);

  @override
  String? readString(String key) => _strings[key];

  @override
  Future<void> writeString(String key, String? value) async =>
      value == null ? _strings.remove(key) : _strings[key] = value;
}
