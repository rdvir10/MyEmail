import 'package:flutter/material.dart';

/// Outlook's blue. Used as the Material 3 seed so the whole palette derives
/// from it rather than being hand-picked per surface.
const outlookBlue = Color(0xFF0F6CBD);

/// Compact by intent: a mail client lives or dies on how many rows fit on
/// screen, and Material's default density wastes a lot of vertical space.
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: outlookBlue,
    brightness: brightness,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: scheme.surface,
    dividerTheme: DividerThemeData(
      space: 1,
      thickness: 1,
      color: scheme.outlineVariant.withValues(alpha: 0.5),
    ),
    listTileTheme: const ListTileThemeData(
      dense: true,
      minVerticalPadding: 0,
      horizontalTitleGap: 8,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
  );
}

/// Icons per folder role, chosen to read like Outlook's set.
class FolderIcons {
  static IconData inbox = Icons.inbox_outlined;
  static IconData drafts = Icons.drafts_outlined;
  static IconData sent = Icons.send_outlined;
  static IconData deleted = Icons.delete_outline;
  static IconData junk = Icons.report_gmailerrorred_outlined;
  static IconData archive = Icons.archive_outlined;
  static IconData outbox = Icons.outbox_outlined;
  static IconData unified = Icons.all_inbox_outlined;
  static IconData folder = Icons.folder_outlined;
  static IconData folderOpen = Icons.folder_open_outlined;
}
