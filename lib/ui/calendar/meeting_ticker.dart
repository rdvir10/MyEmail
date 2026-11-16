import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/meeting_alert_providers.dart' show meetingClockProvider;

/// The time, as what is said about meetings sees it ([meetingClockProvider],
/// a test's own clock in a test), looked at again every [tick] while
/// [builder]'s part of the screen is up, and that part alone built again
/// with it; and at once when the app comes back to the front. The timer
/// runs on the phone's awake time, so after a night with the screen off
/// the morning could show yesterday until the next tick.
///
/// What moves the next meeting's "in 13 min" along over the mail, and the
/// Agenda's finished meetings and "Now" (calendar idea #91), the grid's
/// now line, and the date on the mail's calendar button (#98). [builder]
/// has a ref of its own: what it watches is watched by the part built
/// again.
class MeetingTicker extends ConsumerStatefulWidget {
  const MeetingTicker({super.key, required this.builder});

  /// How often the time is looked at again.
  static const tick = Duration(seconds: 30);

  final Widget Function(BuildContext context, WidgetRef ref, DateTime now)
      builder;

  @override
  ConsumerState<MeetingTicker> createState() => _MeetingTickerState();
}

class _MeetingTickerState extends ConsumerState<MeetingTicker> {
  Timer? _ticking;
  AppLifecycleListener? _back;

  @override
  void initState() {
    super.initState();
    _ticking = Timer.periodic(MeetingTicker.tick, (_) {
      if (mounted) setState(() {});
    });
    // Goes with this state in dispose, so it never finds the state gone.
    _back = AppLifecycleListener(onResume: () => setState(() {}));
  }

  @override
  void dispose() {
    _ticking?.cancel();
    _back?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, ref, ref.watch(meetingClockProvider)());
}
