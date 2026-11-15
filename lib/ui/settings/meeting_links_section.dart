import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/meeting_link.dart';
import '../../state/meeting_providers.dart';

/// Settings, Calendar, Meeting links: rooms of Ron's own, his Zoom room
/// say, for New meeting's Online menu (calendar idea #62). Each is named
/// and changed here; a tap changes one, the bin takes it off.
///
/// Only the host shows in the list: the whole link lets anyone in.
class MeetingLinksSection extends ConsumerWidget {
  const MeetingLinksSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final links = ref.watch(meetingLinksProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
          child: Text(
            'Meeting links',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            "Your own room, your Zoom room say, for New meeting's Online "
            'menu: its link goes in the place and at the end of the notes, '
            'as "Join the Zoom meeting". The name is for you alone: an '
            'invitation never shows it. Anyone with the link can come in, '
            'so a backup has it only with sign-in details.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        for (final l in links)
          ListTile(
            key: ValueKey('meeting-link:${l.url}'),
            leading: const Icon(Icons.videocam_outlined),
            title: Text(l.name),
            subtitle: Text(
              Uri.tryParse(l.url)?.host ?? '',
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _edit(context, ref, l),
            trailing: IconButton(
              key: ValueKey('meeting-link-remove:${l.url}'),
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  ref.read(meetingLinksProvider.notifier).remove(l),
            ),
          ),
        ListTile(
          key: const ValueKey('meeting-link-add'),
          leading: const Icon(Icons.add_link),
          title: const Text('Add a meeting link'),
          onTap: () => _edit(context, ref, null),
        ),
        // The foot of Settings, Calendar.
        const SizedBox(height: 24),
      ],
    );
  }

  /// A new link, or [link] changed, as the dialog gives it back.
  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    MeetingLink? link,
  ) async {
    final others = [
      for (final l in ref.read(meetingLinksProvider))
        if (l != link) l,
    ];
    final kept = await showDialog<MeetingLink>(
      context: context,
      builder: (_) => _MeetingLinkDialog(editing: link, others: others),
    );
    if (kept == null || !context.mounted) return;
    final links = ref.read(meetingLinksProvider.notifier);
    if (link == null) {
      links.add(kept);
    } else {
      links.replace(link, kept);
    }
  }
}

/// A link and its name. The name starts as the service's, taken from the
/// link's host, and follows the link until Ron types one of his own.
class _MeetingLinkDialog extends StatefulWidget {
  const _MeetingLinkDialog({required this.editing, required this.others});

  /// The link being changed, or null for a new one.
  final MeetingLink? editing;

  /// The links kept besides it: the same link twice is refused.
  final List<MeetingLink> others;

  @override
  State<_MeetingLinkDialog> createState() => _MeetingLinkDialogState();
}

class _MeetingLinkDialogState extends State<_MeetingLinkDialog> {
  late final _link = TextEditingController(text: widget.editing?.url);
  late final _name = TextEditingController(text: widget.editing?.name);

  /// Whether the name is Ron's own, typed or kept from before, rather than
  /// the service's: until it is, it follows the link.
  late bool _named = widget.editing != null;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _link.addListener(_follow);
  }

  @override
  void dispose() {
    _link.dispose();
    _name.dispose();
    super.dispose();
  }

  void _follow() {
    if (_named) return;
    final url = meetingLinkUrlOf(_link.text);
    final service = url == null ? '' : meetingServiceOf(url);
    if (_name.text != service) _name.text = service;
  }

  void _save() {
    final url = meetingLinkUrlOf(_link.text);
    if (url == null) {
      setState(() => _problem = 'Only an https:// link can be kept.');
      return;
    }
    if (widget.others.any((l) => l.url == url)) {
      setState(() => _problem = 'That link is kept already.');
      return;
    }
    final name = _name.text.trim();
    Navigator.of(context).pop(MeetingLink(
      name: name.isEmpty ? meetingServiceOf(url) : name,
      url: url,
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
          widget.editing == null ? 'Add a meeting link' : 'Meeting link',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('meeting-link-url'),
              controller: _link,
              autofocus: widget.editing == null,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Link',
                hintText: 'https://zoom.us/j/…',
              ),
            ),
            TextField(
              key: const ValueKey('meeting-link-name'),
              controller: _name,
              onChanged: (_) => _named = true,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Zoom (my room)',
              ),
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _problem!,
                  key: const ValueKey('meeting-link-problem'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('meeting-link-save'),
            onPressed: _save,
            child: Text(widget.editing == null ? 'Add' : 'Save'),
          ),
        ],
      );
}
