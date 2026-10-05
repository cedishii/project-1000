import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../background.dart';
import 'backup_format.dart';

class ExportResult {
  ExportResult({
    required this.file,
    required this.journeys,
    required this.items,
    required this.memories,
    required this.photos,
    required this.missingFiles,
  });

  final File file;
  final int journeys;

  /// Things on all journeys' lists.
  final int items;
  final int memories;
  final int photos;

  /// Photo files the database refers to but that weren't on disk.
  final List<String> missingFiles;
}

/// Writes a complete backup of the archive to a .zip in [outDir].
///
/// The data is read in one transaction (a consistent snapshot); the
/// heavy work — hashing and zipping photos — runs on a background isolate
/// so the app stays responsive.
Future<ExportResult> exportBackup({
  required Database db,
  required Directory archiveDir,
  required Directory outDir,
  required String appVersion,
  DateTime? now,
  void Function(double progress)? onProgress,
}) async {
  final exportedAt = (now ?? DateTime.now());
  final data = await db.transaction((txn) => _snapshot(txn));
  final journeys = (data['journeys'] as List).cast<Map>();
  final allItems = [for (final j in journeys) ...(j['items'] as List)];
  final media = <String>[
    for (final item in allItems)
      for (final m in (item as Map)['memories'] as List)
        for (final ph in (m as Map)['photos'] as List) ...[
          (ph as Map)['file'] as String,
          ph['thumb'] as String,
        ],
  ];
  final photoCount = media.length ~/ 2;
  // Profile pictures: the current one and those kept with each archived
  // journey.
  for (final photo in [
    (data['profile'] as Map?)?['photo'],
    for (final j in journeys) (j['snapshot'] as Map?)?['photo'],
  ]) {
    if (photo is String) media.add(photo);
  }

  await outDir.create(recursive: true);
  // Remove earlier exports so old copies don't pile up in app storage.
  await for (final f in outDir.list()) {
    if (f is File && p.basename(f.path).startsWith('1000-things-backup')) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
  final outPath = p.join(outDir.path, backupFileName(exportedAt));

  final job = _ZipJob(
    archiveDir: archiveDir.path,
    outPath: outPath,
    dataJson: const JsonEncoder.withIndent(' ').convert(data),
    media: media,
    manifestBase: {
      'format': backupFormatId,
      'backupFormatVersion': backupFormatVersion,
      'dataFormatVersion': dataFormatVersion,
      'appVersion': appVersion,
      'exportedAt': exportedAt.toUtc().toIso8601String(),
      'counts': {
        'journeys': journeys.length,
        'items': allItems.length,
        'memories': [for (final i in allItems) ...(i as Map)['memories']]
            .length,
        'photos': photoCount,
      },
    },
  );
  final missing = await runWithProgress(
    (report) => _writeZip(job, report),
    onProgress: onProgress,
  );
  final counts = job.manifestBase['counts'] as Map;
  return ExportResult(
    file: File(outPath),
    journeys: counts['journeys'] as int,
    items: counts['items'] as int,
    memories: counts['memories'] as int,
    photos: counts['photos'] as int,
    missingFiles: missing,
  );
}

/// Everything in the database, as the data.json structure.
/// Journeys are listed oldest first; each journey's items in the user's
/// order.
Future<Map<String, Object?>> _snapshot(Transaction txn) async {
  final journeys = await txn.query('journeys', orderBy: 'number');
  final profile = await txn.query('profile');
  final items = await txn.query('items', orderBy: 'position, rowid');
  final memories = await txn.query('memories', orderBy: 'position, rowid');
  final tags = await txn.query('memory_tags', orderBy: 'position');
  final photos = await txn.query('photos', orderBy: 'position, rowid');
  final settings = await txn.query('settings');

  final tagsBy = <String, List<String>>{};
  for (final t in tags) {
    tagsBy
        .putIfAbsent(t['memory_id'] as String, () => [])
        .add(t['tag'] as String);
  }
  final photosBy = <String, List<Map<String, Object?>>>{};
  for (final ph in photos) {
    photosBy.putIfAbsent(ph['memory_id'] as String, () => []).add({
      'id': ph['id'],
      'position': ph['position'],
      'file': ph['file'],
      'thumb': ph['thumb'],
      'width': ph['width'],
      'height': ph['height'],
      'createdAt': ph['created_at'],
    });
  }
  final memoriesBy = <String, List<Map<String, Object?>>>{};
  for (final m in memories) {
    memoriesBy.putIfAbsent(m['item_id'] as String, () => []).add({
      'id': m['id'],
      'position': m['position'],
      'title': m['title'],
      'text': m['body'],
      'date': m['date'],
      'location': m['location'],
      'hashtags': tagsBy[m['id']] ?? const <String>[],
      'createdAt': m['created_at'],
      'updatedAt': m['updated_at'],
      'photos': photosBy[m['id']] ?? const [],
    });
  }

  final itemsBy = <String, List<Map<String, Object?>>>{};
  for (final i in items) {
    itemsBy.putIfAbsent(i['journey_id'] as String, () => []).add({
      'id': i['id'],
      'number': i['number'],
      'position': i['position'],
      'title': i['title'],
      'description': i['description'],
      'isCompleted': i['is_completed'] == 1,
      'completedOn': i['completed_on'],
      'createdAt': i['created_at'],
      'updatedAt': i['updated_at'],
      'memories': memoriesBy[i['id']] ?? const [],
    });
  }

  return {
    'dataFormatVersion': dataFormatVersion,
    'settings': {for (final s in settings) s['key'] as String: s['value']},
    'profile': profile.isEmpty
        ? null
        : {
            'name': profile.first['name'],
            'nickname': profile.first['nickname'],
            'age': profile.first['age'],
            'startedOn': profile.first['started_on'],
            'bio': profile.first['bio'],
            'photo': profile.first['photo'],
            'updatedAt': profile.first['updated_at'],
          },
    'journeys': [
      for (final j in journeys)
        {
          'id': j['id'],
          'number': j['number'],
          'status': j['status'],
          'startedOn': j['started_on'],
          'completedOn': j['completed_on'],
          'snapshot': j['snapshot'] == null
              ? null
              : jsonDecode(j['snapshot'] as String),
          'createdAt': j['created_at'],
          'archivedAt': j['archived_at'],
          'items': itemsBy[j['id']] ?? const [],
        },
    ],
  };
}

class _ZipJob {
  _ZipJob({
    required this.archiveDir,
    required this.outPath,
    required this.dataJson,
    required this.media,
    required this.manifestBase,
  });

  final String archiveDir;
  final String outPath;
  final String dataJson;
  final List<String> media;
  final Map<String, Object?> manifestBase;
}

/// Runs on a background isolate. Returns the list of missing files.
Future<List<String>> _writeZip(
  _ZipJob job,
  void Function(double) report,
) async {
  final partial = File('${job.outPath}.partial');
  final encoder = ZipFileEncoder()..create(partial.path);
  final files = <String, Object>{};
  final missing = <String>[];
  try {
    final dataBytes = utf8.encode(job.dataJson);
    encoder.addArchiveFile(ArchiveFile.bytes(dataName, dataBytes));

    var done = 0;
    for (final rel in job.media) {
      if (++done % 10 == 0) report(done / job.media.length * 0.95);
      if (files.containsKey(rel)) continue;
      final file = File(p.join(job.archiveDir, rel));
      if (!file.existsSync()) {
        missing.add(rel);
        continue;
      }
      files[rel] = {
        'sha256': await sha256OfFile(file),
        'size': file.lengthSync(),
      };
      // Photos are already compressed: store them as-is, streamed from
      // disk, so even very large archives never sit in memory.
      final input = InputFileStream(file.path);
      encoder.addArchiveFile(
        ArchiveFile.stream(rel, input)..compression = CompressionType.none,
      );
      await input.close();
    }

    final manifest = {
      ...job.manifestBase,
      'data': {
        'file': dataName,
        'sha256': sha256.convert(dataBytes).toString(),
        'size': dataBytes.length,
      },
      'files': files,
      'missingAtExport': missing,
    };
    encoder.addArchiveFile(
      ArchiveFile.bytes(
        manifestName,
        utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
      ),
    );
    await encoder.close();
  } catch (_) {
    try {
      await encoder.close();
    } catch (_) {}
    if (partial.existsSync()) partial.deleteSync();
    rethrow;
  }

  // Check the finished zip can be read back and contains every file.
  final input = InputFileStream(partial.path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final names = {for (final f in archive) f.name};
    final expected = {dataName, manifestName, ...files.keys};
    if (!names.containsAll(expected)) {
      throw StateError('Backup verification failed');
    }
  } finally {
    await input.close();
  }

  final out = File(job.outPath);
  if (out.existsSync()) out.deleteSync();
  partial.renameSync(job.outPath);
  return missing;
}
