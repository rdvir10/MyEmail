import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/ui_state_store.dart';
import 'state/providers.dart';
import 'theme/app_theme.dart';
import 'ui/shell/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loaded before the first frame so the tree renders in its remembered shape
  // immediately rather than snapping into it a moment later.
  final uiState = await PrefsUiStateStore.open();
  runApp(
    ProviderScope(
      overrides: [uiStateStoreProvider.overrideWithValue(uiState)],
      child: const MailTreeApp(),
    ),
  );
}

class MailTreeApp extends StatelessWidget {
  const MailTreeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MailTree',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      // Light and dark follow the system, as planned.
      themeMode: ThemeMode.system,
      home: const AppShell(),
    );
  }
}
