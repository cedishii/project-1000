import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'cloud_media.dart';
import 'cloud_migration.dart';

/// [CloudArchiveApi] for the signed-in Supabase account.
class SupabaseMigrationApi implements CloudArchiveApi {
  SupabaseMigrationApi(this.client);

  final SupabaseClient client;

  @override
  String get userId => client.auth.currentUser!.id;

  @override
  Future<Map<String, Object?>> importArchive(Map<String, Object?> data) async =>
      ((await client.rpc('import_archive', params: {'p_data': data})) as Map)
          .cast();

  @override
  Future<Map<String, Object?>> exportArchive() async =>
      ((await client.rpc('export_archive')) as Map).cast();

  @override
  Future<List<CloudFile>> archiveFiles() async {
    final rows = (await client.rpc('archive_files')) as List;
    return [
      for (final r in rows.cast<Map>())
        CloudFile(
          path: r['path'] as String,
          present: r['present'] as bool,
          size: r['size'] as int?,
        ),
    ];
  }

  @override
  Future<void> uploadFile(
    String path,
    File file, {
    required String contentType,
    required bool replace,
  }) async {
    try {
      await client.storage
          .from(CloudMedia.bucket)
          .uploadBinary(
            '$userId/$path',
            await file.readAsBytes(),
            fileOptions: FileOptions(contentType: contentType, upsert: replace),
          );
    } on StorageException catch (e) {
      // Already there from an interrupted earlier run: the size check
      // that follows decides whether it is good.
      if (!replace && (e.statusCode == '409' || e.message.contains('exists'))) {
        return;
      }
      rethrow;
    }
  }
}
