import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/widget/home_screen_surface.dart';
import '../data/widget/mailbox_widgets.dart';
import '../data/widget/widget_state_store.dart';

/// The home screen. main() overrides this with the Android one; everywhere
/// else it does nothing, so a test or the browser preview behaves the same
/// as a phone with no widget placed.
final homeScreenSurfaceProvider =
    Provider<HomeScreenSurface>((ref) => const NoHomeScreenSurface());

/// Which widget shows which mailbox, and when the app was last in front.
/// main() overrides this with the shared_preferences one, which is what the
/// background isolate also reads.
final widgetStateStoreProvider =
    Provider<WidgetStateStore>((ref) => MemoryWidgetStateStore());

final mailboxWidgetsProvider = Provider<MailboxWidgets>(
  (ref) => MailboxWidgets(
    surface: ref.watch(homeScreenSurfaceProvider),
    store: ref.watch(widgetStateStoreProvider),
  ),
);
