import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/files/file_bridge.dart';
import '../domain/draft.dart';

/// Where a file dropped onto the app should go.
///
/// Android reports a drop against the whole window — Flutter draws its
/// entire interface into one view, so there is nothing smaller to aim at —
/// which leaves the app to decide what the drop meant. The rule: if a
/// message is being written, the file is an attachment for it; otherwise
/// there is nothing sensible to attach it to and a new message is started
/// holding it.
///
/// The compose screen claims and releases the drop while it is on screen, so
/// the most recent one wins and closing it puts things back.
class DropTargets {
  void Function(List<IncomingFile>)? _handler;

  /// Deliberately a plain object behind a Provider rather than a Notifier:
  /// nothing on screen changes when the claim moves, and a Notifier cannot
  /// be written to from initState or dispose, which are exactly the two
  /// moments a screen claims and gives up the drop.
  void claim(void Function(List<IncomingFile>) handler) => _handler = handler;

  /// Only if it is still ours: a screen closing after another has opened
  /// must not take the newer one's claim with it.
  void release(void Function(List<IncomingFile>) handler) {
    // == rather than identical: a tear-off of the same method on the same
    // object is equal but not necessarily the same object, so identical
    // would never match and the claim would outlive the screen.
    if (_handler == handler) _handler = null;
  }

  void Function(List<IncomingFile>)? get current => _handler;
}

final dropTargetProvider = Provider<DropTargets>((ref) => DropTargets());

/// Read a dropped or pasted file into something a draft can carry.
///
/// Read now, not later: the file is a copy in this app's cache and Android
/// is free to clear it, while a draft may sit unsent for a day.
Future<List<DraftAttachment>> readIncoming(List<IncomingFile> files) async {
  final read = <DraftAttachment>[];
  for (final file in files) {
    try {
      read.add(
        DraftAttachment(
          fileName: file.name,
          mimeType: file.mimeType,
          bytes: await File(file.path).readAsBytes(),
        ),
      );
    } catch (e) {
      debugPrint('[myemail] could not read ${file.path}: $e');
    }
  }
  return read;
}
