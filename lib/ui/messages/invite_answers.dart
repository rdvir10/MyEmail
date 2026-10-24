import 'package:flutter/material.dart';

import '../../domain/calendar_invite.dart';
import '../../domain/free_busy.dart';

/// An answer to an invitation with more to it than a tap gives: a note to
/// the organiser, or no word to them at all. Outlook's Edit the Response
/// before Sending and Do Not Send a Response, in one place.
typedef NotedAnswer = ({InviteResponse response, String note, bool send});

/// A new time proposed: Outlook's Propose New Time, as a tentative or a
/// declined answer with the time beside it.
typedef ProposedAnswer = ({
  InviteResponse response,
  TimeSpan proposal,
  String note,
});

/// Asks for an answer with a note. Null if backed out of. [canStayQuiet]
/// where the account answers on a calendar of its own, which can take an
/// answer without a word to the organiser; over mail, an answer not sent
/// is no answer, so the choice is not offered.
Future<NotedAnswer?> askForNotedAnswer(
  BuildContext context, {
  bool canStayQuiet = false,
}) =>
    showDialog<NotedAnswer>(
      context: context,
      builder: (_) => _NotedAnswerDialog(canStayQuiet: canStayQuiet),
    );

/// Asks for a new time for [invite], starting from the time it has. Null
/// if backed out of.
Future<ProposedAnswer?> askForProposal(
  BuildContext context,
  CalendarInvite invite,
) =>
    showDialog<ProposedAnswer>(
      context: context,
      builder: (_) => _ProposeDialog(invite: invite),
    );

class _NotedAnswerDialog extends StatefulWidget {
  const _NotedAnswerDialog({required this.canStayQuiet});

  final bool canStayQuiet;

  @override
  State<_NotedAnswerDialog> createState() => _NotedAnswerDialogState();
}

class _NotedAnswerDialogState extends State<_NotedAnswerDialog> {
  InviteResponse _response = InviteResponse.accepted;
  bool _send = true;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Answer'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<InviteResponse>(
                segments: [
                  for (final r in InviteResponse.values)
                    ButtonSegment(value: r, label: Text(_label(r))),
                ],
                selected: {_response},
                onSelectionChanged: (s) => setState(() => _response = s.first),
                showSelectedIcon: false,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('answer-note'),
                controller: _note,
                enabled: _send,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'A note to the organiser',
                  border: OutlineInputBorder(),
                ),
              ),
              if (widget.canStayQuiet)
                SwitchListTile(
                  key: const ValueKey('answer-tell'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tell the organiser'),
                  subtitle: Text(
                    _send
                        ? 'They get your answer, with the note.'
                        : 'Your calendar has the answer; the organiser is '
                            'not told.',
                  ),
                  value: _send,
                  onChanged: (on) => setState(() => _send = on),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('answer-send'),
            onPressed: () => Navigator.of(context).pop((
              response: _response,
              note: _send ? _note.text : '',
              send: _send,
            )),
            child: Text(_send ? 'Send' : 'Answer'),
          ),
        ],
      );
}

class _ProposeDialog extends StatefulWidget {
  const _ProposeDialog({required this.invite});

  final CalendarInvite invite;

  @override
  State<_ProposeDialog> createState() => _ProposeDialogState();
}

class _ProposeDialogState extends State<_ProposeDialog> {
  late DateTime _start = widget.invite.start.toLocal();
  late Duration _length = widget.invite.end == null
      ? const Duration(hours: 1)
      : widget.invite.end!.difference(widget.invite.start);
  InviteResponse _response = InviteResponse.tentative;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final day = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (day == null) return;
    setState(() => _start =
        DateTime(day.year, day.month, day.day, _start.hour, _start.minute));
  }

  Future<void> _pickTime({required bool end}) async {
    final from = end ? _start.add(_length) : _start;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(from),
    );
    if (time == null) return;
    setState(() {
      final picked = DateTime(
          _start.year, _start.month, _start.day, time.hour, time.minute);
      if (end) {
        if (picked.isAfter(_start)) _length = picked.difference(_start);
      } else {
        _start = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String clock(DateTime t) => localizations.formatTimeOfDay(
          TimeOfDay.fromDateTime(t),
          alwaysUse24HourFormat: use24h,
        );
    return AlertDialog(
      title: const Text('Propose a new time'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_outlined),
              title: Text(localizations.formatFullDate(_start)),
              onTap: _pickDay,
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('propose-start'),
                    onPressed: () => _pickTime(end: false),
                    child: Text(clock(_start)),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('to'),
                ),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('propose-end'),
                    onPressed: () => _pickTime(end: true),
                    child: Text(clock(_start.add(_length))),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<InviteResponse>(
              segments: const [
                ButtonSegment(
                  value: InviteResponse.tentative,
                  label: Text('Tentative'),
                ),
                ButtonSegment(
                  value: InviteResponse.declined,
                  label: Text('Decline'),
                ),
              ],
              selected: {_response},
              onSelectionChanged: (s) => setState(() => _response = s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'A note to the organiser',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('propose-send'),
          onPressed: () => Navigator.of(context).pop((
            response: _response,
            proposal: (start: _start, end: _start.add(_length)),
            note: _note.text,
          )),
          child: const Text('Send'),
        ),
      ],
    );
  }
}

String _label(InviteResponse r) => switch (r) {
      InviteResponse.accepted => 'Accept',
      InviteResponse.tentative => 'Tentative',
      InviteResponse.declined => 'Decline',
    };
