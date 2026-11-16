import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/data/calendar/calendar_upkeep.dart';
import 'package:myemail/data/widget/home_screen_surface.dart';

/// The calendar as an app icon on the home screen (calendar idea #87): the
/// weekday, the day of the month and how many meetings are still to come
/// today, beside the mailbox widget and the size of it. It is Kotlin, a
/// layout, an info file and the manifest, which only the release build
/// compiles and no test can draw, so this reads them as a compiler would
/// and holds their names together, and to the Dart that writes what it
/// counts and asks for it to be drawn.
void main() {
  const main = 'android/app/src/main';
  const provider = 'CalendarDayWidgetProvider';

  /// [path] under [main], or nothing where it is not there yet.
  String read(String path) {
    final file = File('$main/$path');
    return file.existsSync() ? file.readAsStringSync() : '';
  }

  final kt = read('kotlin/com/rdvir/mailtree/$provider.kt');
  final listKt = read('kotlin/com/rdvir/mailtree/CalendarWidgetProvider.kt');
  final manifest = read('AndroidManifest.xml');
  final layout = read('res/layout/calendar_day_widget.xml');
  final info = read('res/xml/calendar_day_widget_info.xml');
  final listInfo = read('res/xml/calendar_widget_info.xml');
  final mailLayout = read('res/layout/mailbox_count_widget.xml');
  final mailInfo = read('res/xml/mailbox_count_widget_info.xml');
  final strings = read('res/values/strings.xml');

  /// [name]="…" on the element whose id is [id] in [xml].
  String? attribute(String xml, String id, String name) {
    final element = RegExp('<\\w+[^<>]*?android:id="@\\+id/$id"[^<>]*>')
        .firstMatch(xml)?[0];
    if (element == null) return null;
    return RegExp('android:$name="([^"]*)"').firstMatch(element)?[1];
  }

  /// Every attribute of the provider in an appwidget info file.
  Map<String, String> attributes(String xml) => {
        for (final m in RegExp(r'android:(\w+)="([^"]*)"').allMatches(xml))
          m[1]!: m[2]!,
      };

  /// The last part of [path], Windows's or not.
  String last(String path) => path.split(RegExp(r'[\\/]')).last;

  /// Whether res has a [kind] (drawable, layout, xml) named [name], in any
  /// of its folders for that kind (drawable-v21 and the like).
  bool resource(String kind, String name) => Directory('$main/res')
      .listSync()
      .whereType<Directory>()
      .where((d) => last(d.path) == kind || last(d.path).startsWith('$kind-'))
      .any((d) =>
          d.listSync().any((f) => last(f.path).split('.').first == name));

  /// The manifest's receiver for this widget.
  String receiver() =>
      RegExp('<receiver\\s+android:name="\\.$provider"[\\s\\S]*?</receiver>')
          .firstMatch(manifest)?[0] ??
      '';

  group('the names hold together', () {
    test('the manifest declares it as the other two are declared', () {
      final declared = receiver();
      expect(declared, isNotEmpty);
      expect(declared, contains('android:exported="true"'));
      expect(declared,
          contains('android.appwidget.action.APPWIDGET_UPDATE'));
      expect(declared,
          contains('android:name="android.appwidget.provider"'));
      expect(declared,
          contains('android:resource="@xml/calendar_day_widget_info"'));
      expect(declared,
          contains('android:label="@string/calendar_day_widget_label"'));
      expect(kt, contains('class $provider : HomeWidgetProvider()'));
      expect(kt, startsWith('package com.rdvir.mailtree'));
      // The name the app asks home_widget to draw.
      expect(calendarDayWidgetProvider, provider);
    });

    test('every id, layout, string and plural it names is there', () {
      expect(kt, isNotEmpty);
      for (final m in RegExp(r'R\.id\.(\w+)').allMatches(kt)) {
        expect(layout, contains('android:id="@+id/${m[1]}"'),
            reason: 'R.id.${m[1]}');
      }
      for (final m in RegExp(r'R\.(layout|drawable)\.(\w+)').allMatches(kt)) {
        expect(resource(m[1]!, m[2]!), isTrue, reason: m[0]);
      }
      for (final m in RegExp(r'R\.string\.(\w+)').allMatches(kt)) {
        expect(strings, contains('<string name="${m[1]}">'), reason: m[0]);
      }
      final plurals = RegExp(r'R\.plurals\.(\w+)').allMatches(kt).toList();
      expect(plurals, isNotEmpty);
      for (final m in plurals) {
        final plural =
            RegExp('<plurals name="${m[1]}">([\\s\\S]*?)</plurals>')
                .firstMatch(strings)?[1];
        expect(plural, isNotNull, reason: m[0]);
        expect(plural, contains('<item quantity="one">'));
        expect(plural, contains('<item quantity="other">'));
      }
      // And what its XML names.
      for (final xml in [layout, info, receiver()]) {
        for (final m in RegExp(r'@(string|drawable|layout|xml)/(\w+)')
            .allMatches(xml)) {
          final (kind, name) = (m[1]!, m[2]!);
          expect(
            kind == 'string'
                ? strings.contains('<string name="$name">')
                : resource(kind, name),
            isTrue,
            reason: m[0],
          );
        }
      }
    });

    test('the picker names it plainly, beside the other two', () {
      String text(String name) =>
          RegExp('<string name="$name">([^<]*)</string>')
              .firstMatch(strings)?[1] ??
          '';
      expect(text('calendar_day_widget_label'), 'Calendar icon');
      expect(text('calendar_day_widget_description'), isNotEmpty);
      expect(attributes(info)['description'],
          '@string/calendar_day_widget_description');
      expect(attributes(info)['initialLayout'], '@layout/calendar_day_widget');
    });
  });

  group('a pair with the mailbox widget', () {
    test('one cell, as an app icon, not resized', () {
      final mine = attributes(info);
      final mail = attributes(mailInfo);
      for (final a in [
        'minWidth',
        'minHeight',
        'targetCellWidth',
        'targetCellHeight',
        'resizeMode',
        'widgetCategory',
      ]) {
        expect(mine[a], mail[a], reason: a);
      }
      // Nothing to choose when it is placed.
      expect(mine.containsKey('configure'), isFalse);
    });

    test("the tile, the count and the name as the mailbox widget's", () {
      for (final a in ['layout_width', 'layout_height', 'src']) {
        expect(attribute(layout, 'calendar_day_widget_tile', a),
            attribute(mailLayout, 'mailbox_widget_tile', a),
            reason: a);
      }
      // The count where the mailbox's total is, and the same size: a
      // fact about the day rather than an alert.
      for (final a in [
        'layout_height',
        'minWidth',
        'layout_gravity',
        'gravity',
        'paddingStart',
        'paddingEnd',
        'background',
        'textColor',
        'textSize',
        'maxLines',
      ]) {
        expect(attribute(layout, 'calendar_day_widget_count', a),
            attribute(mailLayout, 'mailbox_widget_total', a),
            reason: a);
      }
      // Hidden until there is a number: none left, no badge.
      expect(attribute(layout, 'calendar_day_widget_count', 'visibility'),
          'gone');
      for (final a in [
        'layout_width',
        'layout_marginTop',
        'gravity',
        'maxLines',
        'ellipsize',
        'textColor',
        'textSize',
        'shadowColor',
        'shadowDx',
        'shadowDy',
        'shadowRadius',
      ]) {
        expect(attribute(layout, 'calendar_day_widget_name', a),
            attribute(mailLayout, 'mailbox_widget_name', a),
            reason: a);
      }
      // Sized to the cell by the mailbox widget's own sum.
      expect(kt, contains('MailboxCountWidgetProvider().iconDpFor('));
    });
  });

  group('the date and the count', () {
    test("the weekday and the day are Android's own clock, which turns over "
        'at midnight by itself', () {
      for (final (id, format) in [
        ('calendar_day_widget_weekday', 'EEE'),
        ('calendar_day_widget_day', 'd'),
      ]) {
        expect(
          RegExp('<TextClock[^<>]*android:id="@\\+id/$id"').hasMatch(layout),
          isTrue,
          reason: id,
        );
        expect(attribute(layout, id, 'format12Hour'), format, reason: id);
        expect(attribute(layout, id, 'format24Hour'), format, reason: id);
      }
    });

    test('counted from the meetings the calendar widget reads', () {
      expect(RegExp(r'const val KEY = "([^"]+)"').firstMatch(kt)?[1],
          CalendarUpkeep.widgetKey);
      final dart =
          File('lib/data/calendar/calendar_upkeep.dart').readAsStringSync();
      final written = {
        for (final m in RegExp(r"'(\w)': ").allMatches(
            dart.substring(dart.indexOf('Future<void> _widget('))))
          m[1]!,
      };
      final read = {
        for (final m in RegExp(r'o\.opt(?:String|Long|Boolean)\("(\w+)"')
            .allMatches(kt))
          m[1]!,
      };
      // Its start and end; all day and declined, which are not counted.
      expect(read, {'s', 'e', 'a', 'd'});
      expect(written, containsAll(read));
      expect(kt,
          contains('o.optBoolean("a", false) || o.optBoolean("d", false)'));
      expect(kt, contains('o.optLong("e", 0) > now'));
      expect(kt, contains('o.optLong("s", 0) < tomorrow'));
    });

    test('a tap anywhere opens the calendar, as the date on the calendar '
        'widget does', () {
      expect(layout, contains('android:id="@+id/calendar_day_widget_root"'));
      expect(kt, contains('R.id.calendar_day_widget_root,'));
      expect(kt, contains('Uri.parse("myemail://calendar")'));
      expect(listKt, contains('Uri.parse("myemail://calendar")'));
    });

    test('drawn whenever the calendar widget is', () {
      // Android's half hour, and the app's: the list's drawing draws the
      // icons too, and the app asks for both.
      expect(listKt, contains('$provider.drawAll(context)'));
      expect(kt, contains('fun drawAll(context: Context)'));
    });

    test('and on its own half hour, as the calendar widget has, so a '
        'meeting over is not still counted with the icon alone', () {
      final every = attributes(info)['updatePeriodMillis'];
      expect(every, attributes(listInfo)['updatePeriodMillis']);
      expect(every, '1800000');
    });
  });

  test('the app asks for both calendar widgets to be drawn', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final asked = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('home_widget');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'updateWidget') {
        asked.add((call.arguments as Map)['android']);
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await const AndroidHomeScreenSurface().redrawCalendar();

    expect(asked, [calendarWidgetProvider, provider]);
  });
}
