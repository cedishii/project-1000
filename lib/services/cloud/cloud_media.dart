import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/log.dart';
import '../../data/archive_repository.dart';
import '../../data/models.dart';
import '../media_store.dart';
import '../photo_storage.dart';
import 'cloud_migration.dart' show contentTypeFor;

/// Photos of a cloud account: the private `photos` bucket, one folder per
/// account (`<user id>/photos/…`, `thumbs/…`, `profile/…`; see
/// supabase/migrations/20261012000400_storage.sql).
///
/// Images are downloaded with the user's session (no public URLs) and
/// cached by Flutter's image cache. Photos picked while editing a memory
/// are kept in memory as "pending" until the memory is saved.
class CloudMedia implements MediaStore {
  CloudMedia(this.client);

  final SupabaseClient client;
  final _pending = <String, Uint8List>{};

  static const bucket = 'photos';

  String get _userId => client.auth.currentUser!.id;
  StorageFileApi get _files => client.storage.from(bucket);

  /// The storage key of an archive-relative [path].
  String keyOf(String path) => '$_userId/$path';

  static bool isPending(String path) => path.startsWith('pending/');

  /// Bytes of a pending photo or thumbnail.
  Uint8List? pendingBytes(String path) => _pending[path];

  @override
  ImageProvider image(String path) {
    final pending = _pending[path];
    if (pending != null) return MemoryImage(pending);
    final key = keyOf(path);
    return BytesImage('cloud:$key', () => _files.download(key));
  }

  @override
  Future<String?> localFile(String path) async {
    if (kIsWeb) return null;
    try {
      final file = File(
        p.join(Directory.systemTemp.path, 'p1000_cloud', _userId, path),
      );
      if (!await file.exists()) {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(await _files.download(keyOf(path)));
      }
      return file.path;
    } catch (e) {
      logError('Could not download $path', e);
      return null;
    }
  }

  @override
  Future<PhotoRef> addPending(XFile picked) async {
    final bytes = await picked.readAsBytes();
    final id = ArchiveRepository.newId();
    const known = ['.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif', '.gif'];
    var ext = p
        .extension(picked.name.isEmpty ? picked.path : picked.name)
        .toLowerCase();
    if (!known.contains(ext)) {
      // Browsers and some pickers give no file name; use the type.
      final type = picked.mimeType?.split('/').last.toLowerCase();
      ext = known.contains('.$type') ? '.$type' : '.jpg';
    }
    final (width, height, thumb) = await shrinkImage(
      bytes,
      thumbMaxSide,
      quality: 82,
    );
    final file = 'pending/$id$ext', thumbPath = 'pending/${id}_t.jpg';
    _pending[file] = bytes;
    _pending[thumbPath] = thumb.bytes;
    return PhotoRef(
      id: id,
      memoryId: '',
      position: 0,
      file: file,
      thumb: thumbPath,
      width: width,
      height: height,
      createdAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> discard(Iterable<PhotoRef> photos) async {
    for (final ph in photos) {
      _pending.remove(ph.file);
      _pending.remove(ph.thumb);
    }
  }

  /// Uploads [bytes] to [path]. Overwrites, so repeating an upload that
  /// may or may not have arrived is harmless (paths are unique per photo).
  Future<void> upload(String path, Uint8List bytes) => _files.uploadBinary(
    keyOf(path),
    bytes,
    fileOptions: FileOptions(contentType: contentTypeFor(path), upsert: true),
  );

  Future<void> copy(String from, String to) =>
      _files.copy(keyOf(from), keyOf(to));

  /// Removes files after their records are gone. A failure only leaves an
  /// unused file behind (listed by the `orphan_files` function).
  Future<void> remove(Iterable<String> paths) async {
    final keys = [for (final path in paths) keyOf(path)];
    if (keys.isEmpty) return;
    try {
      await _files.remove(keys);
    } catch (e) {
      logError('Could not remove ${keys.length} cloud files', e);
    }
  }
}
