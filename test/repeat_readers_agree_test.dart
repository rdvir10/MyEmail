import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/domain/meeting_repeat.dart';
import 'package:myemail/domain/series_repeat.dart';

/// A series' repeat is read twice: by the meeting's sheet, to say it
/// ([MeetingRepeat], calendar idea #44), and by Edit, to change it
/// ([SeriesRepeat], #55). The sheet says more series than Edit can change,
/// but the two must never disagree: where Edit shows a repeat, it is the
/// sheet's sentence word for word, and where the sheet can say nothing,
/// Edit shows nothing either.
void main() {
  Map<String, Object?> graph(
    Map<String, Object?> pattern, {
    Map<String, Object?>? range,
  }) =>
      {
        'pattern': pattern,
        'range': range ??
            {
              'type': 'noEnd',
              'startDate': '2026-09-01',
              'recurrenceTimeZone': 'Eastern Standard Time',
            },
      };

  Map<String, Object?> weekly(List<String> days, {Object? interval = 1}) => {
        'type': 'weekly',
        'interval': interval,
        'daysOfWeek': days,
        'firstDayOfWeek': 'sunday',
      };

  // 1 September 2026 is a Tuesday, the month's first.
  final graphSeries = <String, Map<String, Object?>>{
    'weekly, one day': graph(weekly(['tuesday'])),
    'weekly, two days': graph(weekly(['tuesday', 'thursday'])),
    'weekly, Sunday and Tuesday': graph(weekly(['sunday', 'tuesday'])),
    'weekly, the working days': graph(
        weekly(['monday', 'tuesday', 'wednesday', 'thursday', 'friday'])),
    'weekly, Sunday to Thursday': graph(weekly(
        ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday'])),
    'weekly, all seven': graph(weekly([
      'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday',
      'sunday',
    ])),
    'every 2 weeks': graph(weekly(['tuesday'], interval: 2)),
    'every 3 weeks': graph(weekly(['tuesday'], interval: 3)),
    'an interval that is no whole number':
        graph(weekly(['tuesday'], interval: 1.5)),
    'an interval written as text': graph(weekly(['tuesday'], interval: '2')),
    'daily': graph({'type': 'daily', 'interval': 1}),
    'every 2 days': graph({'type': 'daily', 'interval': 2}),
    'monthly on its own date':
        graph({'type': 'absoluteMonthly', 'interval': 1, 'dayOfMonth': 1}),
    'monthly on another date':
        graph({'type': 'absoluteMonthly', 'interval': 1, 'dayOfMonth': 15}),
    'every 3 months':
        graph({'type': 'absoluteMonthly', 'interval': 3, 'dayOfMonth': 1}),
    'monthly on the first Tuesday': graph({
      'type': 'relativeMonthly',
      'interval': 1,
      'daysOfWeek': ['tuesday'],
      'index': 'first',
    }),
    'monthly on the last Friday': graph({
      'type': 'relativeMonthly',
      'interval': 1,
      'daysOfWeek': ['friday'],
      'index': 'last',
    }),
    'yearly on its own date': graph({
      'type': 'absoluteYearly',
      'interval': 1,
      'dayOfMonth': 1,
      'month': 9,
    }),
    'yearly on a weekday': graph({
      'type': 'relativeYearly',
      'interval': 1,
      'daysOfWeek': ['tuesday'],
      'index': 'first',
      'month': 9,
    }),
    'until a day': graph(weekly(['tuesday']), range: {
      'type': 'endDate',
      'startDate': '2026-09-01',
      'endDate': '2027-06-29',
      'recurrenceTimeZone': 'Eastern Standard Time',
    }),
    'a number of times': graph(weekly(['tuesday']), range: {
      'type': 'numbered',
      'startDate': '2026-09-01',
      'numberOfOccurrences': 12,
      'recurrenceTimeZone': 'Eastern Standard Time',
    }),
    'a range of a kind not known': graph(weekly(['tuesday']), range: {
      'type': 'somethingNew',
      'startDate': '2026-09-01',
    }),
    'no range': {'pattern': weekly(['tuesday'])},
    'no pattern': {
      'range': {'type': 'noEnd', 'startDate': '2026-09-01'},
    },
    'a pattern of a kind not known': graph({'type': 'hourly', 'interval': 1}),
    'no days': graph(weekly(const [])),
  };

  Map<String, Object?> google(List<Object?> lines, {bool allDay = false}) => {
        'start': allDay
            ? {'date': '2026-09-01'}
            : {
                'dateTime': '2026-09-01T09:00:00-04:00',
                'timeZone': 'America/New_York',
              },
        'end': allDay
            ? {'date': '2026-09-02'}
            : {
                'dateTime': '2026-09-01T10:00:00-04:00',
                'timeZone': 'America/New_York',
              },
        'recurrence': lines,
      };

  final googleSeries = <String, Map<String, Object?>>{
    'weekly, its own day': google(['RRULE:FREQ=WEEKLY']),
    'weekly, one day': google(['RRULE:FREQ=WEEKLY;BYDAY=TU']),
    'weekly, two days': google(['RRULE:FREQ=WEEKLY;BYDAY=TU,TH']),
    'weekly, Sunday and Tuesday': google(['RRULE:FREQ=WEEKLY;BYDAY=SU,TU']),
    'weekly, the working days':
        google(['RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR']),
    'weekly, all seven':
        google(['RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU']),
    'every 2 weeks': google(['RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU']),
    'every 2 weeks, counted from Sunday':
        google(['RRULE:FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU']),
    'every 3 weeks': google(['RRULE:FREQ=WEEKLY;INTERVAL=3;BYDAY=TU']),
    'daily': google(['RRULE:FREQ=DAILY']),
    'every 2 days': google(['RRULE:FREQ=DAILY;INTERVAL=2']),
    'monthly on its own date': google(['RRULE:FREQ=MONTHLY']),
    'monthly on another date': google(['RRULE:FREQ=MONTHLY;BYMONTHDAY=15']),
    'monthly on the first Tuesday': google(['RRULE:FREQ=MONTHLY;BYDAY=1TU']),
    'monthly on the last Friday': google(['RRULE:FREQ=MONTHLY;BYDAY=-1FR']),
    'yearly': google(['RRULE:FREQ=YEARLY']),
    'until a day, written in UTC':
        google(['RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20270630T035959Z']),
    'until a day, all day':
        google(['RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20270629'], allDay: true),
    'a number of times': google(['RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=12']),
    'with a day left out': google([
      'EXDATE;TZID=America/New_York:20261006T090000',
      'RRULE:FREQ=WEEKLY;BYDAY=TU',
    ]),
    'with a day added': google([
      'RRULE:FREQ=WEEKLY;BYDAY=TU',
      'RDATE;TZID=America/New_York:20261007T090000',
    ]),
    'two rules': google([
      'RRULE:FREQ=WEEKLY;BYDAY=TU',
      'RRULE:FREQ=MONTHLY;BYMONTHDAY=1',
    ]),
    'by its place in a set':
        google(['RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1']),
    'every hour': google(['RRULE:FREQ=HOURLY']),
    'in small letters': google(['rrule:freq=weekly;byday=tu']),
    'a rule of nonsense': google(['RRULE:FREQ=WEEKLY;BYDAY=XX;INTERVAL=-3']),
    'not a rule at all': google([42, null, 'RRULE']),
    'no lines': google(const []),
  };

  void agree(String name, MeetingRepeat? sheet, SeriesRepeat? edit) {
    final shown = edit?.repeat;
    if (sheet == null) {
      expect(shown, isNull,
          reason: '$name: the sheet says nothing, so Edit must show nothing');
      return;
    }
    if (shown == null) return; // The sheet may say what Edit cannot change.
    expect(shown.describe(edit!.firstDay), sheet.describe(),
        reason: '$name: Edit and the sheet say it differently');
  }

  test('a Microsoft series: where Edit shows its repeat, it is the sheet\'s '
      'sentence; where the sheet says nothing, Edit shows nothing', () {
    var both = 0;
    graphSeries.forEach((name, recurrence) {
      final sheet = MeetingRepeat.fromGraph(recurrence);
      final edit = SeriesRepeat.fromGraph(recurrence);
      agree(name, sheet, edit);
      if (sheet != null && edit?.repeat != null) both++;
    });
    // The table must not pass by reading nothing at all.
    expect(both, greaterThanOrEqualTo(8));
    expect(MeetingRepeat.fromGraph(graphSeries['every 3 weeks'])?.describe(),
        'Every 3 weeks on Tuesday');
    expect(SeriesRepeat.fromGraph(graphSeries['every 3 weeks'])?.repeat,
        isNull,
        reason: 'the Repeat menu has no item for every 3 weeks');
  });

  test('a Google series: the same', () {
    var both = 0;
    googleSeries.forEach((name, event) {
      final sheet = MeetingRepeat.fromGoogle(event);
      final edit = SeriesRepeat.fromGoogle(event);
      agree(name, sheet, edit);
      if (sheet != null && edit?.repeat != null) both++;
    });
    expect(both, greaterThanOrEqualTo(8));
  });

  test('both read a Google series\' last day on the series\' own clock', () {
    // Monday 28 June 2027 is the last meeting of a Dallas series: Google
    // writes the end of that day in Dallas, in UTC, which is already the
    // 29th in UTC.
    final dallas = {
      'start': {
        'dateTime': '2026-09-07T09:00:00-05:00',
        'timeZone': 'America/Chicago',
      },
      'end': {
        'dateTime': '2026-09-07T10:00:00-05:00',
        'timeZone': 'America/Chicago',
      },
      'recurrence': ['RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20270629T045959Z'],
    };
    final sheet = MeetingRepeat.fromGoogle(dallas);
    final edit = SeriesRepeat.fromGoogle(dallas);
    expect(sheet?.describe(), 'Every week on Monday, until 28 June 2027');
    expect(edit?.repeat?.until, DateTime(2027, 6, 28));
    expect(edit!.repeat!.describe(edit.firstDay), sheet!.describe());
  });
}
