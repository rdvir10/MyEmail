import 'dart:convert';

import 'package:flutter/foundation.dart';

/// How a new meeting starts, chosen in Settings, Calendar, New meetings
/// (calendar idea #61), and carried by the backup: how long it lasts,
/// whether it ends a few minutes early, and the accounts whose meetings
/// start online. Only New meeting starts from them: a meeting being changed
/// keeps what it has, and one made from another (Duplicate) keeps its own
/// length.
///
/// Read on the phone alone. Google keeps a default length of its own, but
/// reading it needs a settings scope the app has not asked for, and Graph
/// has nothing for Outlook's "end early".
@immutable
class NewMeetingDefaults {
  const NewMeetingDefaults({
    this.minutes = 60,
    this.endEarly = 0,
    this.online = const {},
  });

  /// How long a new meeting is, in minutes: one of [lengthChoices]. An
  /// hour, as it always was, until chosen.
  final int minutes;

  /// How many minutes before the hour or half hour it ends: one of
  /// [endEarlyChoices], 0 for on time. Taken off [minutes], so a half
  /// hour with 5 ends at 25 past.
  final int endEarly;

  /// The accounts, by id, whose new meetings start with Online on: a
  /// Teams or Meet link, as the account's calendar holds them.
  final Set<String> online;

  static const lengthChoices = [15, 30, 45, 60];
  static const endEarlyChoices = [0, 5, 10];

  /// How long a new meeting is drawn and sent: [minutes] less [endEarly],
  /// never less than ten minutes (15 minutes ending 10 early ends 5 early).
  Duration get length {
    final early = minutes - endEarly < shortest
        ? (minutes - shortest).clamp(0, endEarly)
        : endEarly;
    return Duration(minutes: minutes - early);
  }

  /// The shortest a meeting ending early is left.
  static const shortest = 10;

  /// Whether a new meeting from [accountId] starts online.
  bool onlineFor(String accountId) => online.contains(accountId);

  NewMeetingDefaults copyWith({
    int? minutes,
    int? endEarly,
    Set<String>? online,
  }) =>
      NewMeetingDefaults(
        minutes: minutes ?? this.minutes,
        endEarly: endEarly ?? this.endEarly,
        online: online ?? this.online,
      );

  /// The accounts as ids in a list, which a backup restored on another
  /// device rewrites to that device's ids.
  Map<String, Object?> toJson() => {
        'minutes': minutes,
        'endEarly': endEarly,
        if (online.isNotEmpty) 'online': [...online]..sort(),
      };

  /// What [toJson] wrote; anything missing or out of range is the default.
  factory NewMeetingDefaults.fromJson(Object? json) {
    if (json is! Map) return const NewMeetingDefaults();
    final minutes = json['minutes'];
    final early = json['endEarly'];
    final online = json['online'];
    return NewMeetingDefaults(
      // Whole numbers only: 60.0 equals 60, and is not one.
      minutes: minutes is int && lengthChoices.contains(minutes) ? minutes : 60,
      endEarly: early is int && endEarlyChoices.contains(early) ? early : 0,
      online: {
        if (online is List)
          for (final id in online)
            if (id is String && id.isNotEmpty) id,
      },
    );
  }

  /// The defaults kept as text, or null for text that is not them.
  static NewMeetingDefaults? tryParse(String text) {
    try {
      final json = jsonDecode(text);
      return json is Map ? NewMeetingDefaults.fromJson(json) : null;
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is NewMeetingDefaults &&
      other.minutes == minutes &&
      other.endEarly == endEarly &&
      setEquals(other.online, online);

  @override
  int get hashCode =>
      Object.hash(minutes, endEarly, Object.hashAllUnordered(online));
}
