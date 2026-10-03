import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/put_away_providers.dart';

/// Close everything over the app's first screen, as it is put away: a
/// Settings screen, an open message, a menu, a sheet, the folder drawer.
/// The app then comes back to the mail rather than to wherever it was left.
///
/// A screen with a guard is asked first (see [GuardsPutAway]): a message
/// being written goes to Drafts, and a sign-in, which is half done in
/// another app, stays, and everything under it with it. Says whether it got
/// all the way down.
Future<bool> closeForPutAway(
  NavigatorState navigator,
  PutAwayGuards guards,
) async {
  // Bounded, because a route that refused every pop would otherwise hold
  // this loop for good.
  for (var tries = 0; tries < 100 && navigator.mounted; tries++) {
    Route<dynamic>? top;
    // Looks at the top route without popping it.
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    final route = top;
    if (route == null) return true;
    if (route.isFirst) {
      // The first screen's own, such as its drawer, which closes as back
      // would close it and leaves the screen in place.
      if (route is ModalRoute && route.willHandlePopInternally) {
        navigator.pop();
        continue;
      }
      return true;
    }
    final guard = guards[route];
    if (guard != null && !await guard()) return false;
    // Closed already, by its guard or by the person.
    if (!route.isActive) continue;
    // Removed, not popped. A screen that asks before letting go has had
    // its say through its guard, or has nothing to lose; and the app is out
    // of sight, drawing no frames, so a closing slide would wait to play
    // until it came back, and greet it with the screen it was leaving.
    navigator.removeRoute(route);
  }
  return false;
}

/// For a screen that must deal with what it holds before the app, put away,
/// closes it: [whenPutAway] keeps it, and says whether the screen may go.
mixin GuardsPutAway<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// True once the screen may close; false to stay open.
  Future<bool> whenPutAway();

  Route<dynamic>? _route;
  PutAwayGuards? _guards;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    final PutAwayGuards guards = _guards ?? ref.read(putAwayGuardsProvider);
    _guards = guards;
    if (_route != null) guards.remove(_route!, whenPutAway);
    _route = route;
    if (route != null) guards.set(route, whenPutAway);
  }

  @override
  void dispose() {
    if (_route != null) _guards?.remove(_route!, whenPutAway);
    super.dispose();
  }
}

/// A screen that stays open when the app is put away, while [stays] says
/// so, or always.
///
/// For a sign-in. Signing in to Microsoft is approved in the Authenticator
/// app, and an app password is made in the browser: going there is part of
/// the task, and coming back to find the screen gone would undo it.
class StaysWhenPutAway extends ConsumerStatefulWidget {
  const StaysWhenPutAway({super.key, required this.child, this.stays});

  final Widget child;

  /// Asked as the app is put away; null means always.
  final bool Function()? stays;

  @override
  ConsumerState<StaysWhenPutAway> createState() => _StaysWhenPutAwayState();
}

class _StaysWhenPutAwayState extends ConsumerState<StaysWhenPutAway>
    with GuardsPutAway<StaysWhenPutAway> {
  @override
  Future<bool> whenPutAway() async => !(widget.stays?.call() ?? true);

  @override
  Widget build(BuildContext context) => widget.child;
}
