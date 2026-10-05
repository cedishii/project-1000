import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../store_scope.dart';

/// Full-screen photos with swipe and pinch-to-zoom. Only the visible page
/// (and its neighbours) are decoded.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({
    super.key,
    required this.photos,
    required this.initialIndex,
  });

  final List<PhotoRef> photos;
  final int initialIndex;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  final _zoom = TransformationController();

  /// While zoomed in, drags pan the photo instead of changing pages.
  bool _zoomed = false;

  void _onInteractionEnd(ScaleEndDetails _) {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  @override
  void dispose() {
    _controller.dispose();
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.read(context);
    final size = MediaQuery.sizeOf(context);
    final maxPx = (size.longestSide * MediaQuery.devicePixelRatioOf(context))
        .round();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: widget.photos.length > 1
            ? Text(
                '${_index + 1} / ${widget.photos.length}',
                style: const TextStyle(color: Colors.white),
              )
            : null,
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.photos.length,
        physics: _zoomed
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        onPageChanged: (i) => setState(() {
          _index = i;
          _zoom.value = Matrix4.identity();
          _zoomed = false;
        }),
        itemBuilder: (context, i) {
          final photo = widget.photos[i];
          return InteractiveViewer(
            transformationController: i == _index ? _zoom : null,
            panEnabled: _zoomed,
            onInteractionEnd: _onInteractionEnd,
            maxScale: 5,
            child: Center(
              child: Image(
                image: ResizeImage(
                  FileImage(File(store.location.resolve(photo.file))),
                  width: maxPx,
                  height: maxPx,
                  policy: ResizeImagePolicy.fit,
                ),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : const CircularProgressIndicator(color: Colors.white54),
                errorBuilder: (_, _, _) => const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 48,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'This photo file is missing.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
