import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ai/date_finder.dart';
import '../domain/found_dates.dart';
import 'calendar_providers.dart' show deviceCalendarProvider;
import 'calendar_view_providers.dart' show calendarPrefsProvider;
import 'message_providers.dart' show messageBodyProvider;

/// The phone's date finder: ML Kit's entity extraction, which main() sets
/// on Android. Elsewhere it finds nothing.
final dateFinderProvider = Provider<DateFinder>((ref) => FakeDateFinder());

/// How much of a message is read for dates: the start of a long one, where
/// the times worth a meeting are.
const datesReadFrom = 6000;

/// The dates in a message's body worth a link (see [datesWorthLinking]),
/// where Settings, Calendar has them found: the message by its id, and
/// when it was written (its date), which "tomorrow" or "Thursday" in it
/// count from. Empty while the model is not on the phone yet, which the
/// first message opened fetches.
final messageDatesProvider = FutureProvider.autoDispose
    .family<List<FoundDate>, ({String id, DateTime written})>(
        (ref, message) async {
  if (!ref.watch(calendarPrefsProvider).datesInMail) return const [];
  final finder = ref.watch(dateFinderProvider);
  final body = await ref.watch(messageBodyProvider(message.id).future);
  var text = body.text;
  if (text.length > datesReadFrom) text = text.substring(0, datesReadFrom);
  // Read as on the day it was written, never later than now (a sender's
  // clock can be ahead). Which of the dates are gone by is still today's.
  final now = DateTime.now();
  final written = message.written.isAfter(now) ? now : message.written;
  return datesWorthLinking(await finder.find(text, now: written));
});

/// The phone's own zone by its IANA name, or null where it will not say.
final deviceZoneProvider = FutureProvider<String?>((ref) async {
  try {
    return await ref.watch(deviceCalendarProvider).timeZoneId();
  } catch (_) {
    return null;
  }
});
