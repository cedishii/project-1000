import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/archive_location.dart';

/// What a migration needs from the cloud account (the Supabase functions
/// in supabase/migrations). The app's network implementation comes with
/// the sign-in screen; tests use a fake.
abstract interface class CloudArchiveApi {
  /// The signed-in account.
  String get userId;

  /// `import_archive`: stores the archive (backup data.json, version 2).
  /// Safe to repeat; never overwrites what the cloud already has.
  Future<Map<String, Object?>> importArchive(Map<String, Object?> data);

  /// `export_archive`: the cloud's copy, in the same format.
  Future<Map<String, Object?>> exportArchive();

  /// `archive_files`: every file the cloud records refer to, and whether
  /// storage really has it.
  Future<List<CloudFile>> archiveFiles();

  /// Uploads [file] to `<userId>/<path>` in the photos bucket. With
  /// [replace], an existing object is overwritten (a damaged earlier
  /// upload); otherwise an existing object counts as success.
  Future<void> uploadFile(
    String path,
    File file, {
    required String contentType,
    required bool replace,
  });
}

class CloudFile {
  const CloudFile({required this.path, required this.present, this.size});

  /// Archive-relative, e.g. `photos/<id>.jpg`.
  final String path;
  final bool present;
  final int? size;
}

enum MigrationStage { records, photos, verifying, done }

class MigrationProgress {
  const MigrationProgress(this.stage, {this.done = 0, this.total = 0});

  final MigrationStage stage;
  final int done;
  final int total;
}

/// The outcome of a migration run.
class MigrationReport {
  const MigrationReport({
    required this.verified,
    required this.counts,
    required this.uploaded,
    required this.alreadyInCloud,
    required this.missingOnPhone,
    required this.missingInCloud,
    required this.differences,
  });

  /// True only when the cloud's copy was read back and matches this
  /// phone's archive record by record, and every photo file is stored
  /// with the right size.
  final bool verified;

  /// Records in the cloud account (journeys, items, memories, photos).
  final Map<String, int> counts;

  /// Files uploaded in this run.
  final int uploaded;

  /// Files that were already stored (an earlier, interrupted run).
  final int alreadyInCloud;

  /// Files the archive refers to that aren't on this phone (already
  /// missing before the migration; reported, like a backup does).
  final List<String> missingOnPhone;

  /// Files that should be in the cloud but aren't (or have the wrong size).
  final List<String> missingInCloud;

  /// Records whose cloud copy differs from this phone's, in plain words.
  final List<String> differences;
}

/// Copies this phone's archive into the signed-in cloud account and
/// verifies the copy. See docs/CLOUD.md, "Migrating a phone's archive".
///
/// * The phone's archive is only read, never changed; it stays the
///   working copy until the user decides otherwise.
/// * Every step can be repeated: records are matched by their ids and
///   files by their paths, so an interrupted run is finished by running
///   it again, without duplicates.
/// * Success is decided by reading the cloud's copy back and comparing it
///   with the phone's, never by an upload "returning fine".
///
/// Progress is recorded in `archive/cloud_migration.json`, inside the
/// archive folder so that importing a different backup also discards it.
class CloudMigration {
  CloudMigration({
    required this.location,
    required this.snapshot,
    required this.api,
  });

  final ArchiveLocation location;

  /// Reads the archive as data.json (AppStore.archiveSnapshot).
  final Future<Map<String, Object?>> Function() snapshot;
  final CloudArchiveApi api;

  File get _stateFile => File(stateFileIn(location));

  static String stateFileIn(ArchiveLocation location) =>
      p.join(location.live.path, 'cloud_migration.json');

  /// The last recorded state, or null if no migration was started.
  static Future<Map<String, Object?>?> lastState(
    ArchiveLocation location,
  ) async {
    final f = File(stateFileIn(location));
    if (!await f.exists()) return null;
    try {
      return (jsonDecode(await f.readAsString()) as Map).cast();
    } catch (_) {
      return null;
    }
  }

  Future<MigrationReport> run({
    void Function(MigrationProgress progress)? onProgress,
  }) async {
    final startedAt = DateTime.now().toUtc().toIso8601String();
    await _writeState({'status': 'in_progress', 'startedAt': startedAt});

    // 1. Records: one transaction on the server, all or nothing.
    onProgress?.call(const MigrationProgress(MigrationStage.records));
    final local = await snapshot();
    await api.importArchive(local);

    // 2. Files: upload what the cloud doesn't have yet.
    final expected = await api.archiveFiles();
    var uploaded = 0, alreadyThere = 0;
    final missingOnPhone = <String>[];
    for (var i = 0; i < expected.length; i++) {
      onProgress?.call(
        MigrationProgress(
          MigrationStage.photos,
          done: i,
          total: expected.length,
        ),
      );
      final f = expected[i];
      final file = File(location.resolve(f.path));
      if (!await file.exists()) {
        missingOnPhone.add(f.path);
        continue;
      }
      final size = await file.length();
      if (f.present && f.size == size) {
        alreadyThere++;
        continue;
      }
      await api.uploadFile(
        f.path,
        file,
        contentType: contentTypeFor(f.path),
        replace: f.present,
      );
      uploaded++;
    }

    // 3. Verify by reading everything back.
    onProgress?.call(const MigrationProgress(MigrationStage.verifying));
    final cloud = await api.exportArchive();
    final differences = compareArchives(local, cloud);
    final missingInCloud = <String>[];
    for (final f in await api.archiveFiles()) {
      if (missingOnPhone.contains(f.path)) continue;
      final file = File(location.resolve(f.path));
      if (!f.present || f.size != await file.length()) {
        missingInCloud.add(f.path);
      }
    }
    final report = MigrationReport(
      verified: differences.isEmpty && missingInCloud.isEmpty,
      counts: _counts(cloud),
      uploaded: uploaded,
      alreadyInCloud: alreadyThere,
      missingOnPhone: missingOnPhone,
      missingInCloud: missingInCloud,
      differences: differences,
    );
    await _writeState({
      'status': report.verified ? 'verified' : 'needs_attention',
      'startedAt': startedAt,
      if (report.verified)
        'verifiedAt': DateTime.now().toUtc().toIso8601String(),
      'counts': report.counts,
      'missingOnPhone': missingOnPhone,
      'missingInCloud': missingInCloud,
      'differences': differences.take(50).toList(),
    });
    onProgress?.call(const MigrationProgress(MigrationStage.done));
    return report;
  }

  Future<void> _writeState(Map<String, Object?> state) async {
    final tmp = File('${_stateFile.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent(' ')
          .convert({'userId': api.userId, ...state}),
      flush: true,
    );
    await tmp.rename(_stateFile.path);
  }

  static Map<String, int> _counts(Map<String, Object?> data) {
    final journeys = (data['journeys'] as List? ?? const []).cast<Map>();
    final items = [for (final j in journeys) ...(j['items'] as List)];
    final memories = [
      for (final i in items) ...((i as Map)['memories'] as List),
    ];
    final photos = [
      for (final m in memories) ...((m as Map)['photos'] as List),
    ];
    return {
      'journeys': journeys.length,
      'items': items.length,
      'memories': memories.length,
      'photos': photos.length,
    };
  }
}

String contentTypeFor(String path) => switch (p.extension(path).toLowerCase()) {
  '.png' => 'image/png',
  '.webp' => 'image/webp',
  '.heic' => 'image/heic',
  '.heif' => 'image/heif',
  '.gif' => 'image/gif',
  _ => 'image/jpeg',
};

/// Differences between two archives in the data.json format, in plain
/// words (empty when they hold the same records). Records are matched by
/// id; timestamps are compared as instants, so `…54.113790Z` and
/// `…54.11379+00:00` are equal.
List<String> compareArchives(Map<String, Object?> a, Map<String, Object?> b) {
  final out = <String>[];
  _compare(a, b, 'archive', out);
  return out;
}

const _instantKeys = {'createdAt', 'updatedAt', 'archivedAt'};

void _compare(Object? a, Object? b, String where, List<String> out) {
  if (a is Map && b is Map) {
    for (final key in {...a.keys, ...b.keys}) {
      final k = key as String;
      if (k == 'dataFormatVersion') continue;
      final av = a[k], bv = b[k];
      if (_instantKeys.contains(k)) {
        if (!_sameInstant(av, bv)) out.add('$where: $k differs');
      } else {
        _compare(av, bv, '$where.$k', out);
      }
    }
  } else if (a is List && b is List) {
    final keyed =
        [...a, ...b].isNotEmpty &&
        [...a, ...b].every((e) => e is Map && e['id'] != null);
    if (!keyed) {
      if (jsonEncode(a) != jsonEncode(b)) out.add('$where differs');
      return;
    }
    final am = {for (final e in a) (e as Map)['id']: e};
    final bm = {for (final e in b) (e as Map)['id']: e};
    for (final id in {...am.keys, ...bm.keys}) {
      final label = '$where[${_label(am[id] ?? bm[id])}]';
      if (!am.containsKey(id)) {
        out.add('$label: only in the cloud');
      } else if (!bm.containsKey(id)) {
        out.add('$label: missing in the cloud');
      } else {
        _compare(am[id], bm[id], label, out);
      }
    }
  } else if (a != b) {
    out.add('$where differs');
  }
}

String _label(Object? record) {
  final r = record as Map;
  final n = r['number'];
  return n is int ? '#${n.toString().padLeft(3, '0')}' : '${r['id']}';
}

bool _sameInstant(Object? a, Object? b) {
  if (a == null || b == null) return a == b;
  final x = DateTime.tryParse('$a'), y = DateTime.tryParse('$b');
  return x != null && y != null && x.isAtSameMomentAs(y);
}
