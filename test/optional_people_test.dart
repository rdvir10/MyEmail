import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:myemail/data/calendar/device_calendar.dart';
import 'package:myemail/data/calendar/google_calendar_api.dart';
import 'package:myemail/data/contacts/device_contacts.dart';
import 'package:myemail/data/graph/graph_calendar_api.dart';
import 'package:myemail/data/sample/sample_mail_engine.dart';
import 'package:myemail/data/ui_state_store.dart';
import 'package:myemail/domain/account.dart';
import 'package:myemail/domain/calendar_change.dart';
import 'package:myemail/domain/calendar_event.dart';
import 'package:myemail/domain/calendar_invite.dart';
import 'package:myemail/domain/mail_message.dart';
import 'package:myemail/domain/meeting.dart';
import 'package:myemail/state/calendar_providers.dart';
import 'package:myemail/state/contact_providers.dart';
import 'package:myemail/state/providers.dart';
import 'package:myemail/ui/calendar/event_actions.dart' show duplicateEvent;
import 'package:myemail/ui/compose/header_fields.dart';
import 'package:myemail/ui/meetings/new_meeting_screen.dart';

import 'fakes/fake_webview.dart';

/// Optional people (calendar idea #56): a person's bubble on New meeting
/// or Edit is made optional from its menu, drawn fainter, and Outlook and
/// Google are told; a reply or a change of something else leaves them so.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  const dana = MailAddress(email: 'dana@example.com', name: 'Dana Levi');
  const yossi = MailAddress(email: 'yossi@example.com', name: 'Yossi Cohen');

  http.Response json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});

  Map<String, Object?> bodyOf(http.Request r) =>
      (jsonDecode(r.body) as Map).cast<String, Object?>();

  MeetingDraft draft({Set<String> optional = const {}}) => MeetingDraft(
        accountId: 'a',
        title: 'Q3 review',
        attendees: const [dana, yossi],
        optional: optional,
        start: DateTime(2026, 10, 1, 9),
        end: DateTime(2026, 10, 1, 10),
        timeZone: 'Asia/Jerusalem',
      );

  CalendarEvent meeting({List<EventAttendee>? attendees}) => CalendarEvent(
        id: 'm1',
        accountId: 'acct-ms',
        title: 'Q3 review',
        start: DateTime(2026, 10, 1, 9),
        end: DateTime(2026, 10, 1, 10),
        isOrganizer: true,
        response: EventResponse.organizer,
        attendees: attendees ??
            const [
              EventAttendee(dana, response: EventResponse.accepted),
              EventAttendee(yossi,
                  response: EventResponse.tentative, optional: true),
            ],
      );

  group('the meeting', () {
    test('who is optional is part of what it is', () {
      expect(draft().sameMeetingAs(draft(optional: {'dana@example.com'})),
          isFalse);
      expect(draft(optional: {'dana@example.com'}).isOptional(dana), isTrue);
      expect(
        draft(optional: {'dana@example.com'})
            .isOptional(const MailAddress(email: ' Dana@Example.com ')),
        isTrue,
        reason: 'addresses come in any case',
      );
      expect(draft().isOptional(dana), isFalse);
    });

    test('a change of who is optional alone is a change of the people', () {
      final before = meeting();
      const notes = EventNotes(text: '');
      EventChange change(Set<String> optional) => EventChange.between(
            before,
            notesBefore: notes,
            title: 'Q3 review',
            start: before.start,
            end: before.end,
            allDay: false,
            location: '',
            notes: '',
            attendees: const [dana, yossi],
            optional: optional,
          );
      expect(change({'yossi@example.com'}).isEmpty, isTrue,
          reason: 'as it was');
      final swapped = change({'dana@example.com'});
      expect(swapped.onlyPeople, isTrue);
      expect(swapped.attendees, const [dana, yossi]);
      expect(swapped.optional, {'dana@example.com'});
    });
  });

  group('on a Microsoft calendar', () {
    late List<http.Request> sent;

    GraphCalendarApi api([http.Response Function(http.Request)? answer]) {
      sent = [];
      return GraphCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          return answer?.call(request) ?? json({'id': 'e1'});
        }),
        sleep: (_) async {},
      );
    }

    test('a new meeting asks each as chosen: optional, or required', () {
      final body = GraphCalendarApi.eventJson(
          draft(optional: {'yossi@example.com'}));
      expect(body['attendees'], [
        {
          'emailAddress': {'address': 'dana@example.com', 'name': 'Dana Levi'},
          'type': 'required',
        },
        {
          'emailAddress': {
            'address': 'yossi@example.com',
            'name': 'Yossi Cohen',
          },
          'type': 'optional',
        },
      ]);
    });

    test('a meeting whose link was made ahead is sent its people as chosen '
        'too', () async {
      await api((r) => json({
            'id': 'e1',
            'isOnlineMeeting': true,
            'onlineMeeting': {'joinUrl': 'https://teams.microsoft.com/l/x'},
          })).sendShell(
        const PreparedMeeting(
          accountId: 'a',
          kind: OnlineMeetingKind.teams,
          eventId: 'e1',
          joinUrl: 'https://teams.microsoft.com/l/x',
          inviteText: 'Microsoft Teams meeting',
          bodyHtml: '<html><body>Teams</body></html>',
        ),
        draft(optional: {'dana@example.com'}),
      );
      expect(bodyOf(sent.last)['attendees'], [
        {
          'emailAddress': {'address': 'dana@example.com', 'name': 'Dana Levi'},
          'type': 'optional',
        },
        {
          'emailAddress': {
            'address': 'yossi@example.com',
            'name': 'Yossi Cohen',
          },
          'type': 'required',
        },
      ]);
    });

    test('an edit sends who is optional as the screen has it', () async {
      final graph = api((r) => r.method == 'GET'
          ? json({
              'id': 'm1',
              'attendees': [
                {
                  'type': 'required',
                  'emailAddress': {'address': 'dana@example.com'},
                },
                {
                  'type': 'optional',
                  'emailAddress': {'address': 'yossi@example.com'},
                },
              ],
            })
          : json({}));
      await graph.update(
        'm1',
        const EventChange(
          attendees: [dana, yossi],
          optional: {'dana@example.com'},
        ),
        before: meeting(),
      );
      expect(bodyOf(sent.last)['attendees'], [
        {
          'emailAddress': {'address': 'dana@example.com', 'name': 'Dana Levi'},
          'type': 'optional',
        },
        {
          'emailAddress': {
            'address': 'yossi@example.com',
            'name': 'Yossi Cohen',
          },
          'type': 'required',
        },
      ]);
    });

    test('a change that does not say, Invite people, leaves each as they '
        'were', () {
      final body = GraphCalendarApi.changeJson(
        const EventChange(attendees: [
          dana,
          yossi,
          MailAddress(email: 'new@example.com'),
        ]),
        before: meeting(),
      );
      expect([for (final a in body['attendees']! as List) (a as Map)['type']],
          ['required', 'optional', 'required']);
    });
  });

  group('on a Google calendar', () {
    late List<http.Request> sent;

    GoogleCalendarApi api(Map<String, Object?> event) {
      sent = [];
      return GoogleCalendarApi(
        accessToken: ({bool force = false}) async => 'token',
        httpClient: http_testing.MockClient((request) async {
          sent.add(request);
          if (request.method == 'GET') return json(event);
          return json({});
        }),
        sleep: (_) async {},
      );
    }

    test('a new meeting marks the optional ones, and only them', () {
      final body = GoogleCalendarApi.eventJson(
          draft(optional: {'yossi@example.com'}));
      expect(body['attendees'], [
        {'email': 'dana@example.com', 'displayName': 'Dana Levi'},
        {
          'email': 'yossi@example.com',
          'displayName': 'Yossi Cohen',
          'optional': true,
        },
      ]);
    });

    test('an edit changes who is optional and keeps everyone\'s answer',
        () async {
      final own = {
        'id': 'g1',
        'attendees': [
          {
            'email': 'me@gmail.example',
            'organizer': true,
            'self': true,
            'responseStatus': 'accepted',
          },
          {'email': 'dana@example.com', 'responseStatus': 'accepted'},
          {
            'email': 'yossi@example.com',
            'optional': true,
            'responseStatus': 'tentative',
          },
        ],
      };
      await api(own).update(
        'g1',
        const EventChange(
          attendees: [dana, yossi, MailAddress(email: 'new@example.com')],
          optional: {'dana@example.com', 'new@example.com'},
        ),
        before: meeting(),
      );
      expect(bodyOf(sent.last)['attendees'], [
        {
          'email': 'me@gmail.example',
          'organizer': true,
          'self': true,
          'responseStatus': 'accepted',
        },
        {
          'email': 'dana@example.com',
          'responseStatus': 'accepted',
          'optional': true,
        },
        {
          'email': 'yossi@example.com',
          'optional': false,
          'responseStatus': 'tentative',
        },
        {'email': 'new@example.com', 'optional': true},
      ]);
    });

    test('only those whose optional Ron changed are marked or unmarked: one '
        'made optional in Google Calendar since the phone read the meeting '
        'is not set back', () {
      final merged = GoogleCalendarApi.mergedAttendees(
        [
          // Dana made optional in Google Calendar; the phone's copy has
          // her required, and Edit left her so.
          {'email': 'dana@example.com', 'optional': true},
          {'email': 'yossi@example.com', 'optional': true},
        ],
        const [dana, yossi],
        before: meeting(),
        // Yossi made required on the screen; Dana untouched there.
        optional: const {},
      );
      expect(merged, [
        {'email': 'dana@example.com', 'optional': true},
        {'email': 'yossi@example.com', 'optional': false},
      ]);
    });

    test('a change that does not say, Invite people, leaves each as they '
        'were', () {
      final merged = GoogleCalendarApi.mergedAttendees(
        [
          {'email': 'yossi@example.com', 'optional': true},
        ],
        const [yossi, MailAddress(email: 'new@example.com')],
        before: meeting(),
      );
      expect(merged, [
        {'email': 'yossi@example.com', 'optional': true},
        {'email': 'new@example.com'},
      ]);
    });

    test("an answer to someone else's meeting leaves who is optional as it "
        'was', () {
      final answered = GoogleCalendarApi.answeredAttendees(
        {
          'attendees': [
            {'email': 'dana@example.com', 'organizer': true},
            {'email': 'me@gmail.example', 'self': true, 'optional': true},
            {'email': 'yossi@example.com', 'optional': true},
          ],
        },
        InviteResponse.accepted,
      )!;
      expect(answered[1]['optional'], isTrue);
      expect(answered[2]['optional'], isTrue);
    });
  });

  group('the bubble', () {
    Future<ValueNotifier<Set<String>>?> pump(
      WidgetTester tester, {
      bool meeting = true,
    }) async {
      final optional = meeting ? ValueNotifier<Set<String>>({}) : null;
      final line = TextEditingController(
          text: 'Dana Levi <dana@example.com>, '
              'Yossi Cohen <yossi@example.com>');
      addTearDown(line.dispose);
      final c = ProviderContainer(overrides: [
        mailEngineProvider.overrideWithValue(SampleMailEngine()),
        deviceContactsProvider.overrideWithValue(FakeDeviceContacts()),
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: RecipientField(
              label: 'Attendees',
              controller: line,
              enabled: true,
              optional: optional,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return optional;
    }

    Future<void> menu(WidgetTester tester, String person, String item) async {
      await tester.tap(find.text(person));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item).last);
      await tester.pumpAndSettle();
    }

    /// What [person]'s bubble is filled with and written in.
    ({Color? fill, Color? ink}) look(WidgetTester tester, String person) {
      final fill = tester
          .widget<Material>(find
              .ancestor(of: find.text(person), matching: find.byType(Material))
              .first)
          .color;
      final ink = tester.widget<Text>(find.text(person)).style?.color;
      return (fill: fill, ink: ink);
    }

    testWidgets('its menu makes a person optional, and required again; the '
        'bubble is drawn fainter and says so', (tester) async {
      final semantics = tester.ensureSemantics();
      final optional = (await pump(tester))!;
      final before = look(tester, 'Dana Levi');

      await menu(tester, 'Dana Levi', 'Optional');
      expect(optional.value, {'dana@example.com'});
      final after = look(tester, 'Dana Levi');
      expect(after.fill, isNot(before.fill));
      expect(after.ink, isNot(before.ink));
      expect(look(tester, 'Yossi Cohen'), before, reason: 'still required');
      expect(find.bySemanticsLabel(RegExp(r'Dana Levi, optional')),
          findsOneWidget);

      // Fainter, but still to be read: against what is under it.
      final scheme = Theme.of(tester.element(find.text('Dana Levi')))
          .colorScheme;
      final ground = after.fill == null || after.fill!.a == 0
          ? scheme.surface
          : Color.alphaBlend(after.fill!, scheme.surface);
      expect(_contrast(after.ink!, ground), greaterThanOrEqualTo(4.5));

      await menu(tester, 'Dana Levi', 'Required');
      expect(optional.value, isEmpty);
      expect(look(tester, 'Dana Levi'), before);
      semantics.dispose();
    });

    testWidgets('one taken off the line is no longer optional', (tester) async {
      final optional = (await pump(tester))!;
      await menu(tester, 'Dana Levi', 'Optional');
      await menu(tester, 'Dana Levi', 'Remove');
      expect(optional.value, isEmpty);
    });

    testWidgets("a message's lines have no such choice", (tester) async {
      await pump(tester, meeting: false);
      await tester.tap(find.text('Dana Levi'));
      await tester.pumpAndSettle();
      expect(find.text('Optional'), findsNothing);
      expect(find.text('Remove'), findsOneWidget);
    });
  });

  group('New meeting and Edit', () {
    late _Microsoft engine;

    setUp(() => engine = _Microsoft());

    Future<void> pumpScreen(WidgetTester tester, {EventEdit? editing}) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        deviceContactsProvider.overrideWithValue(FakeDeviceContacts()),
        deviceCalendarProvider.overrideWithValue(
            FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      ]);
      addTearDown(c.dispose);
      // Over a page of its own, as it is opened, so that it has somewhere
      // to close to and the bar along the bottom somewhere to be said.
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NewMeetingScreen(
                      accountId: 'acct-ms',
                      start: DateTime(2026, 10, 1, 9),
                      editing: editing,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Finder field(String key) => find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(TextField),
          matchRoot: true,
        );

    Future<void> menu(WidgetTester tester, String person, String item) async {
      await tester.tap(find.text(person));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item).last);
      await tester.pumpAndSettle();
    }

    testWidgets('a person made optional on New meeting is sent so',
        (tester) async {
      await pumpScreen(tester);
      await tester.enterText(field('meeting-title'), 'Q3 review');
      await tester.enterText(field('meeting-attendees'),
          'Dana Levi <dana@example.com>, Yossi Cohen <yossi@example.com>, ');
      await tester.pumpAndSettle();
      await menu(tester, 'Yossi Cohen', 'Optional');

      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      final m = engine.meetings.single;
      expect(m.attendees.map((a) => a.email),
          ['dana@example.com', 'yossi@example.com']);
      expect(m.optional, {'yossi@example.com'});
    });

    testWidgets('with nobody made optional, everyone is asked as before',
        (tester) async {
      await pumpScreen(tester);
      await tester.enterText(field('meeting-title'), 'Q3 review');
      await tester.enterText(
          field('meeting-attendees'), 'Dana Levi <dana@example.com>, ');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(engine.meetings.single.optional, isEmpty);
    });

    testWidgets('Edit starts with those optional as the calendar has them, '
        'and Save sends a change of it', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpScreen(tester,
          editing: EventEdit(
              event: meeting(), notes: const EventNotes(text: '')));
      expect(find.bySemanticsLabel(RegExp(r'Yossi Cohen, optional')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'Dana Levi, optional')),
          findsNothing);

      await menu(tester, 'Yossi Cohen', 'Required');
      await menu(tester, 'Dana Levi', 'Optional');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      expect(engine.calendarActions.single,
          contains('optional=dana@example.com'));
      expect(find.text('Saved. Everyone on it is sent the change.'),
          findsOneWidget);
      semantics.dispose();
    });

    testWidgets('Duplicate opens with the same people optional',
        (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ProviderContainer(overrides: [
        uiStateStoreProvider.overrideWithValue(MemoryUiStateStore()),
        mailEngineProvider.overrideWithValue(engine),
        deviceContactsProvider.overrideWithValue(FakeDeviceContacts()),
        deviceCalendarProvider.overrideWithValue(
            FakeDeviceCalendar(timeZone: 'Asia/Jerusalem')),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => duplicateEvent(context, ref, meeting()),
                child: const Text('duplicate'),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('duplicate'));
      await tester.pumpAndSettle();

      expect(find.byType(NewMeetingScreen), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'Yossi Cohen, optional')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'Dana Levi, optional')),
          findsNothing);
      await tester.enterText(field('meeting-title'), 'Q3 review again');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(engine.meetings.single.optional, {'yossi@example.com'});
      semantics.dispose();
    });

    testWidgets('Edit with who is optional left alone changes nothing',
        (tester) async {
      await pumpScreen(tester,
          editing: EventEdit(
              event: meeting(), notes: const EventNotes(text: '')));
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(engine.calendarActions, isEmpty);
      expect(find.text('Nothing was changed.'), findsOneWidget);
    });
  });
}

/// The WCAG contrast ratio of [a] on [b].
double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// An engine with one Microsoft account, whose calendar holds meetings.
class _Microsoft extends SampleMailEngine {
  @override
  Future<List<Account>> loadAccounts() async => const [
        Account(
          id: 'acct-ms',
          displayName: 'Work',
          emailAddress: 'ron@contoso.com',
          provider: MailProvider.outlook,
          authMethod: AuthMethod.oauth,
          colorValue: 0xFF0F6CBD,
        ),
      ];
}
