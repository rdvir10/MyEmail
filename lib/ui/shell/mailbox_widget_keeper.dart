import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import '../../data/widget/widget_setup_channel.dart';
import '../../data/widget/widget_taps.dart';
import '../../state/providers.dart';
import '../../state/widget_providers.dart';
import '../calendar/calendar_screen.dart' show CalendarScreen, openMeeting;

/// Keeps the home-screen widgets in step with the app being used.
///
/// A widget's "new" counts from the last time its own mailbox was on screen.
/// It used to count from the last time the app came to the front, whatever
/// was on screen, so opening one mailbox took every widget to zero.
///
/// A mailbox counts as looked at when it is chosen — tapped in the tree, or
/// its widget tapped — and again as it goes off screen, for what arrived
/// while it was there. The one the app merely opens on counts only once it
/// has stayed a moment: a widget tap comes in just after the app is back in
/// front, and until then the mailbox on screen is whichever one was left
/// there last time.
///
/// The widgets are redrawn as that happens and as the counts move while the
/// app is in use, so they are already right by the time the home screen is
/// back, rather than changing a moment after it.
///
/// Wrapped around the app rather than living in the shell, so it keeps
/// working while a message is open, a screen is pushed, or the shell is
/// rebuilt underneath it.
class MailboxWidgetKeeper extends ConsumerStatefulWidget {
  const MailboxWidgetKeeper({super.key, required this.child});

  final Widget child;

  /// How long the mailbox the app opens on has to stay on screen to count
  /// as looked at.
  static const glance = Duration(milliseconds: 1500);

  /// How long the counts are left to settle before the widgets are redrawn
  /// from them: marking forty messages read moves them forty times.
  static const settle = Duration(seconds: 2);

  /// The time, for tests, whose clock DateTime.now() does not follow.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  @override
  ConsumerState<MailboxWidgetKeeper> createState() =>
      _MailboxWidgetKeeperState();
}

class _MailboxWidgetKeeperState extends ConsumerState<MailboxWidgetKeeper>
    with WidgetsBindingObserver {
  /// The mailbox on screen while the app is in front; null while it is
  /// away, or showing the calendar a widget opened.
  String? _viewing;

  /// When [_viewing] came on screen.
  DateTime _since = DateTime(0);

  /// Whether [_viewing] was chosen, rather than the one the app opened on.
  bool _chosen = false;

  /// Hidden or paused since the app was last in front.
  bool _away = false;

  /// Opened on the calendar by its widget. The mailbox under it is not
  /// being read, and counts again once the calendar is closed.
  bool _onCalendar = false;

  StreamSubscription<Uri?>? _taps;
  Timer? _settling;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The first opening with a widget placed is where "new" starts for a
    // mailbox not looked at since. Android is asked here which widgets are
    // still on the home screen, as only the app can.
    unawaited(ref
        .read(mailboxWidgetsProvider)
        .opened(MailboxWidgetKeeper.now().toUtc())
        .then((_) => _redraw(prune: true)));

    ref.listenManual<String?>(
      effectiveSelectedFolderIdProvider,
      _shown,
      fireImmediately: true,
    );
    // A listing after mail is read, moved or arrives. Read from the cache
    // the listing has just written.
    ref.listenManual(foldersProvider, (_, _) {
      _settling?.cancel();
      _settling = Timer(MailboxWidgetKeeper.settle, _redraw);
    });

    // Opened by tapping a widget: go where it was pointing.
    widgetLinkAppOpenedOn().then((uri) {
      if (!mounted) return;
      if (folderFromWidgetLink(uri) case final folderId?) _openFolder(folderId);
      if (calendarFromWidgetLink(uri) case final link?) _openCalendar(link);
    });
    _taps = listenForWidgetTaps(_openFolder, onCalendar: _openCalendar);
  }

  @override
  void dispose() {
    _taps?.cancel();
    _settling?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A different mailbox on screen. From one to another is a choice; from
  /// none to one is the app arriving on it as the folders load.
  ///
  /// Not while the app is away: put away from another folder, the list goes
  /// back to its account's Inbox, and nobody chose it. It is the one the
  /// app opens on when it comes back. A widget tapped meanwhile has already
  /// said what is on screen, before its selection gets here.
  void _shown(String? previous, String? next) {
    if (next == previous || next == _viewing) return;
    final now = MailboxWidgetKeeper.now();
    final chose = previous != null && next != null && !_away;
    final left = _leave(now);
    if (next == null) {
      unawaited(left.then(_redrawIf));
      return;
    }
    if (!chose && (_away || _onCalendar)) {
      unawaited(left.then(_redrawIf));
      return;
    }
    if (chose) _onCalendar = false;
    _view(next, now, chosen: chose);
    unawaited(() async {
      final looked = await left;
      if (chose) await _look(next, now);
      _redrawIf(looked || chose);
    }());
  }

  void _view(String folderId, DateTime now, {required bool chosen}) {
    _viewing = folderId;
    _since = now;
    _chosen = chosen;
  }

  /// The mailbox on screen goes off it: looked at, unless it was only the
  /// one the app opened on, and only for a moment. True when it was.
  Future<bool> _leave(DateTime now) async {
    final folderId = _viewing;
    _viewing = null;
    if (folderId == null) return false;
    if (!_chosen && now.difference(_since) < MailboxWidgetKeeper.glance) {
      return false;
    }
    await _look(folderId, now);
    return true;
  }

  Future<void> _look(String folderId, DateTime now) =>
      ref.read(mailboxWidgetsProvider).seen(folderId, now.toUtc());

  /// Show what the tapped widget was counting, and count it as looked at.
  ///
  /// Set even when the folder is not in the tree yet: folders load a moment
  /// after the first frame, and the selection is honoured as soon as the one
  /// it names turns up.
  void _openFolder(String folderId) {
    if (!mounted) return;
    final now = MailboxWidgetKeeper.now();
    final left = _leave(now);
    _onCalendar = false;
    // Before the selection, so the change it makes is seen as this one.
    _view(folderId, now, chosen: true);
    ref.read(selectedFolderIdProvider.notifier).select(folderId);
    unawaited(() async {
      await left;
      await _look(folderId, now);
      _redraw();
    }());
  }

  /// The calendar widget tapped: the meeting, or the calendar on its day.
  void _openCalendar(CalendarLink link) {
    if (!mounted) return;
    _viewing = null;
    _onCalendar = true;
    final meeting = link.meeting;
    final closed = meeting != null
        ? openMeeting(context, ref, meeting)
        : CalendarScreen.open(context, day: link.day);
    // Back from the calendar to the mail: what is on screen now is read.
    unawaited(closed.whenComplete(() {
      if (!mounted || !_onCalendar) return;
      _onCalendar = false;
      if (_away || _viewing != null) return;
      final folderId = ref.read(effectiveSelectedFolderIdProvider);
      if (folderId != null) {
        _view(folderId, MailboxWidgetKeeper.now(), chosen: false);
      }
    }));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        if (_away) return;
        _away = true;
        _onCalendar = false;
        // Whatever was on screen was read up to now. Then every widget is
        // redrawn, from what the app already holds: syncing every widget's
        // folder on the way out cost battery and data for numbers that were
        // current a moment ago.
        unawaited(_leave(MailboxWidgetKeeper.now())
            .then((_) => _redraw(prune: true)));
      case AppLifecycleState.resumed:
        // Back from being away, and not merely given focus again: the
        // shade pushed back up, or the app tapped in split screen, and the
        // mail was on screen all along.
        if (!_away) return;
        _away = false;
        // A widget tapped to get here has already said what is on screen,
        // as has the calendar's.
        if (_viewing != null || _onCalendar) return;
        final folderId = ref.read(effectiveSelectedFolderIdProvider);
        if (folderId != null) {
          _view(folderId, MailboxWidgetKeeper.now(), chosen: false);
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  void _redrawIf(bool changed) {
    if (changed) _redraw();
  }

  /// The redraw under way, and whether another was asked for meanwhile.
  /// One at a time and at most one waiting, which then answers every ask
  /// made in between.
  Future<void>? _redrawing;
  bool _again = false;
  bool _prune = false;

  /// Every widget, from the cache. [prune] also asks Android which widgets
  /// are still on the home screen, and forgets the rest.
  void _redraw({bool prune = false}) {
    if (!mounted) return;
    _prune |= prune;
    if (_redrawing != null) {
      _again = true;
      return;
    }
    final widgets = ref.read(mailboxWidgetsProvider);
    final engine = ref.read(mailEngineProvider);
    final placed = _prune ? placedWidgetIds() : null;
    _prune = false;
    _redrawing = () async {
      await widgets.refresh(engine, placed: await placed, fromCache: true);
    }()
        .whenComplete(() {
      _redrawing = null;
      if (_again) {
        _again = false;
        _redraw();
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
