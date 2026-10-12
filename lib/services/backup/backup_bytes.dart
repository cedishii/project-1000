/// Backups held in memory: reading a backup the user picked in a browser,
/// and writing one from an account's data. Same zip layout, manifest and
/// checks as the phone's file-based export and import
/// (docs/BACKUP_FORMAT.md), so a backup made on either opens on both.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'backup_format.dart';
import 'import_service.dart' show upgradeBackupData, validateBackupData;

/// Backups larger than this aren't opened in memory (browsers).
const int maxInMemoryBackupBytes = 1024 * 1024 * 1024;

/// A checked backup: its data.json (current version) and the media files
/// whose checksums matched the manifest.
class BackupContents {
  BackupContents({
    required this.data,
    required this.files,
    required this.exportedAt,
    required this.appVersion,
  });

  final Map<String, Object?> data;

  /// Archive-relative path (`photos/…`, `thumbs/…`, `profile/…`) → bytes.
  final Map<String, Uint8List> files;
  final DateTime? exportedAt;
  final String appVersion;

  List<Map> get journeys => (data['journeys'] as List).cast<Map>();
  List<Map> get items => [
    for (final j in journeys) ...(j['items'] as List).cast<Map>(),
  ];
  List<Map> get memories => [
    for (final i in items) ...(i['memories'] as List).cast<Map>(),
  ];
  List<Map> get photos => [
    for (final m in memories) ...(m['photos'] as List).cast<Map>(),
  ];

  /// Photos whose full-size file and thumbnail are both missing.
  int get missingPhotos => photos
      .where(
        (p) => !files.containsKey(p['file']) && !files.containsKey(p['thumb']),
      )
      .length;
}

/// Opens and checks a backup zip. Throws [ImportException] with a
/// user-facing reason if it isn't a usable backup.
BackupContents readBackupBytes(Uint8List zip) {
  if (zip.length > maxInMemoryBackupBytes) {
    throw ImportException(ImportProblem.unreadable, 'too large: ${zip.length}');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zip);
  } catch (e) {
    throw ImportException(ImportProblem.notABackup, 'not a zip: $e');
  }
  final entries = {
    for (final f in archive)
      if (f.isFile) f.name: f,
  };
  Map<String, Object?> json(ArchiveFile f, String what) {
    try {
      return (jsonDecode(utf8.decode(f.readBytes() ?? Uint8List(0))) as Map)
          .cast<String, Object?>();
    } catch (e) {
      throw ImportException(ImportProblem.corrupted, '$what json: $e');
    }
  }

  final manifestEntry = entries[manifestName];
  if (manifestEntry == null) {
    throw ImportException(ImportProblem.notABackup, 'no manifest');
  }
  final manifest = json(manifestEntry, 'manifest');
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
  final dataEntry = entries[dataName];
  final dataInfo = manifest['data'];
  if (dataEntry == null || dataInfo is! Map) {
    throw ImportException(ImportProblem.corrupted, 'no data.json');
  }
  final dataBytes = dataEntry.readBytes() ?? Uint8List(0);
  if (sha256.convert(dataBytes).toString() != dataInfo['sha256']) {
    throw ImportException(ImportProblem.corrupted, 'data checksum');
  }
  var data = json(dataEntry, 'data');
  data = upgradeBackupData(data, dfv);
  validateBackupData(data);

  // Media: only files that match their recorded size and checksum.
  final info = (manifest['files'] as Map? ?? const {});
  final files = <String, Uint8List>{};
  for (final MapEntry(:key, :value) in info.entries) {
    final rel = '$key';
    final entry = entries[rel];
    if (entry == null || value is! Map || !isSafeMediaPath(rel)) continue;
    final bytes = entry.readBytes();
    if (bytes == null || bytes.length != value['size']) continue;
    if (sha256.convert(bytes).toString() != value['sha256']) continue;
    files[rel] = bytes;
  }

  // As on the phone: a photo with only one of its two files keeps the
  // other; a missing profile picture is left out.
  final contents = BackupContents(
    data: data,
    files: files,
    exportedAt: DateTime.tryParse('${manifest['exportedAt']}'),
    appVersion: '${manifest['appVersion'] ?? ''}',
  );
  for (final m in contents.memories) {
    final photos = (m['photos'] as List).cast<Map>();
    photos.removeWhere(
      (ph) => !files.containsKey(ph['file']) && !files.containsKey(ph['thumb']),
    );
    for (final ph in photos) {
      if (!files.containsKey(ph['file'])) ph['file'] = ph['thumb'];
      if (!files.containsKey(ph['thumb'])) ph['thumb'] = ph['file'];
    }
  }
  for (final owner in [
    data['profile'] as Map?,
    for (final j in contents.journeys) j['snapshot'] as Map?,
  ]) {
    final photo = owner?['photo'];
    if (photo is String && !files.containsKey(photo)) owner!['photo'] = null;
  }
  return contents;
}

/// The media paths [data] refers to: photos, thumbnails, the profile
/// picture and those kept with archived journeys.
List<String> mediaPathsOf(Map<String, Object?> data) {
  final journeys = (data['journeys'] as List).cast<Map>();
  return {
    for (final j in journeys)
      for (final i in (j['items'] as List).cast<Map>())
        for (final m in (i['memories'] as List).cast<Map>())
          for (final ph in (m['photos'] as List).cast<Map>()) ...[
            ph['file'] as String,
            ph['thumb'] as String,
          ],
    if ((data['profile'] as Map?)?['photo'] case final String photo) photo,
    for (final j in journeys)
      if ((j['snapshot'] as Map?)?['photo'] case final String photo) photo,
  }.toList();
}

/// Writes a backup zip of [data] and [files] (paths as in [mediaPathsOf]),
/// exactly like the phone's export. [missing] lists files that couldn't
/// be included.
Uint8List encodeBackupBytes({
  required Map<String, Object?> data,
  required Map<String, Uint8List> files,
  required String appVersion,
  required DateTime exportedAt,
  List<String> missing = const [],
}) {
  final journeys = (data['journeys'] as List).cast<Map>();
  final items = [for (final j in journeys) ...(j['items'] as List)];
  final memories = [for (final i in items) ...((i as Map)['memories'] as List)];
  final photos = [for (final m in memories) ...((m as Map)['photos'] as List)];
  final dataBytes = utf8.encode(
    const JsonEncoder.withIndent(' ').convert(data),
  );
  final archive = Archive()..add(ArchiveFile.bytes(dataName, dataBytes));
  final fileInfo = <String, Object>{};
  for (final MapEntry(:key, :value) in files.entries) {
    fileInfo[key] = {
      'sha256': sha256.convert(value).toString(),
      'size': value.length,
    };
    archive.add(
      ArchiveFile.bytes(key, value)..compression = CompressionType.none,
    );
  }
  final manifest = {
    'format': backupFormatId,
    'backupFormatVersion': backupFormatVersion,
    'dataFormatVersion': dataFormatVersion,
    'appVersion': appVersion,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'counts': {
      'journeys': journeys.length,
      'items': items.length,
      'memories': memories.length,
      'photos': photos.length,
    },
    'data': {
      'file': dataName,
      'sha256': sha256.convert(dataBytes).toString(),
      'size': dataBytes.length,
    },
    'files': fileInfo,
    'missingAtExport': missing,
  };
  archive.add(
    ArchiveFile.bytes(
      manifestName,
      utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
    ),
  );
  return ZipEncoder().encodeBytes(archive);
}
