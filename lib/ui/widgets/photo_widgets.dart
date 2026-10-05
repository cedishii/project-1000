import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../store_scope.dart';
import '../screens/photo_viewer_screen.dart';

/// A square thumbnail, decoded at display size and cached by Flutter's
/// image cache. Shows a placeholder if the file is missing.
class PhotoThumb extends StatelessWidget {
  const PhotoThumb({super.key, required this.photo, this.size = 96, this.onTap});

  final PhotoRef photo;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.read(context);
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: InkWell(
            onTap: onTap,
            child: Ink.image(
              image: ResizeImage(
                FileImage(File(store.location.resolve(photo.thumb))),
                width: px,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.cover,
              onImageError: (_, _) {},
              child: _MissingOverlay(photo: photo),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows an icon over thumbnails whose file can't be found.
class _MissingOverlay extends StatelessWidget {
  const _MissingOverlay({required this.photo});

  final PhotoRef photo;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.read(context);
    final exists = File(store.location.resolve(photo.thumb)).existsSync();
    if (exists) return const SizedBox.expand();
    return Center(
      child: Icon(Icons.broken_image_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant),
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
