import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme/app_theme.dart';
import 'ui/shell/app_shell.dart';

void main() {
  runApp(const ProviderScope(child: MailTreeApp()));
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
