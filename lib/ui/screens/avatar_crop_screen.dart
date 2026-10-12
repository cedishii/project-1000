import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/photo_storage.dart';
import '../feedback.dart';

/// Size of the saved profile picture (square).
const int avatarSize = 720;

/// Lets the user move and zoom a photo inside a circle, then returns the
/// cropped square as JPEG bytes (or null if cancelled). Everything stays
/// on the phone.
class AvatarCropScreen extends StatefulWidget {
  const AvatarCropScreen({super.key, required this.bytes});

  /// The picked image file's contents.
  final Uint8List bytes;

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  final _transform = TransformationController();
  ui.Image? _image;
  Object? _error;
  bool _saving = false;
  double _viewport = 0;
  double _baseScale = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = widget.bytes;
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      // Plenty for a 720 px crop, even when zoomed in.
      final scale = 2400 / math.max(descriptor.width, descriptor.height);
      final codec = await descriptor.instantiateCodec(
        targetWidth: scale < 1 ? (descriptor.width * scale).round() : null,
        targetHeight: scale < 1 ? (descriptor.height * scale).round() : null,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (mounted) setState(() => _image = frame.image);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    _image?.dispose();
    super.dispose();
  }

  /// Centres the photo so it just covers the circle.
  void _reset(double viewport) {
    final image = _image!;
    _viewport = viewport;
    _baseScale = viewport / math.min(image.width, image.height);
    final w = image.width * _baseScale, h = image.height * _baseScale;
    _transform.value = Matrix4.identity()
      ..translateByDouble(-(w - viewport) / 2, -(h - viewport) / 2, 0, 1);
  }

  Future<void> _save() async {
    final image = _image;
    if (image == null || _viewport == 0) return;
    setState(() => _saving = true);
    try {
      final m = _transform.value;
      final zoom = m.getMaxScaleOnAxis();
      final tx = m.getTranslation().x, ty = m.getTranslation().y;
      // The visible square, in image pixels.
      final scale = zoom * _baseScale;
      final src = Rect.fromLTWH(
        -tx / scale,
        -ty / scale,
        _viewport / scale,
        _viewport / scale,
      );
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        image,
        src,
        const Rect.fromLTWH(0, 0, avatarSize + 0.0, avatarSize + 0.0),
        Paint()..filterQuality = FilterQuality.high,
      );
      final out = await recorder.endRecording().toImage(avatarSize, avatarSize);
      final rgba = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      out.dispose();
      final Uint8List jpeg = await encodeRgbaAsJpeg(
        rgba,
        avatarSize,
        avatarSize,
        quality: 88,
      );
      if (mounted) Navigator.pop(context, jpeg);
    } catch (e, s) {
      if (mounted) {
        setState(() => _saving = false);
        showError(context, e, s);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Move and zoom'),
        titleTextStyle: const TextStyle(color: Colors.white, fontSize: 20),
        actions: [
          TextButton(
            onPressed: image == null || _saving ? null : _save,
            child: const Text('Use photo'),
          ),
        ],
      ),
      body: _error != null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'This photo couldn\'t be opened. Try another one.',
                  style: TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : image == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, box) {
                final viewport = math.min(box.maxWidth, box.maxHeight) - 32;
                if (_viewport == 0) {
                  _reset(viewport);
                } else if (viewport != _viewport) {
                  // Rotated: re-fit after this frame (the controller
                  // can't change while the viewer is being built).
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _reset(viewport));
                  });
                }
                return Center(
                  child: SizedBox.square(
                    dimension: viewport,
                    child: Stack(
                      children: [
                        ClipRect(
                          child: InteractiveViewer(
                            transformationController: _transform,
                            constrained: false,
                            minScale: 1,
                            maxScale: 6,
                            boundaryMargin: EdgeInsets.zero,
                            child: SizedBox(
                              width: image.width * _baseScale,
                              height: image.height * _baseScale,
                              child: RawImage(image: image, fit: BoxFit.fill),
                            ),
                          ),
                        ),
                        const IgnorePointer(
                          child: CustomPaint(
                            size: Size.infinite,
                            painter: _CircleMask(),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _CircleMask extends CustomPainter {
  const _CircleMask();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Path()..addOval(rect.deflate(2));
    final mask = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect),
      circle,
    );
    canvas.drawPath(mask, Paint()..color = Colors.black54);
    canvas.drawPath(
      circle,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CircleMask oldDelegate) => false;
}
