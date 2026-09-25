import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'folder_tree.dart' show kUnifiedInboxId;
import 'providers.dart';

/// The account of the folder on screen, or null in the unified Inbox, where
/// there is no single answer.
///
/// What a new meeting is from unless it was started from a message: the
/// account whose mail is in front of the person is the one they mean, the
/// way a new message from the same folder is.
final accountOnScreenProvider = Provider<String?>((ref) {
  final folderId = ref.watch(effectiveSelectedFolderIdProvider);
  if (folderId == null || folderId == kUnifiedInboxId) return null;
  return ref.watch(folderIndexProvider)[folderId]?.accountId;
});
