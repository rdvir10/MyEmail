import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/ui/messages/search_bar.dart';

/// Puts the search box out, the way a person does: the magnifier in the
/// title bar, or on a tablet the ribbon's Search. The box is not there
/// until it is asked for.
Future<void> openSearch(WidgetTester tester) async {
  if (find.byType(MessageSearchBar).evaluate().isNotEmpty) return;
  await tester.tap(find.byTooltip('Search').first);
  await tester.pumpAndSettle();
}

/// The search box's text field.
Finder get searchField => find.descendant(
      of: find.byType(MessageSearchBar),
      matching: find.byType(TextField),
    );
