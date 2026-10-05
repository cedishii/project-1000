/// Constants and helpers shared by export and import.
///
/// The format is documented in docs/BACKUP_FORMAT.md. If it ever changes,
/// increase [backupFormatVersion] (zip layout / manifest) or
/// [dataFormatVersion] (data.json contents) and teach the importer to read
/// every older version — old backups must keep working for decades.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

const String backupFormatId = 'project-1000-backup';
const int backupFormatVersion = 1;
const int dataFormatVersion = 1;

const String manifestName = 'manifest.json';
const String dataName = 'data.json';

/// Folders inside the zip that may contain archive files.
const List<String> mediaFolders = ['photos', 'thumbs'];

/// The only file names accepted from a backup for media: `photos/<name>`
/// or `thumbs/<name>` with a plain file name (no `..`, no sub-folders).
final RegExp mediaPathPattern =
    RegExp(r'^(photos|thumbs)/[A-Za-z0-9][A-Za-z0-9._-]{0,120}$');

bool isSafeMediaPath(String path) =>
    mediaPathPattern.hasMatch(path) && !path.contains('..');

/// SHA-256 of a file, read in chunks (works for large photos).
Future<String> sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

String backupFileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '1000-things-backup-${now.year}-${two(now.month)}-${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}.zip';
}

/// Problems an import can run into, each with a plain-language message.
enum ImportProblem {
  notABackup('This file isn\'t a Project: 1000 backup.'),
  corrupted('This backup file is damaged and can\'t be read. Your current '
      'list was not changed.'),
  newerVersion('This backup was made by a newer version of Project: 1000. '
      'Please update the app, then import again.'),
  invalidData('The backup\'s contents are inconsistent, so it was not '
      'imported. Your current list was not changed.'),
  outOfSpace('There isn\'t enough free storage to import this backup. Free '
      'up some space and try again. Your current list was not changed.'),
  unreadable('The backup file couldn\'t be opened. Try saving it to your '
      'phone first, then import it again.');

  const ImportProblem(this.message);
  final String message;
}

class ImportException implements Exception {
  ImportException(this.problem, [this.detail]);

  final ImportProblem problem;

  /// Technical detail for developer logs only.
  final String? detail;

  @override
  String toString() => 'ImportException(${problem.name}: $detail)';
}
