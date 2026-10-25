import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../domain/error_report.dart' show ReadableError;
import '../../domain/ics_feed.dart';
import '../../domain/internet_calendar.dart';
import '../mail_engine.dart' show ConnectionFailed;

/// What a calendar from a link last said, and when it was read.
typedef KeptFeed = ({IcsFeed feed, DateTime readAt});

/// Reading the calendars from links, and keeping what each last said, so
/// they show at once and with no signal and are read again every
/// [readEvery].
abstract class InternetCalendars {
  /// How long what a link said is taken as it stands: "every few hours",
  /// as Outlook reads its internet calendars.
  static const readEvery = Duration(hours: 6);

  /// What [calendar] last said; null where it never was read.
  Future<KeptFeed?> kept(InternetCalendar calendar);

  /// [calendar] read from its link now, and kept. Throws [ConnectionFailed]
  /// with no connection, and [FeedUnreadable] for a link that answers
  /// with something other than a calendar.
  Future<IcsFeed> read(InternetCalendar calendar);

  /// What was kept of [calendar], let go: it was taken off.
  Future<void> forget(InternetCalendar calendar);
}

/// A link that did not give a calendar.
class FeedUnreadable implements Exception, ReadableError {
  const FeedUnreadable(this.message);

  @override
  final String message;

  @override
  String toString() => message;
}

/// None at all: the default, for the tests and the browser preview, where
/// there is nowhere to keep one. main() sets [FileInternetCalendars].
class NoInternetCalendars implements InternetCalendars {
  const NoInternetCalendars();

  @override
  Future<KeptFeed?> kept(InternetCalendar calendar) async => null;

  @override
  Future<IcsFeed> read(InternetCalendar calendar) async =>
      throw const FeedUnreadable('Calendars from links are read on the phone.');

  @override
  Future<void> forget(InternetCalendar calendar) async {}
}

/// Each calendar kept in a file of its own, in the app's support folder,
/// what it said as it said it; read from its link with [http].
class FileInternetCalendars implements InternetCalendars {
  FileInternetCalendars({
    this.client,
    Future<Directory?> Function()? folder,
  }) : _folder = folder ?? _defaultFolder;

  /// One handed in, which belongs to whoever handed it in; null makes one
  /// for each read.
  final http.Client? client;
  final Future<Directory?> Function() _folder;

  /// What each file said, read once, while the file is as it was.
  final Map<String, ({DateTime modified, IcsFeed feed})> _parsed = {};

  static Future<Directory?> _defaultFolder() async {
    try {
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}'
        '${Platform.pathSeparator}internet-calendars',
      );
      await dir.create(recursive: true);
      return dir;
    } catch (e) {
      debugPrint('[myemail] nowhere to keep calendars from links: $e');
      return null;
    }
  }

  Future<File?> _fileOf(InternetCalendar calendar) async {
    final dir = await _folder();
    if (dir == null) return null;
    // The id is the app's own, letters and digits.
    return File('${dir.path}${Platform.pathSeparator}${calendar.id}.ics');
  }

  @override
  Future<KeptFeed?> kept(InternetCalendar calendar) async {
    try {
      final file = await _fileOf(calendar);
      if (file == null || !await file.exists()) return null;
      final modified = await file.lastModified();
      final known = _parsed[calendar.id];
      if (known != null && known.modified == modified) {
        return (feed: known.feed, readAt: modified);
      }
      final feed = IcsFeed.parse(await file.readAsString());
      _parsed[calendar.id] = (modified: modified, feed: feed);
      return (feed: feed, readAt: modified);
    } catch (e) {
      debugPrint('[myemail] kept calendar ${calendar.name} not read: $e');
      return null;
    }
  }

  @override
  Future<IcsFeed> read(InternetCalendar calendar) async {
    final client = this.client ?? http.Client();
    final http.Response response;
    try {
      response = await client
          .get(Uri.parse(calendar.url))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw ConnectionFailed('Could not reach ${calendar.name}. ($e)');
    } finally {
      if (this.client == null) client.close();
    }
    if (response.statusCode >= 400) {
      throw FeedUnreadable(
        '${calendar.name} could not be read (HTTP ${response.statusCode}).',
      );
    }
    final text = response.body;
    if (!text.contains('BEGIN:VCALENDAR')) {
      throw FeedUnreadable('${calendar.name} is not a calendar.');
    }
    final feed = IcsFeed.parse(text);
    try {
      final file = await _fileOf(calendar);
      if (file != null) {
        await file.writeAsString(text, flush: true);
        _parsed[calendar.id] = (modified: await file.lastModified(), feed: feed);
      }
    } catch (e) {
      // Read, and shown; only opening at once next time is lost.
      debugPrint('[myemail] calendar ${calendar.name} not kept: $e');
    }
    return feed;
  }

  @override
  Future<void> forget(InternetCalendar calendar) async {
    _parsed.remove(calendar.id);
    try {
      final file = await _fileOf(calendar);
      if (file != null && await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[myemail] calendar ${calendar.name} not let go: $e');
    }
  }
}

/// Kept in memory, each link answering what a test gave it.
class MemoryInternetCalendars implements InternetCalendars {
  MemoryInternetCalendars([Map<String, String>? feeds])
      : feeds = feeds ?? {};

  /// What each link answers, by its address.
  final Map<String, String> feeds;
  final Map<String, KeptFeed> _kept = {};

  /// Every link read, in order.
  final List<String> asked = [];

  DateTime Function() clock = DateTime.now;

  @override
  Future<KeptFeed?> kept(InternetCalendar calendar) async => _kept[calendar.id];

  @override
  Future<IcsFeed> read(InternetCalendar calendar) async {
    asked.add(calendar.url);
    final text = feeds[calendar.url];
    if (text == null) {
      throw FeedUnreadable('${calendar.name} could not be read (HTTP 404).');
    }
    final feed = IcsFeed.parse(text);
    _kept[calendar.id] = (feed: feed, readAt: clock());
    return feed;
  }

  @override
  Future<void> forget(InternetCalendar calendar) async =>
      _kept.remove(calendar.id);
}
