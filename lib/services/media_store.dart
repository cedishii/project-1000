import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImmutableBuffer;

import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';

import '../data/archive_location.dart';
import '../data/models.dart';
import 'photo_storage.dart';

/// How screens show and read the archive's photos (paths like
/// `photos/<id>.jpg`, `thumbs/<id>.jpg`, `profile/<id>.jpg`), wherever
/// they are kept: [LocalMedia] on this phone, CloudMedia in the account's
/// private storage.
abstract interface class MediaStore {
  /// The image at [path], for display. Fails to load (so `errorBuilder`
  /// shows) if the file doesn't exist.
  ImageProvider image(String path);

  /// A file on this device holding [path]'s image (downloaded first if
  /// needed), or null if it isn't available. Used by the PDF export.
  Future<String?> localFile(String path);

  /// Prepares a picked photo for a memory being edited: a copy and a
  /// thumbnail, kept as "pending" until the memory is saved.
  Future<PhotoRef> addPending(XFile picked);

  /// Throws away pending photos that were not saved.
  Future<void> discard(Iterable<PhotoRef> photos);
}

class LocalMedia implements MediaStore {
  LocalMedia(this.location, this.photos);

  final ArchiveLocation location;
  final PhotoStorage photos;

  @override
  ImageProvider image(String path) => FileImage(File(location.resolve(path)));

  @override
  Future<String?> localFile(String path) async {
    final resolved = location.resolve(path);
    return await File(resolved).exists() ? resolved : null;
  }

  @override
  Future<PhotoRef> addPending(XFile picked) => photos.addPending(picked.path);

  @override
  Future<void> discard(Iterable<PhotoRef> photos) =>
      this.photos.discard(photos);
}

/// An [ImageProvider] over bytes fetched by [load], cached by Flutter's
/// image cache under [key]. Used for photos that aren't local files.
class BytesImage extends ImageProvider<BytesImage> {
  const BytesImage(this.key, this.load);

  final String key;
  final Future<Uint8List> Function() load;

  @override
  Future<BytesImage> obtainKey(ImageConfiguration configuration) async => this;

  @override
  ImageStreamCompleter loadImage(BytesImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: () async {
          final bytes = await load();
          return decode(await ImmutableBuffer.fromUint8List(bytes));
        }(),
        scale: 1,
        debugLabel: key.key,
      );

  @override
  bool operator ==(Object other) => other is BytesImage && other.key == key;

  @override
  int get hashCode => key.hashCode;
}
