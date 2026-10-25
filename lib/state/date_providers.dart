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

/// The dates in [messageId]'s body worth a link (see [datesWorthLinking]),
/// where Settings, Calendar has them found. Empty while the model is not
/// on the phone yet, which the first message opened fetches.
final messageDatesProvider = FutureProvider.autoDispose
    .family<List<FoundDate>, String>((ref, messageId) async {
  if (!ref.watch(calendarPrefsProvider).datesInMail) return const [];
  final finder = ref.watch(dateFinderProvider);
  final body = await ref.watch(messageBodyProvider(messageId).future);
  var text = body.text;
  if (text.length > datesReadFrom) text = text.substring(0, datesReadFrom);
  return datesWorthLinking(await finder.find(text));
});

/// The phone's own zone by its IANA name, or null where it will not say.
final deviceZoneProvider = FutureProvider<String?>((ref) async {
  try {
    return await ref.watch(deviceCalendarProvider).timeZoneId();
  } catch (_) {
    return null;
  }
});
