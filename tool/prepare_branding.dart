// Prepares platform icon/splash source images from the official logo.
//
// The official logo (assets/branding/logo_original.png) is a wide banner.
// App icons must be square, so this script only performs technical
// preparation: it lifts the emblem (the face inside its white sticker
// outline) out of the banner pixel-for-pixel and places it on square
// canvases sized for each platform. No artwork is redrawn or altered.
//
// Run from the project root:
//   dart run tool/prepare_branding.dart   (also writes the web icons)
//   dart run flutter_launcher_icons
//   dart run flutter_native_splash:create

import 'dart:collection';
import 'dart:io';

import 'package:image/image.dart' as img;

/// Region of the banner that contains the emblem (above the title text).
const regionLeft = 270, regionTop = 40, regionRight = 755, regionBottom = 425;

/// Background colour used where a platform forbids transparency.
/// Sampled from the banner's own wall colour.
final background = img.ColorRgba8(0x29, 0x30, 0x2e, 255);

void main() {
  final source = img.decodePng(
    File('assets/branding/logo_original.png').readAsBytesSync(),
  )!;

  final emblem = _extractEmblem(source);
  _write('assets/branding/emblem.png', emblem);

  // Opaque square icon (iOS, legacy Android): emblem on the banner's
  // wall colour, with breathing room.
  _write(
    'assets/branding/icon_square.png',
    _place(emblem, canvas: 1024, fraction: 0.84, fill: background),
  );

  // Android adaptive icon foreground: emblem inside the 66/108 safe zone.
  _write(
    'assets/branding/icon_adaptive_foreground.png',
    _place(emblem, canvas: 1024, fraction: 66 / 108),
  );

  // Android 12+ splash icon: must fit within a circle 2/3 of the canvas.
  _write(
    'assets/branding/splash_emblem.png',
    _place(emblem, canvas: 1024, fraction: 0.6),
  );

  // Web: favicon, app icons, and maskable icons (emblem inside the 80%
  // safe zone, on the wall colour).
  _write('web/favicon.png', _place(emblem, canvas: 64, fraction: 0.96));
  for (final size in [192, 512]) {
    _write(
      'web/icons/Icon-$size.png',
      _place(emblem, canvas: size, fraction: 0.84, fill: background),
    );
    _write(
      'web/icons/Icon-maskable-$size.png',
      _place(emblem, canvas: size, fraction: 0.66, fill: background),
    );
  }
}

/// Flood-fills the background from the region's edges, stopping at the
/// white sticker outline; everything not reached is the emblem.
img.Image _extractEmblem(img.Image s) {
  final w = regionRight - regionLeft, h = regionBottom - regionTop;
  bool isWhite(int x, int y) {
    final p = s.getPixel(regionLeft + x, regionTop + y);
    return p.r > 225 && p.g > 225 && p.b > 225;
  }

  final outside = List.generate(h, (_) => List.filled(w, false));
  final queue = Queue<(int, int)>();
  void seed(int x, int y) {
    if (!outside[y][x] && !isWhite(x, y)) {
      outside[y][x] = true;
      queue.add((x, y));
    }
  }

  for (var x = 0; x < w; x++) {
    seed(x, 0);
    seed(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    seed(0, y);
    seed(w - 1, y);
  }
  while (queue.isNotEmpty) {
    final (x, y) = queue.removeFirst();
    if (x > 0) seed(x - 1, y);
    if (x < w - 1) seed(x + 1, y);
    if (y > 0) seed(x, y - 1);
    if (y < h - 1) seed(x, y + 1);
  }

  // Keep only the region connected to the emblem's centre, so specks of
  // the background that happen to be enclosed by white are dropped.
  final inside = List.generate(h, (_) => List.filled(w, false));
  final cx = 512 - regionLeft, cy = 240 - regionTop;
  inside[cy][cx] = true;
  queue.add((cx, cy));
  while (queue.isNotEmpty) {
    final (x, y) = queue.removeFirst();
    for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
      final nx = x + dx, ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      if (outside[ny][nx] || inside[ny][nx]) continue;
      inside[ny][nx] = true;
      queue.add((nx, ny));
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      outside[y][x] = !inside[y][x];
    }
  }

  // Tight bounding box of the emblem.
  var minX = w, minY = h, maxX = 0, maxY = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (!outside[y][x]) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }

  final ew = maxX - minX + 1, eh = maxY - minY + 1;
  final side = ew > eh ? ew : eh;
  final out = img.Image(width: side, height: side, numChannels: 4);
  final ox = (side - ew) ~/ 2, oy = (side - eh) ~/ 2;
  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      if (outside[y][x]) continue;
      // Soften the outermost edge by one pixel to avoid jagged corners.
      var edge = 0;
      for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h || outside[ny][nx]) edge++;
      }
      final p = s.getPixel(regionLeft + x, regionTop + y);
      out.setPixelRgba(
        ox + x - minX,
        oy + y - minY,
        p.r,
        p.g,
        p.b,
        edge > 0 ? 170 : 255,
      );
    }
  }
  return out;
}

img.Image _place(
  img.Image emblem, {
  required int canvas,
  required double fraction,
  img.Color? fill,
}) {
  final out = img.Image(width: canvas, height: canvas, numChannels: 4);
  if (fill != null) img.fill(out, color: fill);
  final size = (canvas * fraction).round();
  final scaled = img.copyResize(
    emblem,
    width: size,
    height: size,
    interpolation: img.Interpolation.cubic,
  );
  img.compositeImage(
    out,
    scaled,
    dstX: (canvas - size) ~/ 2,
    dstY: (canvas - size) ~/ 2,
  );
  return out;
}

void _write(String path, img.Image image) {
  File(path).writeAsBytesSync(img.encodePng(image));
  stdout.writeln('wrote $path (${image.width}x${image.height})');
}
