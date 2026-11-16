import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/state/meeting_alert_providers.dart'
    show meetingClockProvider;
import 'package:myemail/ui/calendar/meeting_ticker.dart';

/// The shared clock of what is said about meetings: the next meeting's
/// "in 13 min", the Agenda's Now, the grid's now line and the mail's
/// calendar button. Right the moment the app comes back, not up to a tick
/// later: with the screen off overnight its timer runs on the phone's
/// awake time, and the morning could show yesterday for half a minute.
void main() {
  late DateTime clock;
  late List<DateTime> told;

  Future<void> pump(WidgetTester tester) async {
    clock = DateTime(2026, 11, 17, 23, 59, 50);
    told = [];
    await tester.pumpWidget(ProviderScope(
      overrides: [meetingClockProvider.overrideWithValue(() => clock)],
      child: MeetingTicker(builder: (context, ref, now) {
        told.add(now);
        return const SizedBox();
      }),
    ));
  }

  void goAway(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void comeBack(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  testWidgets('after a resume it tells its listeners once, at once',
      (tester) async {
    await pump(tester);
    expect(told, [DateTime(2026, 11, 17, 23, 59, 50)]);

    goAway(tester);
    await tester.pump();
    clock = DateTime(2026, 11, 18, 7, 30);
    comeBack(tester);
    // The next frame, with no time passed: not the next tick.
    await tester.pump();
    expect(told, [
      DateTime(2026, 11, 17, 23, 59, 50),
      DateTime(2026, 11, 18, 7, 30),
    ]);
    await tester.pump();
    expect(told, hasLength(2), reason: 'once');

    // And the ticks go on as before.
    clock = DateTime(2026, 11, 18, 7, 30, 30);
    await tester.pump(MeetingTicker.tick);
    expect(told.last, DateTime(2026, 11, 18, 7, 30, 30));
  });

  testWidgets('nothing is left listening after it has gone', (tester) async {
    await pump(tester);
    await tester.pumpWidget(const SizedBox());
    final before = told.length;

    goAway(tester);
    comeBack(tester);
    await tester.pump(MeetingTicker.tick * 2);

    expect(tester.takeException(), isNull);
    expect(told, hasLength(before));
  });
}
