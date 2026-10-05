import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../data/archive_location.dart';
import '../data/archive_repository.dart';
import '../data/models.dart';

/// Longest side of stored photos. Large enough for full-screen viewing on
/// any phone, small enough to keep the archive (and backups) manageable.
const int photoMaxSide = 2560;

/// Longest side of thumbnails.
const int thumbMaxSide = 480;

/// Copies picked photos into the archive and creates thumbnails.
///
/// New photos are first placed in `archive/pending/`. They only move to
/// `photos/` and `thumbs/` when the memory is saved, so a cancelled edit
/// (or a crash) never leaves unexplained files among the user's photos.
class PhotoStorage {
  PhotoStorage(this.location);

  final ArchiveLocation location;

  Directory get _pending => Directory(p.join(location.live.path, 'pending'));

  /// Removes leftovers from edits that were never saved.
  Future<void> clearPending() async {
    if (await _pending.exists()) await _pending.delete(recursive: true);
  }

  /// Copies [sourcePath] into the pending area and makes a thumbnail.
  /// The returned [PhotoRef] points at the pending files; call
  /// [commit] when the memory is saved.
  Future<PhotoRef> addPending(String sourcePath) async {
    await _pending.create(recursive: true);
    final id = ArchiveRepository.newId();
    var ext = p.extension(sourcePath).toLowerCase();
    if (!const ['.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif', '.gif']
        .contains(ext)) {
      ext = '.jpg';
    }
    final full = File(p.join(_pending.path, '$id$ext'));
    await File(sourcePath).copy(full.path);

    final bytes = await full.readAsBytes();
    final (width, height, thumbBytes) = await _thumbnail(bytes);
    final thumb = File(p.join(_pending.path, '${id}_t.jpg'));
    await thumb.writeAsBytes(thumbBytes, flush: true);

    return PhotoRef(
      id: id,
      memoryId: '',
      position: 0,
      file: p.join('pending', '$id$ext').replaceAll(r'\', '/'),
      thumb: p.join('pending', '${id}_t.jpg').replaceAll(r'\', '/'),
      width: width,
      height: height,
      createdAt: DateTime.now().toUtc(),
    );
  }

  static bool isPending(PhotoRef photo) => photo.file.startsWith('pending/');

  /// Moves pending photos into `photos/` and `thumbs/`, returning the
  /// refs with their final paths. Already-committed photos pass through.
  /// If a move fails, the ones already moved are put back.
  Future<List<PhotoRef>> commit(List<PhotoRef> photos) async {
    final out = <PhotoRef>[];
    try {
      await _commitInto(photos, out);
    } catch (_) {
      await rollback(photos, out);
      rethrow;
    }
    return out;
  }

  Future<void> _commitInto(List<PhotoRef> photos, List<PhotoRef> out) async {
    for (final ph in photos) {
      if (!isPending(ph)) {
        out.add(ph);
        continue;
      }
      final file = 'photos/${p.basename(ph.file)}';
      final thumb = 'thumbs/${ph.id}.jpg';
      await File(location.resolve(ph.file)).rename(location.resolve(file));
      await File(location.resolve(ph.thumb)).rename(location.resolve(thumb));
      out.add(PhotoRef(
        id: ph.id,
        memoryId: ph.memoryId,
        position: ph.position,
        file: file,
        thumb: thumb,
        width: ph.width,
        height: ph.height,
        createdAt: ph.createdAt,
      ));
    }
  }

  /// Undoes [commit]: moves files back to where [original] says.
  Future<void> rollback(List<PhotoRef> original, List<PhotoRef> committed) async {
    for (var i = 0; i < original.length && i < committed.length; i++) {
      final from = committed[i], to = original[i];
      if (from.file == to.file) continue;
      for (final (a, b) in [(from.file, to.file), (from.thumb, to.thumb)]) {
        try {
          await File(location.resolve(a)).rename(location.resolve(b));
        } catch (_) {}
      }
    }
  }

  /// Deletes pending photos that were not saved (e.g. edit cancelled).
  Future<void> discard(Iterable<PhotoRef> photos) async {
    for (final ph in photos.where(isPending)) {
      for (final rel in [ph.file, ph.thumb]) {
        try {
          await File(location.resolve(rel)).delete();
        } catch (_) {}
      }
    }
  }
}

/// Decodes [bytes] at thumbnail size (natively, honouring EXIF rotation)
/// and encodes a JPEG off the UI thread. Returns the photo's size too.
Future<(int?, int?, Uint8List)> _thumbnail(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final w = descriptor.width, h = descriptor.height;
  final scale = thumbMaxSide / (w > h ? w : h);
  final codec = await descriptor.instantiateCodec(
    targetWidth: scale < 1 ? (w * scale).round() : null,
    targetHeight: scale < 1 ? (h * scale).round() : null,
  );
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final tw = image.width, th = image.height;
  image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();

  final pixels = rgba.buffer.asUint8List();
  final jpeg = await Isolate.run(() => Uint8List.fromList(img.encodeJpg(
      img.Image.fromBytes(
          width: tw, height: th, bytes: pixels.buffer, numChannels: 4),
      quality: 82)));
  return (w, h, jpeg);
}
