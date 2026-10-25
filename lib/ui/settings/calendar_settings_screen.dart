import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/microsoft_oauth.dart';
import '../../data/calendar/phone_calendar_sync.dart';
import '../../domain/account.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../state/calendar_view_providers.dart';
import '../../state/providers.dart';
import '../accounts/microsoft_sign_in_screen.dart';
import '../common/bottom_message.dart';
import '../../domain/time_zones.dart' show placeOf;
import '../calendar/time_zone_picker.dart';
import '../messages/date_format.dart' show formatClock;

/// Settings, Calendar: how MyEmail's calendar shows the day, and Microsoft
/// accounts' calendars in the phone's own calendar, as Outlook for
/// Android's Sync calendars.
class CalendarSettingsScreen extends ConsumerWidget {
  const CalendarSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = [
      for (final a in ref.watch(accountsProvider).value ?? const <Account>[])
        if (PhoneCalendarSync.canShow(a)) a,
    ];
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final heading = theme.textTheme.labelMedium
        ?.copyWith(color: theme.colorScheme.primary);
    final prefs = ref.watch(calendarPrefsProvider);
    final setPrefs = ref.read(calendarPrefsProvider.notifier).set;
    final span = ref.watch(calendarWeekSpanProvider) ??
        (MediaQuery.sizeOf(context).width >= 700
            ? WeekSpan.sevenDays
            : WeekSpan.threeDays);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String hour(int h) => h == 24
        ? (use24h ? '24:00' : 'Midnight')
        : formatClock(DateTime(2000, 1, 1, h), use24h: use24h);
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar'), centerTitle: false),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
            child: Text('In MyEmail', style: heading),
          ),
          SwitchListTile(
            key: const ValueKey('calendar-declined-switch'),
            title: const Text('Show declined meetings'),
            subtitle: const Text(
              'Faint and struck through. Off, they are left out. Outlook '
              'takes a meeting you decline off its calendar itself; Google '
              'keeps it.',
            ),
            value: prefs.showDeclined,
            onChanged: (on) => setPrefs(prefs.copyWith(showDeclined: on)),
          ),
          ListTile(
            title: const Text('Week shows'),
            subtitle: const Text('Kept on this device'),
            trailing: DropdownButton<WeekSpan>(
              key: const ValueKey('calendar-week-span'),
              value: span,
              onChanged: (chosen) {
                if (chosen != null) {
                  ref.read(calendarWeekSpanProvider.notifier).set(chosen);
                }
              },
              items: [
                for (final s in WeekSpan.values)
                  DropdownMenuItem(value: s, child: Text(s.choice)),
              ],
            ),
          ),
          ListTile(
            title: const Text('Working day'),
            subtitle: const Text(
              'Where Day and Week open, with the hours outside it shaded',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButton<int>(
                  key: const ValueKey('calendar-day-start'),
                  value: prefs.dayStart,
                  onChanged: (h) {
                    if (h != null) setPrefs(prefs.copyWith(dayStart: h));
                  },
                  items: [
                    for (var h = 0; h < 24; h++)
                      DropdownMenuItem(value: h, child: Text(hour(h))),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('to'),
                ),
                DropdownButton<int>(
                  key: const ValueKey('calendar-day-end'),
                  value: prefs.dayEnd,
                  onChanged: (h) {
                    if (h != null) setPrefs(prefs.copyWith(dayEnd: h));
                  },
                  items: [
                    for (var h = prefs.dayStart + 1; h <= 24; h++)
                      DropdownMenuItem(value: h, child: Text(hour(h))),
                  ],
                ),
              ],
            ),
          ),
          ListTile(
            key: const ValueKey('calendar-second-zone'),
            title: const Text('Second time zone'),
            subtitle: Text(prefs.secondZone == null
                ? "None: Day and Week show the phone's own hours"
                : '${placeOf(prefs.secondZone!)}, beside your own in Day and '
                    'Week'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final chosen = await pickTimeZone(
                context,
                current: prefs.secondZone,
                none: 'None',
              );
              if (chosen == null) return;
              setPrefs(chosen.zone == null
                  ? prefs.copyWith(noSecondZone: true)
                  : prefs.copyWith(secondZone: chosen.zone));
            },
          ),
          SwitchListTile(
            key: const ValueKey('calendar-dates-in-mail'),
            title: const Text('Find dates in mail'),
            subtitle: const Text(
              'Days and times in a message are underlined; a tap makes a '
              'meeting then. Read on the phone, in English.',
            ),
            value: prefs.datesInMail,
            onChanged: (on) => setPrefs(prefs.copyWith(datesInMail: on)),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
            child: Text("In the phone's calendar", style: heading),
          ),
          for (final account in accounts) _PhoneCalendarRow(account: account),
          if (accounts.isEmpty)
            const ListTile(
              title: Text('No Microsoft account here to show.'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Text(
              "Meetings from Outlook show in Samsung's or Google's calendar "
              'app, with their reminders, from a month back to a year ahead. '
              'They are read only there: change them in Outlook, or answer '
              'them in MyEmail. MyEmail brings them up to date when it checks '
              "for mail, at most every half hour. A Gmail account's calendar "
              "is in the phone's calendar already, through Google.",
              style: muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _PhoneCalendarRow extends ConsumerStatefulWidget {
  const _PhoneCalendarRow({required this.account});

  final Account account;

  @override
  ConsumerState<_PhoneCalendarRow> createState() => _PhoneCalendarRowState();
}

class _PhoneCalendarRowState extends ConsumerState<_PhoneCalendarRow> {
  bool _busy = false;

  /// What the last try said, where it did not work.
  String? _problem;

  /// That try was refused for want of the calendar permission, which a
  /// sign-in again with it clears.
  bool _offerAllow = false;

  Account get account => widget.account;

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: kBottomMessage,
      persist: false,
      content: Text(text),
    ));

  /// Into the phone's calendar now, with every other account switched on.
  Future<bool> _bringUpToDate() async {
    final on = ref.read(phoneCalendarsProvider);
    final problems = await PhoneCalendarSync(
      engine: ref.read(mailEngineProvider),
      phone: ref.read(phoneCalendarProvider),
    ).run(ref.read(accountsProvider).value ?? const [], on);
    final problem = problems[account.id];
    if (!mounted) return problem == null;
    setState(() {
      _problem = switch (problem) {
        null => null,
        SignInNeedsConsent(:final needsAdministrator) => needsAdministrator
            ? 'Not allowed to read this calendar yet. Allow, then sign in; '
                'where your organisation has to approve it, the sign-in '
                'sends them the request.'
            : 'Not allowed to read this calendar yet. Allow, then sign in.',
        ReadableError(:final message) => message,
        _ => '$problem',
      };
      _offerAllow = problem is SignInNeedsConsent;
    });
    return problem == null;
  }

  Future<void> _set(bool on) async {
    final phone = ref.read(phoneCalendarProvider);
    final shown = ref.read(phoneCalendarsProvider.notifier);
    setState(() => _busy = true);
    try {
      if (on) {
        if (!await phone.requestPermission()) {
          _say("MyEmail needs the calendar permission for this. Allow it in "
              "Android's settings for MyEmail, under Permissions.");
          return;
        }
        shown.setShown(account.id, true);
        if (await _bringUpToDate()) {
          _say("${account.displayName}'s calendar is in the phone's calendar "
              'now.');
        }
      } else {
        shown.setShown(account.id, false);
        await phone.remove(account.id);
        if (mounted) setState(() => _problem = null);
        _say("Taken out of the phone's calendar.");
      }
    } catch (e) {
      if (mounted) setState(() => _problem = e is ReadableError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A sign-in that asks Microsoft for the calendar beside the mail, then
  /// the calendar again.
  Future<void> _allow() async {
    final token = await MicrosoftSignInScreen.show(
      context,
      loginHint: account.emailAddress,
      scopes: [...MicrosoftOAuth.scopes, ...MicrosoftOAuth.calendarScopes],
    );
    if (token == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(accountsProvider.notifier)
          .signInAgain(accountId: account.id, token: token);
      if (await _bringUpToDate()) {
        _say("${account.displayName}'s calendar is in the phone's calendar "
            'now.');
      }
    } catch (e) {
      if (mounted) setState(() => _problem = e is ReadableError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = ref.watch(phoneCalendarsProvider).contains(account.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: ValueKey('phone-calendar:${account.id}'),
          secondary: CircleAvatar(
            radius: 10,
            backgroundColor: Color(account.colorValue),
          ),
          title: Text(account.displayName),
          subtitle: Text(account.emailAddress),
          value: on,
          onChanged: _busy ? null : _set,
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _problem!,
                  key: ValueKey('phone-calendar-problem:${account.id}'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                if (_offerAllow)
                  TextButton(
                    key: ValueKey('phone-calendar-allow:${account.id}'),
                    onPressed: _busy ? null : _allow,
                    child: const Text('Allow'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
