import 'package:flutter/material.dart';

import '../../domain/calendar_invite.dart';
import '../../domain/free_busy.dart';

/// An answer to an invitation as it goes: with a note to the organiser, or
/// with no word to them at all ([send] false).
typedef NotedAnswer = ({InviteResponse response, String note, bool send});

/// A new time proposed: Outlook's Propose New Time, as a tentative or a
/// declined answer with the time beside it.
typedef ProposedAnswer = ({
  InviteResponse response,
  TimeSpan proposal,
  String note,
});

/// Outlook's three ways an answer goes, as its Accept, Tentative and
/// Decline ask on the PC.
enum _How { sendNow, edit, quiet }

/// Asks how [response], to the meeting called [title], goes, as Outlook
/// does: Send the response now, Edit the response before sending (a
/// message to the organiser, asked for next), or Do not send a response.
///
/// A menu under [anchor], the button pressed; a dialog where there is
/// none, as when the answer began on a notification. [quietRefusal] says
/// why Do not send a response cannot be done here, which shows it greyed
/// with that line under it; null where it can. Null if backed out of.
Future<NotedAnswer?> askHowToAnswer(
  BuildContext context,
  InviteResponse response, {
  required String title,
  BuildContext? anchor,
  String? quietRefusal,
}) async {
  final named = title.trim().isEmpty ? '(No title)' : title.trim();
  final heading = '${_label(response)}: $named';
  final how = anchor != null
      ? await _menuUnder(anchor, quietRefusal)
      : await showDialog<_How>(
          context: context,
          builder: (context) => _HowDialog(
            heading: heading,
            quietRefusal: quietRefusal,
          ),
        );
  if (how == null || !context.mounted) return null;
  switch (how) {
    case _How.sendNow:
      return (response: response, note: '', send: true);
    case _How.quiet:
      return (response: response, note: '', send: false);
    case _How.edit:
      final note = await showDialog<String>(
        context: context,
        builder: (_) => _ResponseMessageDialog(heading: heading),
      );
      if (note == null) return null;
      return (response: response, note: note.trim(), send: true);
  }
}

/// The three as a menu dropping from [anchor], as Outlook's does from the
/// button.
Future<_How?> _menuUnder(BuildContext anchor, String? quietRefusal) {
  final button = anchor.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  final position = RelativeRect.fromRect(
    Rect.fromPoints(
      button.localToGlobal(button.size.bottomLeft(Offset.zero),
          ancestor: overlay),
      button.localToGlobal(button.size.bottomRight(Offset.zero),
          ancestor: overlay),
    ),
    Offset.zero & overlay.size,
  );
  return showMenu<_How>(
    context: anchor,
    position: position,
    items: [
      const PopupMenuItem(
        key: ValueKey('answer-now'),
        value: _How.sendNow,
        child: Text(_sendNow),
      ),
      const PopupMenuItem(
        key: ValueKey('answer-edit'),
        value: _How.edit,
        child: Text(_edit),
      ),
      PopupMenuItem(
        key: const ValueKey('answer-quiet'),
        value: _How.quiet,
        enabled: quietRefusal == null,
        child: _QuietLabel(refusal: quietRefusal),
      ),
    ],
  );
}

// Outlook's own words for them.
const _sendNow = 'Send the response now';
const _edit = 'Edit the response before sending';
const _quiet = 'Do not send a response';

/// Do not send a response, with why not under it where it cannot be done.
class _QuietLabel extends StatelessWidget {
  const _QuietLabel({this.refusal});

  final String? refusal;

  @override
  Widget build(BuildContext context) {
    final why = refusal;
    if (why == null) return const Text(_quiet);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(_quiet),
        // No colour of its own: the greyed one of the item around it.
        Text(why, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

/// The three as a dialog, for an answer with no button to drop them from.
class _HowDialog extends StatelessWidget {
  const _HowDialog({required this.heading, this.quietRefusal});

  final String heading;
  final String? quietRefusal;

  @override
  Widget build(BuildContext context) {
    void choose(_How how) => Navigator.of(context).pop(how);
    final quiet = quietRefusal == null;
    return SimpleDialog(
      title: Text(heading),
      children: [
        SimpleDialogOption(
          key: const ValueKey('answer-now'),
          onPressed: () => choose(_How.sendNow),
          child: const Text(_sendNow),
        ),
        SimpleDialogOption(
          key: const ValueKey('answer-edit'),
          onPressed: () => choose(_How.edit),
          child: const Text(_edit),
        ),
        SimpleDialogOption(
          key: const ValueKey('answer-quiet'),
          onPressed: quiet ? () => choose(_How.quiet) : null,
          child: quiet
              ? const Text(_quiet)
              : DefaultTextStyle.merge(
                  style: TextStyle(color: Theme.of(context).disabledColor),
                  child: _QuietLabel(refusal: quietRefusal),
                ),
        ),
      ],
    );
  }
}

/// Edit the response before sending: a message to the organiser, which
/// goes with the answer. Empty sends the answer alone. The message, or
/// null if backed out of.
class _ResponseMessageDialog extends StatefulWidget {
  const _ResponseMessageDialog({required this.heading});

  final String heading;

  @override
  State<_ResponseMessageDialog> createState() => _ResponseMessageDialogState();
}

class _ResponseMessageDialogState extends State<_ResponseMessageDialog> {
  final _message = TextEditingController();

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.heading),
        content: TextField(
          key: const ValueKey('answer-note'),
          controller: _message,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Message to the organiser',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('answer-send'),
            onPressed: () => Navigator.of(context).pop(_message.text),
            child: const Text('Send'),
          ),
        ],
      );
}

/// Asks for a new time for [invite], starting from the time it has. Null
/// if backed out of.
Future<ProposedAnswer?> askForProposal(
  BuildContext context,
  CalendarInvite invite,
) =>
    askForProposalAt(
      context,
      start: invite.start.toLocal(),
      end: invite.end?.toLocal() ??
          invite.start.toLocal().add(const Duration(hours: 1)),
    );

/// Asks for a new time for a meeting from [start] to [end], as it is now:
/// the same dialog, for a meeting on the calendar. Null if backed out of.
Future<ProposedAnswer?> askForProposalAt(
  BuildContext context, {
  required DateTime start,
  required DateTime end,
}) =>
    showDialog<ProposedAnswer>(
      context: context,
      builder: (_) => _ProposeDialog(start: start, end: end),
    );

class _ProposeDialog extends StatefulWidget {
  const _ProposeDialog({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  @override
  State<_ProposeDialog> createState() => _ProposeDialogState();
}

class _ProposeDialogState extends State<_ProposeDialog> {
  late DateTime _start = widget.start;
  late Duration _length = widget.end.isAfter(widget.start)
      ? widget.end.difference(widget.start)
      : const Duration(hours: 1);
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
