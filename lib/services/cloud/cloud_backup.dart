import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/log.dart';
import '../backup/backup_bytes.dart';
import 'cloud_media.dart';
import 'cloud_migration.dart' show contentTypeFor;

/// What merging a backup (or a phone's archive) into the account does, as
/// reported by the server's `merge_archive` (a dry run for the preview,
/// the real thing when applied). See
/// supabase/migrations/20261013000200_merge_and_live.sql.
class MergeSummary {
  MergeSummary(Map json)
    : applied = json['applied'] == true,
      nothingToAdd = json['nothingToAdd'] == true,
      before = _counts(json['before']),
      after = _counts(json['after']),
      changes = (json['changes'] as Map).cast<String, Object?>();

  final bool applied;
  final bool nothingToAdd;

  /// journeys, items, memories, photos, completed, listed.
  final Map<String, int> before;
  final Map<String, int> after;
  final Map<String, Object?> changes;

  int _c(String key) => (changes[key] as num?)?.toInt() ?? 0;
  int get itemsAdded => _c('itemsAdded');
  int get matchedById => _c('matchedById');
  int get matchedByTitle => _c('matchedByTitle');
  int get completionsAdded => _c('completionsAdded');
  int get textKept => _c('textKept');
  int get renumbered => _c('renumbered');
  int get memoriesAdded => _c('memoriesAdded');
  int get photosAdded => _c('photosAdded');
  int get journeysAdded => _c('journeysAdded');
  int get settingsAdded => _c('settingsAdded');

  /// The account had nothing but an empty first journey: it takes the
  /// file's journeys as they are.
  bool get intoEmptyAccount => changes['replacedEmptyJourney'] == true;

  /// 'added' (the account's was empty), 'kept' (the account's differs and
  /// stays) or 'none'.
  String get profile => '${changes['profile']}';

  static Map<String, int> _counts(Object? m) => {
    for (final e in ((m as Map?) ?? const {}).entries)
      '${e.key}': (e.value as num).toInt(),
  };
}

class MergeResult {
  MergeResult({
    required this.summary,
    required this.uploaded,
    required this.missingInFile,
    required this.missingInCloud,
    required this.verified,
  });

  final MergeSummary summary;

  /// Photo files uploaded in this run.
  final int uploaded;

  /// Files the merged records refer to that the source didn't have.
  final List<String> missingInFile;

  /// Files that should be in the account but aren't.
  final List<String> missingInCloud;

  /// True when a second dry run finds nothing left to add and every file
  /// the source had is stored in the account.
  final bool verified;
}

/// Why a merge was refused, in plain words.
String mergeProblem(Object e) {
  final m = e is PostgrestException ? e.message : '';
  return switch (m) {
    'history_conflict' =>
      'Both your account and this backup have finished journeys, and they '
          'aren\'t the same ones. Two different histories can\'t be combined, '
          'so nothing was changed.',
    'list_full' =>
      'Together this would be more than 1,000 things on your current list, '
          'so nothing was changed.',
    'id_conflict' =>
      'This backup belongs to a different account, so nothing was changed.',
    'unsupported_format' || 'invalid_data' || 'title_required' =>
      'This backup\'s contents are inconsistent, so nothing was changed.',
    'too_large' => 'This backup is too large to import here.',
    _ =>
      isConnectionError(e)
          ? 'The connection dropped. Nothing is lost: try again and it '
                'continues where it stopped, without duplicates.'
          : 'Something went wrong, so it stopped. Your account keeps '
                'everything it had; try again.',
  };
}

bool isConnectionError(Object e) {
  final s = '${e.runtimeType} $e';
  return s.contains('SocketException') ||
      s.contains('ClientException') ||
      s.contains('Timeout') ||
      s.contains('Failed to fetch') ||
      s.contains('HandshakeException');
}

/// Backups of the signed-in account: export in the phone's backup format,
/// and safe, repeatable merges of a backup or a phone's archive into it.
class CloudBackup {
  CloudBackup(this.client);

  final SupabaseClient client;

  String get _userId => client.auth.currentUser!.id;
  StorageFileApi get _files => client.storage.from(CloudMedia.bucket);

  /// The account as a backup zip, photos included. Files that can't be
  /// downloaded are listed in the manifest's `missingAtExport`, as the
  /// phone does for files missing on disk.
  Future<(Uint8List, Map<String, Object?>, List<String>)> export({
    required String appVersion,
    void Function(int done, int total)? onProgress,
  }) async {
    final data = ((await client.rpc('export_archive')) as Map)
        .cast<String, Object?>();
    final paths = mediaPathsOf(data);
    final files = <String, Uint8List>{};
    final missing = <String>[];
    for (var i = 0; i < paths.length; i++) {
      onProgress?.call(i, paths.length);
      try {
        files[paths[i]] = await _files.download('$_userId/${paths[i]}');
      } catch (e) {
        if (isConnectionError(e)) rethrow;
        logError('Export: could not download ${paths[i]}', e);
        missing.add(paths[i]);
      }
    }
    onProgress?.call(paths.length, paths.length);
    final zip = encodeBackupBytes(
      data: data,
      files: files,
      appVersion: appVersion,
      exportedAt: DateTime.now(),
      missing: missing,
    );
    return (zip, data, missing);
  }

  /// What merging [data] would do. Changes nothing.
  Future<MergeSummary> preview(
    Map<String, Object?> data, {
    bool matchTitles = true,
  }) async => MergeSummary(
    (await client.rpc(
      'merge_archive',
      params: {'p_data': data, 'p_apply': false, 'p_match_titles': matchTitles},
    )) as Map,
  );

  /// Merges [data] into the account (one transaction on the server), then
  /// uploads the photo files the account is missing, read with
  /// [readFile], and checks the result. Safe to run again after any
  /// failure: it continues without duplicates.
  Future<MergeResult> merge(
    Map<String, Object?> data, {
    required Future<Uint8List?> Function(String path) readFile,
    bool matchTitles = true,
    void Function(String stage, int done, int total)? onProgress,
  }) async {
    onProgress?.call('records', 0, 0);
    final summary = MergeSummary(
      (await client.rpc(
        'merge_archive',
        params: {
          'p_data': data,
          'p_apply': true,
          'p_match_titles': matchTitles,
        },
      )) as Map,
    );

    final wanted = mediaPathsOf(data).toSet();
    final expected = [
      for (final f in await _archiveFiles())
        if (wanted.contains(f.$1)) f,
    ];
    var uploaded = 0;
    final missingInFile = <String>[];
    for (var i = 0; i < expected.length; i++) {
      onProgress?.call('photos', i, expected.length);
      final (path, present, size) = expected[i];
      final bytes = await readFile(path);
      if (bytes == null) {
        missingInFile.add(path);
        continue;
      }
      if (present && size == bytes.length) continue;
      await _files.uploadBinary(
        '$_userId/$path',
        bytes,
        fileOptions: FileOptions(
          contentType: contentTypeFor(path),
          upsert: true,
        ),
      );
      uploaded++;
    }

    onProgress?.call('verifying', 0, 0);
    final check = await preview(data, matchTitles: matchTitles);
    final missingInCloud = <String>[];
    for (final (path, present, size) in await _archiveFiles()) {
      if (!wanted.contains(path) || missingInFile.contains(path)) continue;
      final bytes = await readFile(path);
      if (!present || (bytes != null && size != bytes.length)) {
        missingInCloud.add(path);
      }
    }
    return MergeResult(
      summary: summary,
      uploaded: uploaded,
      missingInFile: missingInFile,
      missingInCloud: missingInCloud,
      verified: check.nothingToAdd && missingInCloud.isEmpty,
    );
  }

  Future<List<(String, bool, int?)>> _archiveFiles() async => [
    for (final r in ((await client.rpc('archive_files')) as List).cast<Map>())
      (r['path'] as String, r['present'] as bool, (r['size'] as num?)?.toInt()),
  ];
}
