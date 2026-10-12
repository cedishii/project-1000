import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../core/log.dart';
import '../services/photo_storage.dart';
import 'archive_backend.dart';
import 'archive_location.dart';
import 'archive_repository.dart';
import 'database.dart';
import 'models.dart';

/// The archive on this phone: the SQLite database and photo files in the
/// app's private folder (see [ArchiveLocation]).
class LocalArchive implements ArchiveBackend {
  LocalArchive._(this.location, this._db, this.factory)
    : _repo = ArchiveRepository(_db),
      photos = PhotoStorage(location);

  /// Opens the archive in [root], finishing or rolling back an
  /// interrupted import first. [rolledBack] is set if one was rolled back.
  static Future<LocalArchive> open(
    Directory root, {
    DatabaseFactory? factory,
    void Function(bool rolledBack)? onPrepared,
  }) async {
    final location = ArchiveLocation(root);
    final rolledBack = await location.prepare();
    onPrepared?.call(rolledBack);
    await PhotoStorage(location).clearPending();
    final db = await openArchiveDatabase(location.dbPath, factory: factory);
    return LocalArchive._(location, db, factory);
  }

  final ArchiveLocation location;
  final PhotoStorage photos;
  final DatabaseFactory? factory;
  Database _db;
  ArchiveRepository _repo;

  Database get db => _db;
  ArchiveRepository get repository => _repo;

  // ---------------------------------------------------------------- reads

  @override
  Future<Journey> activeJourney() => _repo.activeJourney();

  @override
  Future<Profile> loadProfile() => _repo.loadProfile();

  @override
  Future<List<BucketItem>> loadItems({String? journeyId}) =>
      _repo.loadItems(journeyId: journeyId);

  @override
  Future<Map<String, int>> memoryCounts({String? journeyId}) =>
      _repo.memoryCounts(journeyId: journeyId);

  @override
  Future<Set<String>> searchItemIds(String query, {String? journeyId}) =>
      _repo.searchItemIds(query, journeyId: journeyId);

  @override
  Future<List<Memory>> loadMemories(String itemId) =>
      _repo.loadMemories(itemId);

  @override
  Future<List<Memory>> loadMemoriesByIds(List<String> ids) =>
      _repo.loadMemoriesByIds(ids);

  @override
  Future<List<JourneySummary>> journeySummaries() => _repo.journeySummaries();

  @override
  Future<List<AlbumEntry>> albumOutline(String journeyId) =>
      _repo.albumOutline(journeyId);

  @override
  Future<String?> getSetting(String key) => _repo.getSetting(key);

  // --------------------------------------------------------------- writes

  @override
  Future<BucketItem> addItem(String title, String description) =>
      _repo.addItem(title, description);

  @override
  Future<void> updateItemText(String id, String title, String description) =>
      _repo.updateItemText(id, title, description);

  @override
  Future<void> setCompleted(String id, bool completed, {CalendarDate? on}) =>
      _repo.setCompleted(id, completed, on: on);

  @override
  Future<void> deleteItem(String id) async {
    await deleteFiles(await _repo.deleteItem(id));
  }

  @override
  Future<void> saveOrder(List<String> orderedIds) =>
      _repo.saveOrder(orderedIds);

  /// New (pending) photos are moved into the archive first; if the
  /// database write then fails, they are moved back so nothing is
  /// half-saved.
  @override
  Future<String> saveMemory(MemoryDraft draft) async {
    final committed = await photos.commit(draft.photos);
    final String id;
    final List<String> removedFiles;
    try {
      (id, removedFiles) = await _repo.saveMemory(
        MemoryDraft(
          id: draft.id,
          itemId: draft.itemId,
          title: draft.title,
          body: draft.body,
          date: draft.date,
          location: draft.location,
          hashtags: draft.hashtags,
          photos: committed,
        ),
      );
    } catch (_) {
      await photos.rollback(draft.photos, committed);
      rethrow;
    }
    await deleteFiles(removedFiles);
    return id;
  }

  @override
  Future<void> deleteMemory(String id) async {
    await deleteFiles(await _repo.deleteMemory(id));
  }

  @override
  Future<void> setJourneyStart(CalendarDate? date) =>
      _repo.setJourneyStart(date);

  /// The profile picture is copied, so the archived journey keeps the
  /// picture from that period even if the current one changes.
  @override
  Future<Journey> startNewJourney({
    required CalendarDate? startedOn,
    required CalendarDate completedOn,
    required Profile profile,
    required CalendarDate newStartedOn,
    required bool reuseList,
  }) async {
    String? photoCopy;
    final photo = profile.photo;
    if (photo != null && await File(location.resolve(photo)).exists()) {
      photoCopy = 'profile/${ArchiveRepository.newId()}.jpg';
      await File(location.resolve(photo)).copy(location.resolve(photoCopy));
    }
    try {
      return await _repo.archiveAndStartNew(
        startedOn: startedOn,
        completedOn: completedOn,
        snapshot: profile.isEmpty
            ? null
            : profile.copyWith(photo: photoCopy, clearPhoto: photoCopy == null),
        newStartedOn: newStartedOn,
        reuseList: reuseList,
      );
    } catch (_) {
      if (photoCopy != null) await deleteFiles([photoCopy]);
      rethrow;
    }
  }

  @override
  Future<void> saveProfile(Profile profile) => _repo.saveProfile(profile);

  /// Each picture gets a new file name, so nothing shows a stale cached
  /// image.
  @override
  Future<void> setProfilePhoto(Profile current, Uint8List jpeg) async {
    final rel = 'profile/${ArchiveRepository.newId()}.jpg';
    final file = File(location.resolve(rel));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(jpeg, flush: true);
    try {
      await _repo.saveProfile(current.copyWith(photo: rel));
    } catch (_) {
      await deleteFiles([rel]);
      rethrow;
    }
    if (current.photo != null) await deleteFiles([current.photo!]);
  }

  @override
  Future<void> removeProfilePhoto(Profile current) async {
    await _repo.saveProfile(current.copyWith(clearPhoto: true));
    if (current.photo != null) await deleteFiles([current.photo!]);
  }

  @override
  Future<void> setSetting(String key, String value) =>
      _repo.setSetting(key, value);

  // -------------------------------------------------------------- archive

  /// Deletes files (paths relative to the archive) after their database
  /// rows are gone. A failure only leaves an unused file behind.
  Future<void> deleteFiles(List<String> relativePaths) async {
    for (final rel in relativePaths) {
      try {
        final f = File(location.resolve(rel));
        if (await f.exists()) await f.delete();
      } catch (e) {
        logError('Could not delete $rel', e);
      }
    }
  }

  /// Closes the database, runs [swap] (which replaces the archive folder
  /// on disk) and reopens. If [swap] throws, the existing archive is
  /// reopened unchanged and the error is rethrown.
  Future<void> replace(Future<void> Function() swap) async {
    await _db.close();
    Object? error;
    StackTrace? stack;
    try {
      await swap();
    } catch (e, s) {
      error = e;
      stack = s;
    }
    await location.prepare();
    _db = await openArchiveDatabase(location.dbPath, factory: factory);
    _repo = ArchiveRepository(_db);
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }

  Future<void> close() => _db.close();
}
