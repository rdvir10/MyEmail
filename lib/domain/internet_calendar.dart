import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A calendar from a link, Outlook's Add calendar, From internet: an .ics
/// feed MyEmail reads itself every few hours and shows read only, in its
/// own colour, beside the accounts' calendars. Kept on this device and in
/// the backup.
@immutable
class InternetCalendar {
  const InternetCalendar({
    required this.id,
    required this.name,
    required this.url,
    required this.colour,
  });

  final String id;
  final String name;

  /// Where it is read from: https, a webcal:// link given turned into it.
  final String url;

  /// ARGB.
  final int colour;

  /// The account its events are shown as, apart from every real one.
  String get accountId => '$internetAccountPrefix$id';

  InternetCalendar copyWith({String? name, int? colour}) => InternetCalendar(
        id: id,
        name: name ?? this.name,
        url: url,
        colour: colour ?? this.colour,
      );

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'url': url, 'colour': colour};

  static InternetCalendar? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'], url = json['url'];
    final colour = json['colour'];
    if (id is! String || name is! String || url is! String) return null;
    return InternetCalendar(
      id: id,
      name: name,
      url: url,
      colour: colour is int ? colour : internetCalendarColours.first,
    );
  }

  /// The calendars kept as text, or none for text that is not them.
  static List<InternetCalendar> listFrom(String? text) {
    if (text == null || text.isEmpty) return const [];
    try {
      final json = jsonDecode(text);
      return [
        for (final c in json is List ? json : const [])
          ?InternetCalendar.fromJson(c),
      ];
    } on FormatException {
      return const [];
    }
  }

  static String listToText(List<InternetCalendar> calendars) =>
      jsonEncode([for (final c in calendars) c.toJson()]);

  @override
  bool operator ==(Object other) =>
      other is InternetCalendar &&
      other.id == id &&
      other.name == name &&
      other.url == url &&
      other.colour == colour;

  @override
  int get hashCode => Object.hash(id, name, url, colour);
}

/// The account id a calendar from a link's events carry.
const internetAccountPrefix = 'internet:';

bool isInternetAccount(String accountId) =>
    accountId.startsWith(internetAccountPrefix);

/// A link as pasted, as it can be read: webcal:// is https:// under
/// another name, the way calendar apps hand them out. Null for anything
/// that is not a web link.
String? feedUrlOf(String pasted) {
  var text = pasted.trim();
  if (text.toLowerCase().startsWith('webcals://')) {
    text = 'https://${text.substring('webcals://'.length)}';
  } else if (text.toLowerCase().startsWith('webcal://')) {
    text = 'https://${text.substring('webcal://'.length)}';
  }
  final uri = Uri.tryParse(text);
  if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
    return null;
  }
  return uri.host.isEmpty ? null : uri.toString();
}

/// The colours a new calendar from a link is given in turn.
const internetCalendarColours = [
  0xFF8E24AA,
  0xFF0B8043,
  0xFFD50000,
  0xFFF4511E,
  0xFF039BE5,
  0xFF616161,
];

/// Countries' public holidays, as Google publishes each: the name to pick
/// it by, and Google's calendar for it.
const holidayCalendars = <({String country, String id})>[
  (country: 'Australia', id: 'en.australian'),
  (country: 'Austria', id: 'en.austrian'),
  (country: 'Brazil', id: 'en.brazilian'),
  (country: 'Bulgaria', id: 'en.bulgarian'),
  (country: 'Canada', id: 'en.canadian'),
  (country: 'China', id: 'en.china'),
  (country: 'Croatia', id: 'en.croatian'),
  (country: 'Czechia', id: 'en.czech'),
  (country: 'Denmark', id: 'en.danish'),
  (country: 'Finland', id: 'en.finnish'),
  (country: 'France', id: 'en.french'),
  (country: 'Germany', id: 'en.german'),
  (country: 'Greece', id: 'en.greek'),
  (country: 'Hong Kong', id: 'en.hong_kong'),
  (country: 'Hungary', id: 'en.hungarian'),
  (country: 'India', id: 'en.indian'),
  (country: 'Indonesia', id: 'en.indonesian'),
  (country: 'Ireland', id: 'en.irish'),
  (country: 'Israel', id: 'en.jewish'),
  (country: 'Italy', id: 'en.italian'),
  (country: 'Japan', id: 'en.japanese'),
  (country: 'Latvia', id: 'en.latvian'),
  (country: 'Lithuania', id: 'en.lithuanian'),
  (country: 'Malaysia', id: 'en.malaysia'),
  (country: 'Mexico', id: 'en.mexican'),
  (country: 'Netherlands', id: 'en.dutch'),
  (country: 'New Zealand', id: 'en.new_zealand'),
  (country: 'Norway', id: 'en.norwegian'),
  (country: 'Philippines', id: 'en.philippines'),
  (country: 'Poland', id: 'en.polish'),
  (country: 'Portugal', id: 'en.portuguese'),
  (country: 'Romania', id: 'en.romanian'),
  (country: 'Russia', id: 'en.russian'),
  (country: 'Singapore', id: 'en.singapore'),
  (country: 'Slovakia', id: 'en.slovak'),
  (country: 'South Africa', id: 'en.sa'),
  (country: 'South Korea', id: 'en.south_korea'),
  (country: 'Spain', id: 'en.spain'),
  (country: 'Sweden', id: 'en.swedish'),
  (country: 'Taiwan', id: 'en.taiwan'),
  (country: 'Turkey', id: 'en.turkish'),
  (country: 'Ukraine', id: 'en.ukrainian'),
  (country: 'United Kingdom', id: 'en.uk'),
  (country: 'United States', id: 'en.usa'),
  (country: 'Vietnam', id: 'en.vietnamese'),
  (country: 'Christian holidays', id: 'en.christian'),
  (country: 'Muslim holidays', id: 'en.islamic'),
];

/// Where Google publishes [id]'s holidays, as a link anyone can read.
String holidayFeedUrl(String id) =>
    'https://calendar.google.com/calendar/ical/'
    '${Uri.encodeComponent('$id#holiday@group.v.calendar.google.com')}'
    '/public/basic.ics';
