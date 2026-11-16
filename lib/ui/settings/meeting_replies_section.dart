import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/calendar_prefs.dart';
import '../../state/calendar_view_providers.dart' show calendarPrefsProvider;
import '../../state/sync_providers.dart' show syncSettingsProvider;

/// Settings, Calendar: replies to your meetings filed away by themselves
/// (calendar idea #52), and, once that is on, whether a decline stays.
/// Off until Ron turns it on.
class MeetingRepliesSection extends ConsumerWidget {
  const MeetingRepliesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(calendarPrefsProvider);
    final set = ref.read(calendarPrefsProvider.notifier).set;
    final filing = prefs.replyFiling;
    // Only the background checks file replies: the app's own sync never
    // does (#52's review). Said while they are off.
    final checksOff = ref.watch(syncSettingsProvider).value?.syncs == false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('calendar-file-replies'),
          title: const Text('File replies to your meetings'),
          subtitle: Text(
            'An Accepted, Maybe or Declined with nothing written in it goes '
            'to Deleted Items as it arrives, with no notification. One with '
            'a message, or a new time, stays in the Inbox. Done when MyEmail '
            'checks for mail.'
            '${checksOff ? ' Settings → Sync is set to Only when I open '
                'MyEmail, so nothing is filed until that changes.' : ''}',
          ),
          value: filing != ReplyFiling.off,
          onChanged: (on) => set(prefs.copyWith(
            replyFiling: on ? ReplyFiling.all : ReplyFiling.off,
          )),
        ),
        if (filing != ReplyFiling.off)
          SwitchListTile(
            key: const ValueKey('calendar-keep-declines'),
            title: const Text('Keep declines in the Inbox'),
            subtitle: const Text(
              'A Declined stays, and you are told of it, even with nothing '
              'written in it.',
            ),
            value: filing == ReplyFiling.keepDeclines,
            onChanged: (on) => set(prefs.copyWith(
              replyFiling: on ? ReplyFiling.keepDeclines : ReplyFiling.all,
            )),
          ),
      ],
    );
  }
}
