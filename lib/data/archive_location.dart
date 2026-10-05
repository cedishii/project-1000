import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the archive lives on disk.
///
/// Everything that belongs to the user's archive is kept in one folder so
/// it can be replaced as a whole during an import:
///
/// ```text
/// <app documents>/
///   archive/            ← the live archive
///     archive.db        ← SQLite database
///     photos/           ← full-size photos
///     thumbs/           ← small thumbnails
///   archive_incoming/   ← an import being prepared (temporary)
///   archive_previous/   ← the old archive during a swap (temporary)
///   swap.json           ← present only while a swap is in progress
/// ```
class ArchiveLocation {
  ArchiveLocation(this.root);

  /// The app's private documents directory.
  final Directory root;

  Directory get live => Directory(p.join(root.path, 'archive'));
  Directory get incoming => Directory(p.join(root.path, 'archive_incoming'));
  Directory get previous => Directory(p.join(root.path, 'archive_previous'));
  File get swapMarker => File(p.join(root.path, 'swap.json'));

  static String dbPathIn(Directory archive) =>
      p.join(archive.path, 'archive.db');
  static Directory photosIn(Directory archive) =>
      Directory(p.join(archive.path, 'photos'));
  static Directory thumbsIn(Directory archive) =>
      Directory(p.join(archive.path, 'thumbs'));

  String get dbPath => dbPathIn(live);

  /// Absolute path of a file stored relative to the live archive.
  String resolve(String relative) => p.join(live.path, relative);

  /// Creates the live folders if they don't exist yet and finishes or
  /// rolls back any archive swap that was interrupted (for example by the
  /// app being killed during an import).
  ///
  /// Returns true if an interrupted import was rolled back.
  Future<bool> prepare() async {
    var rolledBack = false;
    if (await swapMarker.exists()) {
      // A swap started but never committed: put the old archive back.
      if (await previous.exists()) {
        if (await live.exists()) await live.delete(recursive: true);
        await previous.rename(live.path);
      }
      await swapMarker.delete();
      rolledBack = true;
    }
    // Without a marker these are leftovers that are safe to remove:
    // `previous` was already replaced successfully, `incoming` never
    // became live.
    if (await previous.exists()) await previous.delete(recursive: true);
    if (await incoming.exists()) await incoming.delete(recursive: true);

    await photosIn(live).create(recursive: true);
    await thumbsIn(live).create(recursive: true);
    return rolledBack;
  }

  /// Replaces the live archive with [incoming]. The caller must have
  /// closed the database first.
  ///
  /// Each step is a directory rename (atomic on the same file system).
  /// If the app dies mid-way, [prepare] restores the old archive on next
  /// launch.
  Future<void> swapInIncoming() async {
    await swapMarker.writeAsString(
        jsonEncode({'startedAt': DateTime.now().toUtc().toIso8601String()}),
        flush: true);
    try {
      if (await live.exists()) await live.rename(previous.path);
      await incoming.rename(live.path);
    } catch (_) {
      // Undo whatever happened before failing.
      if (!await live.exists() && await previous.exists()) {
        await previous.rename(live.path);
      }
      await swapMarker.delete();
      rethrow;
    }
    // Commit point: the new archive is live.
    await swapMarker.delete();
    if (await previous.exists()) {
      try {
        await previous.delete(recursive: true);
      } catch (_) {
        // Left for the next launch's cleanup.
      }
    }
  }
}
