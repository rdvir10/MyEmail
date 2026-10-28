import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/files/draft_files.dart';
import '../../domain/draft.dart';
import '../../state/attachment_providers.dart' show pictureShrinkerProvider;

/// The sizes a picture can be sent at, by its longer side.
enum PictureSize {
  small('Small', 800),
  medium('Medium', 1280),
  large('Large', 1920);

  const PictureSize(this.label, this.longSide);

  final String label;
  final int longSide;
}

/// Pictures this big in all, coming into a message, are offered smaller.
const offerSmallerOver = 1024 * 1024;

/// A picture attached as a file that can go smaller: a photo or a
/// screenshot. Not one shown in the text by its Content-ID, which Insert
/// Pictures has made fit already, and not a GIF, which would stop moving.
bool isShrinkablePicture(DraftAttachment a) =>
    a.contentId == null &&
    const {
      'image/jpeg',
      'image/jpg',
      'image/pjpeg',
      'image/png',
      'image/heic',
      'image/heif',
      'image/webp',
    }.contains(a.mimeType.toLowerCase());

/// Pictures that have just come into a message, shared, forwarded or
/// attached, offered smaller as they arrive, where they weigh more than
/// [offerSmallerOver] in all: Small, Medium or Large, each saying what the
/// pictures would weigh, or Actual size. Ron asked for it (3.7.2).
///
/// What each picture of [added] becomes, by the picture: empty where they
/// stay as they are.
Future<Map<DraftAttachment, DraftAttachment>> offerSmallerPictures(
  BuildContext context,
  List<DraftAttachment> added,
) async {
  final pictures = [
    for (final a in added)
      if (isShrinkablePicture(a)) a,
  ];
  if (pictures.fold(0, (sum, a) => sum + a.size) <= offerSmallerOver) {
    return const {};
  }
  return await showModalBottomSheet<Map<DraftAttachment, DraftAttachment>>(
        context: context,
        showDragHandle: true,
        builder: (_) => SmallerPicturesSheet(pictures: pictures),
      ) ??
      const {};
}

/// The choice of sizes, each one's weight filled in as it is worked out.
class SmallerPicturesSheet extends ConsumerStatefulWidget {
  const SmallerPicturesSheet({super.key, required this.pictures});

  final List<DraftAttachment> pictures;

  @override
  ConsumerState<SmallerPicturesSheet> createState() =>
      _SmallerPicturesSheetState();
}

class _SmallerPicturesSheetState extends ConsumerState<SmallerPicturesSheet> {
  /// Each size's pictures, made one size after another, Medium first as the
  /// one most often wanted, so a choice made early waits the least.
  final _made = <PictureSize, Future<Map<DraftAttachment, DraftAttachment>>>{};

  /// What each size's pictures weigh, once made.
  final _weighs = <PictureSize, int>{};

  /// The size chosen before it was ready, which is waited for.
  PictureSize? _waiting;

  @override
  void initState() {
    super.initState();
    final shrinker = ref.read(pictureShrinkerProvider);
    Future<void> before = Future.value();
    for (final size in const [
      PictureSize.medium,
      PictureSize.small,
      PictureSize.large,
    ]) {
      final made = before.then((_) => _make(shrinker, size));
      _made[size] = made;
      before = made;
    }
  }

  Future<Map<DraftAttachment, DraftAttachment>> _make(
    PictureShrinker shrinker,
    PictureSize size,
  ) async {
    final made = <DraftAttachment, DraftAttachment>{};
    for (final picture in widget.pictures) {
      DraftAttachment? smaller;
      try {
        smaller = await shrinker.shrink(picture, size.longSide);
      } catch (e) {
        debugPrint('[myemail] could not make ${picture.fileName} smaller: $e');
      }
      // Left as it is where it would not come out smaller: a picture that
      // small already, or one the phone could not read.
      if (smaller != null && smaller.size < picture.size) made[picture] = smaller;
    }
    if (mounted) setState(() => _weighs[size] = _weight(made));
    return made;
  }

  int _weight([Map<DraftAttachment, DraftAttachment> made = const {}]) =>
      widget.pictures.fold(0, (sum, p) => sum + (made[p] ?? p).size);

  Future<void> _choose(PictureSize size) async {
    setState(() => _waiting = size);
    final made = await _made[size]!;
    if (mounted) Navigator.of(context).pop(made);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final n = widget.pictures.length;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n == 1
                      ? 'Make the picture smaller?'
                      : 'Make the pictures smaller?',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  '${n == 1 ? 'One picture' : '$n pictures'}, '
                  '${readableBytes(_weight())}',
                  style: muted,
                ),
              ],
            ),
          ),
          for (final size in PictureSize.values)
            ListTile(
              key: ValueKey('smaller-${size.name}'),
              title: Text(size.label),
              trailing: switch (_weighs[size]) {
                final weighs? => Text(readableBytes(weighs)),
                null => const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              },
              onTap: _waiting == null ? () => _choose(size) : null,
            ),
          ListTile(
            key: const ValueKey('smaller-actual'),
            title: const Text('Actual size'),
            trailing: Text(readableBytes(_weight())),
            onTap: _waiting == null ? () => Navigator.of(context).pop() : null,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
