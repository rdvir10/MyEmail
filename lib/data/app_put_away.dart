import 'dart:async';

import 'package:flutter/services.dart';

/// The app put away by the person using it: Home, Recents, another app.
///
/// Not the screen going off, a call coming in, a permission dialog, or the
/// app opening something itself (the file picker, the browser for a
/// sign-in, an attachment in another app), which Android reports to the
/// app in the same way. MainActivity tells them apart, and says so once
/// the app is out of sight.
Stream<void> appPutAwayEvents() {
  final events = StreamController<void>.broadcast();
  const MethodChannel('mailtree/leaving').setMethodCallHandler((call) async {
    if (call.method == 'putAway') events.add(null);
  });
  return events.stream;
}
