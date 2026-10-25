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

/// Settings, Calendar: Microsoft accounts' calendars in the phone's own
/// calendar, as Outlook for Android's Sync calendars.
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
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar'), centerTitle: false),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
            child: Text(
              "In the phone's calendar",
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
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
