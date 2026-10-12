import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../store_scope.dart';
import '../screens/photo_viewer_screen.dart';

/// A square thumbnail, decoded at display size and cached by Flutter's
/// image cache. Shows a placeholder if the photo can't be loaded.
class PhotoThumb extends StatefulWidget {
  const PhotoThumb({
    super.key,
    required this.photo,
    this.size = 96,
    this.onTap,
  });

  final PhotoRef photo;
  final double size;
  final VoidCallback? onTap;

  @override
  State<PhotoThumb> createState() => _PhotoThumbState();
}

class _PhotoThumbState extends State<PhotoThumb> {
  bool _missing = false;

  @override
  void didUpdateWidget(PhotoThumb old) {
    super.didUpdateWidget(old);
    if (old.photo.thumb != widget.photo.thumb) _missing = false;
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.read(context);
    final size = widget.size;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: InkWell(
            onTap: widget.onTap,
            child: Ink.image(
              image: ResizeImage(
                store.media.image(widget.photo.thumb),
                width: px,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.cover,
              onImageError: (_, _) {
                if (mounted && !_missing) setState(() => _missing = true);
              },
              child: _missing
                  ? Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

void openPhotoViewer(BuildContext context, List<PhotoRef> photos, int index) {
  Navigator.push(
    context,
    PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, _, _) =>
          PhotoViewerScreen(photos: photos, initialIndex: index),
      transitionsBuilder: (_, anim, _, child) =>
          FadeTransition(opacity: anim, child: child),
    ),
  );
}
