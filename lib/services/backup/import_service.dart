import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:project_1000/core/log.dart';

import '../../data/archive_location.dart';
import '../../data/database.dart';
import '../../data/models.dart';
import '../background.dart';
import 'backup_format.dart';

/// A backup that has been fully unpacked and checked, waiting for the
/// user to confirm. Nothing in the live archive has been touched yet.
class ImportPreview {
  ImportPreview({
    required this.exportedAt,
    required this.appVersion,
    required this.itemCount,
    required this.memoryCount,
    required this.photoCount,
    required this.missingPhotoCount,
    required this.itemIds,
    required this.data,
  });

  final DateTime? exportedAt;
  final String appVersion;
  final int itemCount;
  final int memoryCount;
  final int photoCount;

  /// Photos referenced by the backup whose files are missing or damaged.
  final int missingPhotoCount;
  final Set<String> itemIds;
  final Map<String, Object?> data;
}

/// Step 1: unpack [zipPath] into the `archive_incoming` folder and check
/// everything: format, version, checksums, data consistency, photos.
///
/// Throws [ImportException] with a user-facing reason on failure, after
/// removing the partial `archive_incoming` folder.
Future<ImportPreview> prepareImport(
  String zipPath,
  ArchiveLocation location, {
  void Function(double progress)? onProgress,
}) async {
  final incoming = location.incoming;
  if (await incoming.exists()) await incoming.delete(recursive: true);
  try {
    final path = incoming.path;
    return await runWithProgress(
      (report) => _unpackAndValidate(zipPath, path, report),
      onProgress: onProgress,
    );
  } catch (e, s) {
    logError('Import validation failed', e, s);
    if (await incoming.exists()) {
      try {
        await incoming.delete(recursive: true);
      } catch (_) {}
    }
    if (e is ImportException) rethrow;
    if (e is FileSystemException && _outOfSpace(e)) {
      throw ImportException(ImportProblem.outOfSpace, '$e');
    }
    if (e is FileSystemException) {
      throw ImportException(ImportProblem.unreadable, '$e');
    }
    throw ImportException(ImportProblem.corrupted, '$e');
  }
}

/// Step 2: build the new database inside `archive_incoming` from the
/// validated preview. The live archive is still untouched.
///
/// Photos whose files were missing/damaged are left out (the user agreed
/// to this when the preview reported them).
Future<void> buildIncomingArchive(
  ImportPreview preview,
  ArchiveLocation location, {
  DatabaseFactory? factory,
}) async {
  final dir = location.incoming;
  final db = await openArchiveDatabase(
    ArchiveLocation.dbPathIn(dir),
    factory: factory,
  );
  try {
    await db.transaction((txn) async {
      final batch = txn.batch();
      final data = preview.data;
      for (final MapEntry(:key, :value)
          in (data['settings'] as Map? ?? const {}).entries) {
        batch.insert('settings', {'key': key, 'value': '$value'});
      }
      for (final i in (data['items'] as List).cast<Map>()) {
        batch.insert('items', {
          'id': i['id'],
          'number': i['number'],
          'position': i['position'],
          'title': i['title'],
          'description': i['description'] ?? '',
          'is_completed': i['isCompleted'] == true ? 1 : 0,
          'completed_on': i['completedOn'],
          'created_at': i['createdAt'],
          'updated_at': i['updatedAt'],
        });
        for (final m in (i['memories'] as List).cast<Map>()) {
          batch.insert('memories', {
            'id': m['id'],
            'item_id': i['id'],
            'position': m['position'],
            'title': m['title'] ?? '',
            'body': m['text'] ?? '',
            'date': m['date'],
            'location': m['location'] ?? '',
            'created_at': m['createdAt'],
            'updated_at': m['updatedAt'],
          });
          final tags = (m['hashtags'] as List).cast<String>();
          for (var t = 0; t < tags.length; t++) {
            batch.insert('memory_tags', {
              'memory_id': m['id'],
              'position': t,
              'tag': tags[t],
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
          for (final ph in (m['photos'] as List).cast<Map>()) {
            if (ph['_skip'] == true) continue;
            batch.insert('photos', {
              'id': ph['id'],
              'memory_id': m['id'],
              'position': ph['position'],
              'file': ph['file'],
              'thumb': ph['thumb'],
              'width': ph['width'],
              'height': ph['height'],
              'created_at': ph['createdAt'],
            });
          }
        }
      }
      await batch.commit(noResult: true);
    });
  } finally {
    await db.close();
  }
  final work = Directory(p.join(dir.path, '_import'));
  if (await work.exists()) await work.delete(recursive: true);
  await ArchiveLocation.photosIn(dir).create(recursive: true);
  await ArchiveLocation.thumbsIn(dir).create(recursive: true);
}

/// Discards a prepared import (user cancelled).
Future<void> cancelImport(ArchiveLocation location) async {
  if (await location.incoming.exists()) {
    await location.incoming.delete(recursive: true);
  }
}

bool _outOfSpace(FileSystemException e) {
  final c = e.osError?.errorCode;
  return c == 28 || c == 112 || c == 39;
}

// ---------------------------------------------------------------------------
// Runs on a background isolate.

ImportPreview _unpackAndValidate(
  String zipPath,
  String incomingPath,
  void Function(double) report,
) {
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (e) {
      throw ImportException(ImportProblem.notABackup, 'not a zip: $e');
    }
    final entries = {
      for (final f in archive)
        if (f.isFile) f.name: f,
    };

    // --- manifest
    final manifestEntry = entries[manifestName];
    if (manifestEntry == null) {
      throw ImportException(ImportProblem.notABackup, 'no manifest');
    }
    final manifest = _decodeJson(manifestEntry, 'manifest');
    if (manifest['format'] != backupFormatId) {
      throw ImportException(ImportProblem.notABackup, 'format id');
    }
    final bfv = manifest['backupFormatVersion'];
    final dfv = manifest['dataFormatVersion'];
    if (bfv is! int || dfv is! int || bfv < 1 || dfv < 1) {
      throw ImportException(ImportProblem.corrupted, 'versions');
    }
    if (bfv > backupFormatVersion || dfv > dataFormatVersion) {
      throw ImportException(ImportProblem.newerVersion, 'v$bfv/$dfv');
    }

    // --- data.json, checked against the manifest's checksum
    final dataEntry = entries[dataName];
    final dataInfo = manifest['data'];
    if (dataEntry == null || dataInfo is! Map) {
      throw ImportException(ImportProblem.corrupted, 'no data.json');
    }
    final dataBytes = dataEntry.readBytes() ?? Uint8List(0);
    if (sha256.convert(dataBytes).toString() != dataInfo['sha256']) {
      throw ImportException(ImportProblem.corrupted, 'data checksum');
    }
    Map<String, Object?> data;
    try {
      data = (jsonDecode(utf8.decode(dataBytes)) as Map)
          .cast<String, Object?>();
    } catch (e) {
      throw ImportException(ImportProblem.corrupted, 'data json: $e');
    }
    data = _migrateData(data, dfv);
    _validate(data);

    // --- photos: extract each referenced file and verify its checksum
    final fileInfo = (manifest['files'] as Map? ?? const {});
    final referenced = <Map>[
      for (final i in (data['items'] as List).cast<Map>())
        for (final m in (i['memories'] as List).cast<Map>())
          ...(m['photos'] as List).cast<Map>(),
    ];
    final good = <String>{};
    var done = 0;
    for (final ph in referenced) {
      if (++done % 10 == 0) report(done / referenced.length);
      for (final rel in [ph['file'] as String, ph['thumb'] as String]) {
        if (good.contains(rel)) continue;
        if (_extractVerified(entries[rel], fileInfo[rel], incomingPath, rel)) {
          good.add(rel);
        }
      }
    }
    var missing = 0;
    for (final ph in referenced) {
      final hasFile = good.contains(ph['file']);
      final hasThumb = good.contains(ph['thumb']);
      if (!hasFile && !hasThumb) {
        ph['_skip'] = true; // nothing to show; leave this photo out
        missing++;
      } else if (!hasFile) {
        ph['file'] = ph['thumb']; // salvage: small version only
        missing++;
      } else if (!hasThumb) {
        ph['thumb'] = ph['file'];
      }
    }

    final items = (data['items'] as List).cast<Map>();
    return ImportPreview(
      exportedAt: DateTime.tryParse('${manifest['exportedAt']}'),
      appVersion: '${manifest['appVersion'] ?? ''}',
      itemCount: items.length,
      memoryCount: [for (final i in items) ...(i['memories'] as List)].length,
      photoCount: referenced.length,
      missingPhotoCount: missing,
      itemIds: {for (final i in items) i['id'] as String},
      data: data,
    );
  } finally {
    input.closeSync();
  }
}

Map<String, Object?> _decodeJson(ArchiveFile f, String what) {
  try {
    final bytes = f.readBytes() ?? Uint8List(0);
    return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
  } catch (e) {
    throw ImportException(ImportProblem.corrupted, '$what json: $e');
  }
}

/// Writes one media file into the incoming archive if it is present and
/// matches its recorded checksum. Returns false (and writes nothing) if it
/// is missing or damaged. Out-of-space errors are rethrown.
bool _extractVerified(
  ArchiveFile? entry,
  Object? info,
  String incomingPath,
  String rel,
) {
  if (entry == null || info is! Map || !isSafeMediaPath(rel)) return false;
  final target = File(p.join(incomingPath, rel));
  target.parent.createSync(recursive: true);
  final out = OutputFileStream(target.path);
  try {
    entry.writeContent(out);
    out.closeSync();
  } on FileSystemException {
    out.closeSync();
    rethrow;
  } catch (e) {
    out.closeSync();
    if (target.existsSync()) target.deleteSync();
    return false;
  }
  final ok =
      target.lengthSync() == info['size'] &&
      sha256.convert(target.readAsBytesSync()).toString() == info['sha256'];
  if (!ok) target.deleteSync();
  return ok;
}

/// Upgrades older data.json versions to the current one. Version 1 is the
/// first, so there is nothing to convert yet.
Map<String, Object?> _migrateData(Map<String, Object?> data, int fromVersion) {
  // Future: if (fromVersion < 2) { ...convert v1 → v2... }
  return data;
}

/// Checks data.json is internally consistent. Any problem rejects the
/// whole backup: a half-understood archive is never imported.
void _validate(Map<String, Object?> data) {
  Never bad(String why) =>
      throw ImportException(ImportProblem.invalidData, why);
  bool isTimestamp(Object? v) => v is String && DateTime.tryParse(v) != null;
  bool isDate(Object? v) {
    if (v is! String) return false;
    try {
      CalendarDate.parse(v);
      return true;
    } on FormatException {
      return false;
    }
  }

  final items = data['items'];
  if (items is! List) bad('items');
  if (items.length > maxItems) bad('too many items');
  final settings = data['settings'];
  if (settings != null && settings is! Map) bad('settings');

  final ids = <String>{};
  final numbers = <int>{};
  for (final i in items) {
    if (i is! Map) bad('item');
    final id = i['id'], number = i['number'];
    if (id is! String || id.isEmpty || !ids.add(id)) bad('item id');
    if (number is! int ||
        number < 1 ||
        number > maxItems ||
        !numbers.add(number)) {
      bad('item number');
    }
    if (i['position'] is! int) bad('position');
    if (i['title'] is! String) bad('title');
    if (i['description'] != null && i['description'] is! String) bad('desc');
    if (i['isCompleted'] is! bool) bad('isCompleted');
    if (i['completedOn'] != null && !isDate(i['completedOn'])) {
      bad('completedOn');
    }
    if (!isTimestamp(i['createdAt']) || !isTimestamp(i['updatedAt'])) {
      bad('item timestamps');
    }
    final memories = i['memories'];
    if (memories is! List) bad('memories');
    for (final m in memories) {
      if (m is! Map) bad('memory');
      final mid = m['id'];
      if (mid is! String || mid.isEmpty || !ids.add(mid)) bad('memory id');
      if (m['position'] is! int) bad('memory position');
      if (!isDate(m['date'])) bad('memory date');
      for (final k in ['title', 'text', 'location']) {
        if (m[k] != null && m[k] is! String) bad('memory $k');
      }
      if (!isTimestamp(m['createdAt']) || !isTimestamp(m['updatedAt'])) {
        bad('memory timestamps');
      }
      final tags = m['hashtags'];
      if (tags is! List || tags.any((t) => t is! String || t.isEmpty)) {
        bad('hashtags');
      }
      final photos = m['photos'];
      if (photos is! List) bad('photos');
      for (final ph in photos) {
        if (ph is! Map) bad('photo');
        final pid = ph['id'];
        if (pid is! String || pid.isEmpty || !ids.add(pid)) bad('photo id');
        if (ph['position'] is! int) bad('photo position');
        final file = ph['file'], thumb = ph['thumb'];
        if (file is! String || !isSafeMediaPath(file)) bad('photo file');
        if (thumb is! String || !isSafeMediaPath(thumb)) bad('photo thumb');
        if (ph['width'] != null && ph['width'] is! int) bad('photo width');
        if (ph['height'] != null && ph['height'] is! int) bad('photo height');
        if (!isTimestamp(ph['createdAt'])) bad('photo createdAt');
      }
    }
  }
}
