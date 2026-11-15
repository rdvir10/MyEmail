import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/meeting_links.dart' show placeToFind;
import '../../domain/text_direction.dart';

/// A meeting's place, a tap from directions in the phone's maps app (#40),
/// on the meeting's sheet, in My Day and on an invitation's card. A place
/// that only names an online meeting, or is its link, stays the plain text
/// it was: Join is the way in to those.
class PlaceLink extends StatelessWidget {
  const PlaceLink({
    super.key,
    required this.place,
    this.style,
    this.maxLines,
    this.overflow,
  });

  final String place;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final query = placeToFind(place);
    if (query == null) {
      return Text(place, style: style, maxLines: maxLines, overflow: overflow);
    }
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      link: true,
      hint: 'Directions',
      child: InkWell(
        key: const ValueKey('place-link'),
        borderRadius: BorderRadius.circular(4),
        onTap: () => openPlace(query),
        child: Text(
          place,
          style: (style ?? const TextStyle()).copyWith(
            color: scheme.primary,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary,
          ),
          // As the place is written in New meeting: by its first letter.
          textDirection: firstStrongDirection(place),
          maxLines: maxLines,
          overflow: overflow,
        ),
      ),
    );
  }
}

/// [query], a place, in the phone's maps app (a geo: link, which Android
/// hands to Google Maps or whichever maps app the phone has), or where no
/// app takes it, in Google Maps on the web. Only on a tap, and only the
/// place goes.
Future<void> openPlace(String query) async {
  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse('geo:0,0?q=${Uri.encodeQueryComponent(query)}'),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // No maps app: the web, then.
  }
  if (opened) return;
  try {
    await launchUrl(
      Uri.https('www.google.com', '/maps/search/', {
        'api': '1',
        'query': query,
      }),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // Nothing on the phone opens either: there is nowhere to show it.
  }
}
