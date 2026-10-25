import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/calendar_upkeep.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';

/// The calendar widget (#11) draws, in Kotlin, what CalendarUpkeep wrote
/// in Dart, and nothing checks the two agree but this.
void main() {
  final kt = File(
    'android/app/src/main/kotlin/com/rdvir/mailtree/CalendarWidgetProvider.kt',
  ).readAsStringSync();
  final dart =
      File('lib/data/calendar/calendar_upkeep.dart').readAsStringSync();
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  test('Android reads the meetings where Dart writes them', () {
    final key = RegExp(r'const val KEY = "([^"]+)"').firstMatch(kt)![1];
    expect(key, CalendarUpkeep.widgetKey);
  });

  test("every field of a meeting Android reads, Dart writes", () {
    final read = {
      for (final m in RegExp(r'o\.opt(?:String|Long|Boolean)\("(\w+)"')
          .allMatches(kt))
        m[1]!,
    };
    final written = {
      for (final m in RegExp(r"'(\w)': ").allMatches(
          dart.substring(dart.indexOf('Future<void> _widget('))))
        m[1]!,
      // Written with Dart's null-aware entry, which the pattern above
      // does not see.
      for (final m in RegExp(r"'(\w)': \?").allMatches(dart)) m[1]!,
    };
    expect(read, containsAll(['t', 's', 'e', 'l']));
    expect(written, containsAll(read));
  });

  test('the widget Dart redraws is the one the manifest declares', () {
    expect(manifest, contains('android:name=".$calendarWidgetProvider"'));
    expect(kt, contains('class $calendarWidgetProvider'));
    expect(manifest, contains('@xml/calendar_widget_info'));
  });

  test("its links are the ones the app opens", () {
    expect(kt, contains('"myemail://calendar"'));
    expect(dart, contains("host: 'event'"));
  });
}
