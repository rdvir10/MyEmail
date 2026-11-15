import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/device_calendar.dart'
    show FakeDeviceCalendar;
import 'package:myemail/data/calendar/phone_calendar.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/meeting_link.dart';
import 'package:myemail/state/calendar_providers.dart'
    show deviceCalendarProvider;
import 'package:myemail/state/calendar_view_providers.dart'
    show phoneCalendarProvider;
import 'package:myemail/state/meeting_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/settings/calendar_settings_screen.dart';

/// Saved meeting links (calendar idea #62): a room of Ron's own, his Zoom
/// room say, kept in Settings, Calendar, Meeting links for New meeting's
/// Online menu. What New meeting does with one is in
/// new_meeting_screen_test, and the backup's part in backup_test.
void main() {
  const room = MeetingLink(
    name: 'Zoom (my room)',
    url: 'https://zoom.us/j/1234567890',
  );
  const webex = MeetingLink(
    name: 'Webex',
    url: 'https://acme.webex.com/meet/ron',
  );

  group('a meeting link', () {
    test('is https alone; one typed without its scheme is taken as https',
        () {
      expect(meetingLinkUrlOf('https://zoom.us/j/1234567890?pwd=Xy12'),
          'https://zoom.us/j/1234567890?pwd=Xy12');
      expect(meetingLinkUrlOf('  zoom.us/j/1234567890 '),
          'https://zoom.us/j/1234567890');
      for (final refused in [
        'http://zoom.us/j/1234567890',
        'zoommtg://zoom.us/join?confno=1234567890',
        'javascript:alert(1)',
        'https://',
        'https:///j/1234567890',
        'https://zoom.us/j/123 456',
        'zoom',
        'my room',
        '',
      ]) {
        expect(meetingLinkUrlOf(refused), isNull, reason: refused);
      }
    });

    test('starts named for its service, by the host itself or as a '
        'dot-suffix, never a lookalike', () {
      expect(meetingServiceOf('https://zoom.us/j/1'), 'Zoom');
      expect(meetingServiceOf('https://us02web.zoom.us/j/1'), 'Zoom');
      expect(meetingServiceOf('https://acme.webex.com/meet/ron'), 'Webex');
      expect(meetingServiceOf('https://whereby.com/ron'), 'Whereby');
      expect(meetingServiceOf('https://teams.live.com/meet/9876'), 'Teams');
      // Not Zoom, whatever they hold.
      expect(meetingServiceOf('https://evilzoom.us/j/1'), 'evilzoom.us');
      expect(meetingServiceOf('https://zoom.us.example.com/j/1'),
          'zoom.us.example.com');
      // A service not known here is its host, less www.
      expect(meetingServiceOf('https://www.meet.example.org/ron'),
          'meet.example.org');
    });

    test('goes out as a line at the end of the notes, naming the service by '
        "the link's host and never Ron's own name for it", () {
      expect(room.line, 'Join the Zoom meeting: https://zoom.us/j/1234567890');
      expect(
        room.endOf('Bring the numbers.\n'),
        'Bring the numbers.\n\n'
        'Join the Zoom meeting: https://zoom.us/j/1234567890',
      );
      expect(room.endOf('  '), room.line);
      expect(webex.line,
          'Join the Webex meeting: https://acme.webex.com/meet/ron');
      // A host not known here, and a lookalike, name no service.
      expect(
        const MeetingLink(name: 'Zoom', url: 'https://meet.example.org/ron')
            .line,
        'Join the meeting: https://meet.example.org/ron',
      );
      expect(
        const MeetingLink(name: 'Zoom', url: 'https://evilzoom.us/j/1').line,
        'Join the meeting: https://evilzoom.us/j/1',
      );
      // What Ron calls it stays his.
      const personal = MeetingLink(
        name: 'Zoom (personal), for clients',
        url: 'https://us02web.zoom.us/j/555',
      );
      expect(personal.line,
          'Join the Zoom meeting: https://us02web.zoom.us/j/555');
      expect(personal.endOf('Notes'), isNot(contains('personal')));
    });

    test('goes once: notes that hold its line already, as a duplicate\'s '
        'do, are left as they are', () {
      final duplicated = 'Bring the numbers.\n\n${room.line}';
      expect(room.endOf(duplicated), duplicated);
      expect(room.endOf('${room.line}\nSee you there.'),
          '${room.line}\nSee you there.');
      // Another room's line is not this one's.
      expect(room.endOf(webex.line), '${webex.line}\n\n${room.line}');
    });

    test("a Google Meet room reads as Meet's own line does", () {
      expect(
        const MeetingLink(
                name: 'Meet', url: 'https://meet.google.com/abc-defg-hij')
            .line,
        'Join with Google Meet: https://meet.google.com/abc-defg-hij',
      );
    });

    test('is kept as text, and what is read back that is not one is left out',
        () {
      expect(MeetingLink.listFrom(MeetingLink.listToText([room, webex])),
          [room, webex]);
      expect(MeetingLink.listFrom(null), isEmpty);
      expect(MeetingLink.listFrom('{"not":"a list"}'), isEmpty);
      expect(MeetingLink.listFrom('not json'), isEmpty);
      final kept = jsonEncode(room.toJson());
      expect(
        MeetingLink.listFrom('[{"name":"Old","url":"http://zoom.us/j/9"},5,'
            '{"name":"","url":"https://zoom.us/j/8"},$kept,$kept]'),
        [const MeetingLink(name: 'Zoom', url: 'https://zoom.us/j/8'), room],
        reason: 'not https, not a link, a blank name named for its service, '
            'and the same link twice',
      );
    });
  });

  group('Settings, Calendar, Meeting links', () {
    late MemoryUiStateStore ui;

    setUp(() => ui = MemoryUiStateStore());

    Future<ProviderContainer> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(ui),
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
        deviceCalendarProvider.overrideWithValue(FakeDeviceCalendar()),
        phoneCalendarProvider.overrideWithValue(FakePhoneCalendar()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: CalendarSettingsScreen()),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    final link = find.byKey(const ValueKey('meeting-link-url'));
    final name = find.byKey(const ValueKey('meeting-link-name'));
    final save = find.byKey(const ValueKey('meeting-link-save'));
    final problem = find.byKey(const ValueKey('meeting-link-problem'));

    String typed(WidgetTester tester, Finder field) =>
        tester.widget<TextField>(field).controller!.text;

    /// [row], at the foot of the list, scrolled wholly into view.
    Future<void> reach(WidgetTester tester, Finder row) async {
      await tester.scrollUntilVisible(row, 200);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
    }

    testWidgets('one added is named for its service until Ron names it, and '
        'only an https link is taken', (tester) async {
      final c = await pump(tester);
      final add = find.byKey(const ValueKey('meeting-link-add'));
      await reach(tester, add);
      expect(find.text('Meeting links'), findsOneWidget);
      await tester.tap(add);
      await tester.pumpAndSettle();

      await tester.enterText(link, 'http://zoom.us/j/1234567890');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(problem, findsOneWidget);
      expect(c.read(meetingLinksProvider), isEmpty);

      await tester.enterText(link, 'https://zoom.us/j/1234567890');
      await tester.pump();
      expect(typed(tester, name), 'Zoom');
      await tester.enterText(name, 'Zoom (my room)');
      // Named by Ron, it no longer follows the link.
      await tester.enterText(link, 'zoom.us/j/1234567890');
      await tester.pump();
      expect(typed(tester, name), 'Zoom (my room)');
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(c.read(meetingLinksProvider), const [room]);
      expect(MeetingLink.listFrom(ui.readString(UiStateKeys.meetingLinks)),
          const [room]);
      expect(find.text('Zoom (my room)'), findsOneWidget);
      expect(find.text('zoom.us'), findsOneWidget,
          reason: 'the host, not the whole link, which lets anyone in');
      expect(find.textContaining('1234567890'), findsNothing);
    });

    testWidgets('one tapped is changed where it is, the same link twice is '
        'refused, and the bin takes one off', (tester) async {
      await ui.writeString(
          UiStateKeys.meetingLinks, MeetingLink.listToText([room, webex]));
      final c = await pump(tester);
      final row = find.byKey(ValueKey('meeting-link:${room.url}'));
      await reach(tester, row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(typed(tester, link), room.url);
      expect(typed(tester, name), room.name);

      await tester.enterText(link, webex.url);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(problem, findsOneWidget);

      await tester.enterText(link, 'https://zoom.us/j/5550001111');
      await tester.enterText(name, 'Zoom (team room)');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(c.read(meetingLinksProvider), const [
        MeetingLink(
          name: 'Zoom (team room)',
          url: 'https://zoom.us/j/5550001111',
        ),
        webex,
      ]);

      final bin = find.byKey(ValueKey('meeting-link-remove:${webex.url}'));
      await reach(tester, bin);
      await tester.tap(bin);
      await tester.pumpAndSettle();
      expect(c.read(meetingLinksProvider).map((l) => l.name),
          ['Zoom (team room)']);
      expect(find.text('Webex'), findsNothing);
    });
  });
}
