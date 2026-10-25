import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/account.dart';
import '../../domain/error_report.dart' show ReadableError;
import '../../domain/mailbox_settings.dart';
import '../../state/providers.dart';
import '../../state/server_settings_providers.dart';
import '../common/bottom_message.dart';
import '../messages/date_format.dart';
import 'server_settings_access.dart';

/// "Off", "On", "From Mon 3 Nov, 09:00 to Fri 7 Nov, 18:00".
String autoReplyStatus(AutoReply reply, {required bool use24h, DateTime? now}) {
  final at = now ?? DateTime.now();
  if (!reply.on) return 'Off';
  if (!reply.scheduled) return 'On';
  String when(DateTime t) =>
      '${formatDay(t, now: at)}, ${formatClock(t, use24h: use24h)}';
  if (!reply.end!.isAfter(at)) return 'Off: ended ${formatDay(reply.end!, now: at)}';
  return reply.start!.isAfter(at)
      ? 'From ${when(reply.start!)} to ${when(reply.end!)}'
      : 'On until ${when(reply.end!)}';
}

/// Settings, Automatic replies: each account's, as its server keeps them.
/// Outlook's Automatic Replies and Gmail's vacation responder answer on the
/// server, with the phone off.
class AutoRepliesScreen extends ConsumerWidget {
  const AutoRepliesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = [
      for (final a in ref.watch(accountsProvider).value ?? const <Account>[])
        if (canReachServerSettings(a)) a,
    ];
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Automatic replies'), centerTitle: false),
      body: ListView(
        children: [
          for (final account in accounts)
            ListTile(
              key: ValueKey('auto-reply-account:${account.id}'),
              leading: const Icon(Icons.reply_all_outlined),
              title: Text(account.emailAddress),
              subtitle: Text(
                switch (ref.watch(autoReplyProvider(account.id))) {
                  AsyncData(:final value) =>
                    autoReplyStatus(value, use24h: use24h),
                  AsyncError(:final error) =>
                    serverSettingsProblem(account, error).offerSignIn
                        ? 'Not allowed yet'
                        : 'Could not be read just now',
                  _ => 'Checking…',
                },
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => AutoReplyScreen(account: account),
              )),
            ),
          if (accounts.isEmpty)
            const ListTile(
              title: Text('No account here can send automatic replies.'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Text(
              'The server sends them, so they go out with the phone off, and '
              'Outlook or Gmail on the web shows the same.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One account's automatic replies, as Outlook or Gmail sets them.
class AutoReplyScreen extends ConsumerStatefulWidget {
  const AutoReplyScreen({super.key, required this.account});

  final Account account;

  @override
  ConsumerState<AutoReplyScreen> createState() => _AutoReplyScreenState();
}

class _AutoReplyScreenState extends ConsumerState<AutoReplyScreen> {
  /// What is being set, from the server's once it is read.
  AutoReply? _reply;
  final _message = TextEditingController();
  final _outside = TextEditingController();
  final _subject = TextEditingController();

  /// Microsoft: a message of their own for people outside.
  bool _ownOutside = false;
  bool _saving = false;
  String? _error;

  Account get account => widget.account;

  @override
  void dispose() {
    _message.dispose();
    _outside.dispose();
    _subject.dispose();
    super.dispose();
  }

  void _take(AutoReply reply) {
    _reply = reply;
    _message.text = reply.message;
    _outside.text = reply.outsideMessage;
    _subject.text = reply.subject;
    _ownOutside = reply.outsideMessage.trim().isNotEmpty;
  }

  AutoReply get _edited => _reply!.copyWith(
        message: _message.text.trim(),
        outsideMessage: _ownOutside ? _outside.text.trim() : '',
        subject: _subject.text.trim(),
      );

  void _set(AutoReply next) => setState(() {
        _reply = next;
        _error = null;
      });

  Future<void> _save() async {
    final reply = _edited;
    if (reply.on && reply.message.isEmpty) {
      setState(() => _error = 'Write the message first.');
      return;
    }
    if (reply.on && reply.scheduled && !reply.end!.isAfter(reply.start!)) {
      setState(() => _error = 'The end has to be after the start.');
      return;
    }
    if (reply.on && reply.scheduled && !reply.end!.isAfter(DateTime.now())) {
      setState(() => _error = 'That end has passed.');
      return;
    }
    final settings = ref.read(mailEngineProvider).serverSettings(account.id);
    if (settings == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await settings.setAutoReply(reply);
      ref.invalidate(autoReplyProvider(account.id));
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: kBottomMessage,
          persist: false,
          content: Text(reply.on
              ? 'Automatic replies are on for ${account.emailAddress}.'
              : 'Automatic replies are off for ${account.emailAddress}.'),
        ));
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ReadableError ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// A day, then a time on it, from [initial].
  Future<DateTime?> _pick(DateTime initial) async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );
    if (day == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(day.year, day.month, day.day, time.hour, time.minute);
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(autoReplyProvider(account.id));
    final settings = ref.watch(mailEngineProvider).serverSettings(account.id);
    if (loaded case AsyncData(:final value) when _reply == null) _take(value);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Automatic replies'),
        centerTitle: false,
        actions: [
          if (_reply != null)
            _saving
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : TextButton(
                    key: const ValueKey('auto-reply-save'),
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
        ],
      ),
      body: switch (loaded) {
        _ when _reply != null && settings != null => _form(context, settings.repliesKnowOrganisation, settings.repliesHaveSubject),
        AsyncError(:final error) => ServerSettingsProblem(
            account: account,
            error: error,
            onRetry: () => ref.invalidate(autoReplyProvider(account.id)),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _form(BuildContext context, bool organisation, bool subject) {
    final theme = Theme.of(context);
    final reply = _reply!;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String when(DateTime t) =>
        '${formatDay(t)}, ${formatClock(t, use24h: use24h)}';
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final now = DateTime.now();
    final outsideOn = reply.audience != ReplyAudience.insideOnly;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(account.emailAddress, style: muted),
        ),
        SwitchListTile(
          key: const ValueKey('auto-reply-on'),
          title: const Text('Send automatic replies'),
          value: reply.on,
          onChanged: (on) => _set(reply.copyWith(on: on)),
        ),
        if (reply.on) ...[
          SwitchListTile(
            key: const ValueKey('auto-reply-scheduled'),
            title: const Text('Only during a time period'),
            value: reply.scheduled,
            onChanged: (only) {
              final start = DateTime(now.year, now.month, now.day, now.hour + 1);
              _set(only
                  ? reply.copyWith(
                      start: start,
                      end: DateTime(start.year, start.month, start.day + 7, 9),
                    )
                  : reply.copyWith(start: null, end: null));
            },
          ),
          if (reply.scheduled) ...[
            ListTile(
              key: const ValueKey('auto-reply-start'),
              contentPadding: const EdgeInsets.only(left: 32, right: 16),
              title: const Text('Starts'),
              subtitle: Text(when(reply.start!)),
              onTap: () async {
                final t = await _pick(reply.start!);
                if (t == null) return;
                // An end before the new start moves with it, a week on.
                _set(reply.copyWith(
                  start: t,
                  end: reply.end!.isAfter(t)
                      ? reply.end
                      : t.add(const Duration(days: 7)),
                ));
              },
            ),
            ListTile(
              key: const ValueKey('auto-reply-end'),
              contentPadding: const EdgeInsets.only(left: 32, right: 16),
              title: const Text('Ends'),
              subtitle: Text(when(reply.end!)),
              onTap: () async {
                final t = await _pick(reply.end!);
                if (t != null) _set(reply.copyWith(end: t));
              },
            ),
          ],
        ],
        if (subject)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              key: const ValueKey('auto-reply-subject'),
              controller: _subject,
              decoration: const InputDecoration(
                labelText: 'Subject',
                hintText: 'Re: and theirs, when empty',
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            key: const ValueKey('auto-reply-message'),
            controller: _message,
            minLines: 4,
            maxLines: 12,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              labelText: organisation
                  ? 'Message to people in my organisation'
                  : 'Message',
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ),
        if (organisation) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('auto-reply-outside'),
            title: const Text('Reply to people outside my organisation'),
            value: outsideOn,
            onChanged: (on) => _set(reply.copyWith(
              audience:
                  on ? ReplyAudience.everyone : ReplyAudience.insideOnly,
            )),
          ),
          if (outsideOn) ...[
            RadioGroup<ReplyAudience>(
              groupValue: reply.audience,
              onChanged: (a) => _set(reply.copyWith(audience: a)),
              child: const Column(
                children: [
                  RadioListTile<ReplyAudience>(
                    key: ValueKey('auto-reply-everyone'),
                    contentPadding: EdgeInsets.only(left: 32, right: 16),
                    value: ReplyAudience.everyone,
                    title: Text('Everyone outside'),
                  ),
                  RadioListTile<ReplyAudience>(
                    key: ValueKey('auto-reply-contacts'),
                    contentPadding: EdgeInsets.only(left: 32, right: 16),
                    value: ReplyAudience.contacts,
                    title: Text('Only my contacts'),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              key: const ValueKey('auto-reply-own-outside'),
              contentPadding: const EdgeInsets.only(left: 32, right: 16),
              title: const Text('A different message for them'),
              value: _ownOutside,
              onChanged: (own) => setState(() => _ownOutside = own),
            ),
            if (_ownOutside)
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 4, 16, 0),
                child: TextField(
                  key: const ValueKey('auto-reply-outside-message'),
                  controller: _outside,
                  minLines: 3,
                  maxLines: 12,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    labelText: 'Message to people outside',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
          ],
        ] else ...[
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('auto-reply-contacts-only'),
            title: const Text('Only reply to people in my contacts'),
            value: reply.audience == ReplyAudience.contacts,
            onChanged: (only) => _set(reply.copyWith(
              audience: only ? ReplyAudience.contacts : ReplyAudience.everyone,
            )),
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              _error!,
              key: const ValueKey('auto-reply-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            organisation
                ? 'Outlook sends one reply to each person while these are '
                    'on.'
                : 'Gmail replies to each person once every four days while '
                    'this is on.',
            style: muted,
          ),
        ),
      ],
    );
  }
}
