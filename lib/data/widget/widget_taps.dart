import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, debugPrint;
import 'package:home_widget/home_widget.dart';

/// Tapping a widget opens the folder it was counting.
///
/// The widget hands over a `myemail://folder?id=…` link, which arrives one of
/// two ways: on the intent that started the app, or — if the app was already
/// running — through the plugin's stream. Both are needed, and they are the
/// same answer, so callers take one callback and get it from wherever it
/// turns up.

/// The folder a link names, or null if it is not one of ours.
String? folderFromWidgetLink(Uri? uri) {
  if (uri == null) return null;
  if (uri.scheme != 'myemail' || uri.host != 'folder') return null;
  final id = uri.queryParameters['id'];
  if (id == null || id.isEmpty) return null;
  return id;
}

/// The folder the app was opened on, if it was opened by tapping a widget.
Future<String?> folderAppOpenedOn() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return folderFromWidgetLink(
      await HomeWidget.initiallyLaunchedFromHomeWidget(),
    );
  } catch (e) {
    debugPrint('[myemail] could not read the widget link: $e');
    return null;
  }
}

/// Later taps, while the app is already open.
StreamSubscription<Uri?>? listenForWidgetTaps(
  void Function(String folderId) onFolder,
) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return HomeWidget.widgetClicked.listen((uri) {
      final folderId = folderFromWidgetLink(uri);
      if (folderId != null) onFolder(folderId);
    });
  } catch (e) {
    debugPrint('[myemail] could not listen for widget taps: $e');
    return null;
  }
}
