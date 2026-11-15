import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A link to a meeting room of Ron's own, his Zoom room say, kept in
/// Settings, Calendar, Meeting links and offered in New meeting's Online
/// menu under Teams and Meet (calendar idea #62).
///
/// It is a standing link, so MyEmail needs no access to the service: a
/// meeting held there carries the link where a person pasting it would put
/// it, the place where none was typed and the notes' last line, and no
/// Teams or Meet meeting is made. A fresh link for each meeting would mean
/// signing MyEmail in to Zoom, which this is not.
///
/// Anyone with the link can come in, so it is kept as a calendar from a
/// link is: on this device, and in a backup only sealed with the sign-in
/// details (see BackupService.export).
@immutable
class MeetingLink {
  const MeetingLink({required this.name, required this.url});

  /// What Ron calls it, "Zoom (my room)": the Online menu's entry and the
  /// list's in Settings. Never sent: see [line].
  final String name;

  /// The room: an https link, as [meetingLinkUrlOf] takes one.
  final String url;

  /// The line it goes out as, last in a meeting's notes, as a Google Meet
  /// link goes on a Microsoft invitation: the service, known by the link's
  /// host, "Join the Zoom meeting: …", or "Join the meeting: …" for a host
  /// not known here. Never [name], which is Ron's own and may say more
  /// than he means the people invited to read. A Meet room reads as that
  /// Meet line does, "Join with Google Meet: …", not as a "Meet meeting".
  String get line => switch (knownMeetingService(url)) {
        final service? when service.endsWith('Meet') =>
          'Join with $service: $url',
        final service? => 'Join the $service meeting: $url',
        null => 'Join the meeting: $url',
      };

  /// [notes] with [line] as their last line, a blank line before it, or
  /// the line alone where there are none. Notes that hold the line already
  /// are left as they are: a meeting duplicated from one held in the room
  /// comes with them, and the line went twice.
  String endOf(String notes) {
    if (notes.contains(line)) return notes;
    return notes.trim().isEmpty ? line : '${notes.trimRight()}\n\n$line';
  }

  Map<String, Object?> toJson() => {'name': name, 'url': url};

  /// Null for anything [toJson] did not write, or a link that is not one
  /// to keep. A blank name is the service's.
  static MeetingLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], url = json['url'];
    if (url is! String) return null;
    final kept = meetingLinkUrlOf(url);
    if (kept == null) return null;
    final named = name is String ? name.trim() : '';
    return MeetingLink(
      name: named.isEmpty ? meetingServiceOf(kept) : named,
      url: kept,
    );
  }

  /// The links kept as text, each link once, or none for text that is not
  /// them.
  static List<MeetingLink> listFrom(String? text) {
    if (text == null || text.isEmpty) return const [];
    try {
      final json = jsonDecode(text);
      final seen = <String>{};
      return [
        for (final entry in json is List ? json : const [])
          if (MeetingLink.fromJson(entry) case final link?
              when seen.add(link.url))
            link,
      ];
    } on FormatException {
      return const [];
    }
  }

  static String listToText(List<MeetingLink> links) =>
      jsonEncode([for (final l in links) l.toJson()]);

  @override
  bool operator ==(Object other) =>
      other is MeetingLink && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(name, url);

  /// The name and the host alone: the whole link lets anyone in, and has
  /// no place in a log.
  @override
  String toString() => 'MeetingLink($name, ${Uri.tryParse(url)?.host})';
}

/// [typed] as a meeting link to keep: https alone, with a host that has a
/// dot in it. One typed without its scheme, "zoom.us/j/123", is taken as
/// https. Null for anything else: http, an app's own scheme (zoommtg:),
/// or words that are not a link.
String? meetingLinkUrlOf(String typed) {
  final text = typed.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
  final schemed = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:').hasMatch(text);
  final uri = Uri.tryParse(schemed ? text : 'https://$text');
  if (uri == null ||
      !uri.isScheme('https') ||
      uri.host.isEmpty ||
      !uri.host.contains('.')) {
    return null;
  }
  return uri.toString();
}

/// The service [url] is a room on, by its host: "Zoom" for zoom.us or
/// us02web.zoom.us. Matched on the host itself or as a dot-suffix, never
/// as part of one: evilzoom.us is not Zoom. Null for a host not known
/// here.
String? knownMeetingService(String url) {
  final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
  for (final (domain, name) in _services) {
    if (host == domain || host.endsWith('.$domain')) return name;
  }
  return null;
}

/// The name a new link starts with: its service's (see
/// [knownMeetingService]), or for a service not known here its host, less
/// www.
String meetingServiceOf(String url) {
  final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
  return knownMeetingService(url) ??
      (host.startsWith('www.') ? host.substring(4) : host);
}

/// The services a room's link is commonly on, by the domain their links
/// are under. Each name reads in "Join the … meeting", so GoTo Meeting is
/// GoTo here, and Jitsi Meet is Jitsi.
const _services = [
  ('zoom.us', 'Zoom'),
  ('zoom.com', 'Zoom'),
  ('zoomgov.com', 'Zoom'),
  ('webex.com', 'Webex'),
  ('teams.microsoft.com', 'Teams'),
  ('teams.live.com', 'Teams'),
  ('meet.google.com', 'Google Meet'),
  ('whereby.com', 'Whereby'),
  ('gotomeeting.com', 'GoTo'),
  ('gotomeet.me', 'GoTo'),
  ('meet.goto.com', 'GoTo'),
  ('ringcentral.com', 'RingCentral'),
  ('chime.aws', 'Amazon Chime'),
  ('join.skype.com', 'Skype'),
  ('meet.jit.si', 'Jitsi'),
];
