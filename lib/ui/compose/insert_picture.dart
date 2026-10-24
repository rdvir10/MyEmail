import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/file_types.dart';
import '../../state/attachment_providers.dart' show fileBridgeProvider;
import '../common/bottom_message.dart';
import 'html_editor.dart';

/// Outlook's Insert Pictures: a photo put where the cursor is, from the
/// pictures on the phone or taken now, scaled to a sensible size first
/// (1600 pixels on its longer side, upright, a JPEG), and sent inside the
/// message rather than attached. It goes in as data, and the send turns it
/// into a part of the message of its own, as a pasted picture is.
Future<void> insertPicture(
  BuildContext context,
  WidgetRef ref,
  HtmlEditorController editor,
) async {
  final source = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('From your pictures'),
            onTap: () => Navigator.of(sheet).pop('gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.of(sheet).pop('camera'),
          ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) => messenger?.showSnackBar(
        SnackBar(duration: kBottomMessage, content: Text(text)),
      );

  final bridge = ref.read(fileBridgeProvider);
  String? path;
  try {
    if (source == 'camera') {
      path = await bridge.takePhoto();
    } else {
      final picked = await FilePicker.pickFiles(type: FileType.image);
      if (picked.isEmpty) return;
      final file = picked.single;
      // The picker hands over what it can read, not always a file of its
      // own: the bytes are copied to one the scaling can open.
      path = file.path;
      if (path == null) {
        final temporary = await getTemporaryDirectory();
        final copy = File(
          '${temporary.path}/picture-${DateTime.now().microsecondsSinceEpoch}'
          '.${file.extension ?? 'jpg'}',
        );
        await copy.writeAsBytes(await file.readAsBytes());
        path = copy.path;
      }
    }
  } catch (e) {
    say(source == 'camera'
        ? 'Could not take a photo.'
        : 'Could not read the picture.');
    return;
  }
  if (path == null) return;
  try {
    final scaled = await bridge.scaleImage(path);
    final bytes = await File(scaled).readAsBytes();
    final type = mimeTypeForFile(scaled);
    await editor.insertHtml(pictureHtml(
      type.startsWith('image/') ? type : 'image/jpeg',
      base64Encode(bytes),
    ));
  } catch (e) {
    say('Could not put the picture in.');
  }
}

/// A picture in the text, as data, no wider than the message.
String pictureHtml(String mimeType, String base64) =>
    '<img src="data:$mimeType;base64,$base64" alt="" '
    'style="max-width:100%;height:auto">';
