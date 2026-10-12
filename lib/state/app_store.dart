import '../core/log.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/archive_location.dart';
import '../data/archive_repository.dart';
import '../data/database.dart';
import '../data/models.dart';
import '../data/progression.dart';
import '../services/backup/export_service.dart' as export_service;
import '../services/backup/export_service.dart' show ExportResult;
import '../services/backup/import_service.dart';
import '../services/photo_storage.dart';

/// App-wide state: the current journey's list (in the user's order),
/// memory counts, the profile and settings. Screens listen to it and
/// call its methods to change data.
class AppStore extends ChangeNotifier {
  AppStore._(this.location, this._db, {this.factory})
    : _repo = ArchiveRepository(_db),
      photos = PhotoStorage(location);

  /// Opens the archive in the app's private documents folder.
  static Future<AppStore> open({
    Directory? root,
    DatabaseFactory? factory,
  }) async {
    final dir = root ?? await getApplicationDocumentsDirectory();
    final location = ArchiveLocation(dir);
    final rolledBack = await location.prepare();
    await PhotoStorage(location).clearPending();
    final db = await openArchiveDatabase(location.dbPath, factory: factory);
    final store = AppStore._(location, db, factory: factory)
      ..recoveredFromInterruptedImport = rolledBack;
    await store._reload();
    await store._loadSettings();
    return store;
  }

  final ArchiveLocation location;
  final PhotoStorage photos;
  final DatabaseFactory? factory;
  Database _db;
  ArchiveRepository _repo;

  ArchiveRepository get repository => _repo;

  /// True if the last launch found an unfinished import and restored the
  /// previous archive.
  bool recoveredFromInterruptedImport = false;

  List<BucketItem> _items = const [];
  Map<String, int> _memoryCounts = const {};
  ThemeMode _themeMode = ThemeMode.system;
  late Journey _journey;
  Profile _profile = const Profile();

  /// Bumped whenever memories change, so open screens can reload.
  int memoryRevision = 0;

  /// Bumped whenever journeys or the profile change.
  int journeyRevision = 0;

  /// The current journey's list in the user's saved order. Never sorted
  /// by the app.
  List<BucketItem> get items => _items;
  int get completedCount => _items.where((i) => i.isCompleted).length;

  /// Level and EXP of the current journey, derived from [items].
  Progression get progression => Progression(completedCount);

  /// The journey the user is working on.
  Journey get journey => _journey;
  Profile get profile => _profile;

  /// When [j] started. Journey 1 takes the profile's started date until
  /// it is archived (the date is then frozen into the journey).
  CalendarDate? startOf(Journey j) =>
      j.startedOn ?? (j.isActive && j.number == 1 ? _profile.startedOn : null);

  /// The latest completion date on the current list: the day a finished
  /// journey was completed.
  CalendarDate? get lastCompletedOn {
    CalendarDate? last;
    for (final i in _items) {
      final d = i.completedOn;
      if (i.isCompleted &&
          d != null &&
          (last == null || d.compareTo(last) > 0)) {
        last = d;
      }
    }
    return last;
  }

  int memoryCountOf(String itemId) => _memoryCounts[itemId] ?? 0;
  ThemeMode get themeMode => _themeMode;
  bool get isFull => _items.length >= maxItems;

  BucketItem? itemById(String id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  Future<void> _reload() async {
    _journey = await _repo.activeJourney();
    _profile = await _repo.loadProfile();
    _items = List.unmodifiable(await _repo.loadItems());
    _memoryCounts = await _repo.memoryCounts();
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    _themeMode = switch (await _repo.getSetting('theme_mode')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  // ---------------------------------------------------------------- items

  Future<BucketItem> addItem(String title, String description) async {
    final item = await _repo.addItem(title, description);
    await _reload();
    return item;
  }

  Future<void> updateItemText(
    String id,
    String title,
    String description,
  ) async {
    await _repo.updateItemText(id, title, description);
    await _reload();
  }

  Future<void> setCompleted(
    String id,
    bool completed, {
    CalendarDate? on,
  }) async {
    await _repo.setCompleted(id, completed, on: on);
    await _reload();
  }

  Future<void> deleteItem(String id) async {
    final files = await _repo.deleteItem(id);
    await deleteArchiveFiles(files);
    memoryRevision++;
    await _reload();
  }

  /// Saves a new order chosen by the user.
  Future<void> saveOrder(List<String> orderedIds) async {
    // Show the new order immediately, then persist it.
    final byId = {for (final i in _items) i.id: i};
    _items = List.unmodifiable([for (final id in orderedIds) byId[id]!]);
    notifyListeners();
    try {
      await _repo.saveOrder(orderedIds);
    } finally {
      await _reload();
    }
  }

  Future<Set<String>> search(String query) => _repo.searchItemIds(query);

  // ------------------------------------------------------------- memories

  Future<List<Memory>> loadMemories(String itemId) =>
      _repo.loadMemories(itemId);

  /// Saves a memory. New (pending) photos are moved into the archive
  /// first; if the database write then fails, they are moved back so
  /// nothing is half-saved.
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
    await deleteArchiveFiles(removedFiles);
    memoryRevision++;
    await _reload();
    return id;
  }

  Future<void> deleteMemory(String id) async {
    final files = await _repo.deleteMemory(id);
    await deleteArchiveFiles(files);
    memoryRevision++;
    await _reload();
  }

  /// Deletes files (paths relative to the archive) after their database
  /// rows are gone. A failure only leaves an unused file behind.
  Future<void> deleteArchiveFiles(List<String> relativePaths) async {
    for (final rel in relativePaths) {
      try {
        final f = File(location.resolve(rel));
        if (await f.exists()) await f.delete();
      } catch (e) {
        logError('Could not delete $rel', e);
      }
    }
  }

  // ------------------------------------------------------------- journeys

  Future<List<JourneySummary>> journeySummaries() => _repo.journeySummaries();

  /// The items of any journey, in that journey's saved order.
  Future<List<BucketItem>> loadJourneyItems(String journeyId) =>
      _repo.loadItems(journeyId: journeyId);

  Future<Map<String, int>> memoryCountsFor(String journeyId) =>
      _repo.memoryCounts(journeyId: journeyId);

  Future<Set<String>> searchJourney(String journeyId, String query) =>
      _repo.searchItemIds(query, journeyId: journeyId);

  Future<List<AlbumEntry>> albumOutline(String journeyId) =>
      _repo.albumOutline(journeyId);

  Future<List<Memory>> loadMemoriesByIds(List<String> ids) =>
      _repo.loadMemoriesByIds(ids);

  /// Changes when the current journey started. For Journey 1 this is the
  /// profile's started date.
  Future<void> setJourneyStart(CalendarDate? date) async {
    if (_journey.number == 1) {
      await saveProfile(
        Profile(
          name: _profile.name,
          nickname: _profile.nickname,
          age: _profile.age,
          startedOn: date,
          bio: _profile.bio,
          photo: _profile.photo,
        ),
      );
      return;
    }
    await _repo.setJourneyStart(date);
    journeyRevision++;
    await _reload();
  }

  /// Archives the finished journey and begins the next one.
  ///
  /// Nothing is deleted. The profile as it is now (including a copy of
  /// the profile picture) is kept with the archived journey for its
  /// Life Album.
  Future<Journey> startNewJourney({
    required CalendarDate newStartedOn,
    required bool reuseList,
  }) async {
    String? photoCopy;
    final photo = _profile.photo;
    if (photo != null && await File(location.resolve(photo)).exists()) {
      photoCopy = 'profile/${ArchiveRepository.newId()}.jpg';
      await File(location.resolve(photo)).copy(location.resolve(photoCopy));
    }
    final Journey next;
    try {
      next = await _repo.archiveAndStartNew(
        startedOn: startOf(_journey),
        completedOn: lastCompletedOn ?? CalendarDate.today(),
        snapshot: _profile.isEmpty
            ? null
            : _profile.copyWith(
                photo: photoCopy,
                clearPhoto: photoCopy == null,
              ),
        newStartedOn: newStartedOn,
        reuseList: reuseList,
      );
    } catch (_) {
      if (photoCopy != null) await deleteArchiveFiles([photoCopy]);
      rethrow;
    }
    journeyRevision++;
    memoryRevision++;
    await _reload();
    return next;
  }

  // -------------------------------------------------------------- profile

  /// Saves the profile's text fields. The picture is changed with
  /// [setProfilePhoto] / [removeProfilePhoto].
  Future<void> saveProfile(Profile p) async {
    await _repo.saveProfile(
      Profile(
        name: p.name,
        nickname: p.nickname,
        age: p.age,
        startedOn: p.startedOn,
        bio: p.bio,
        photo: _profile.photo,
      ),
    );
    journeyRevision++;
    await _reload();
  }

  /// Stores [jpeg] (already cropped) as the profile picture. Each picture
  /// gets a new file name, so nothing shows a stale cached image.
  Future<void> setProfilePhoto(Uint8List jpeg) async {
    final rel = 'profile/${ArchiveRepository.newId()}.jpg';
    final file = File(location.resolve(rel));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(jpeg, flush: true);
    final old = _profile.photo;
    try {
      await _repo.saveProfile(_profile.copyWith(photo: rel));
    } catch (_) {
      await deleteArchiveFiles([rel]);
      rethrow;
    }
    if (old != null) await deleteArchiveFiles([old]);
    journeyRevision++;
    await _reload();
  }

  Future<void> removeProfilePhoto() async {
    final old = _profile.photo;
    await _repo.saveProfile(_profile.copyWith(clearPhoto: true));
    if (old != null) await deleteArchiveFiles([old]);
    journeyRevision++;
    await _reload();
  }

  // ------------------------------------------------------------- settings

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    await _repo.setSetting('theme_mode', mode.name);
  }

  // -------------------------------------------------------------- archive

  /// Closes the database, runs [swap] (which replaces the archive folder
  /// on disk) and reopens. If [swap] throws, the existing archive is
  /// reopened unchanged and the error is rethrown.
  Future<void> replaceArchive(Future<void> Function() swap) async {
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
    memoryRevision++;
    journeyRevision++;
    await _reload();
    await _loadSettings();
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }

  /// Replaces the whole archive with a validated backup. The current
  /// archive stays in place until the new one is completely built.
  Future<void> importBackup(ImportPreview preview) async {
    await buildIncomingArchive(preview, location, factory: factory);
    await replaceArchive(location.swapInIncoming);
  }

  /// Writes a backup .zip into [outDir].
  Future<ExportResult> exportBackup(
    Directory outDir,
    String appVersion, {
    void Function(double progress)? onProgress,
  }) => export_service.exportBackup(
    db: _db,
    archiveDir: location.live,
    outDir: outDir,
    appVersion: appVersion,
    onProgress: onProgress,
  );

  /// The whole archive as the backup's data.json structure (read-only).
  Future<Map<String, Object?>> archiveSnapshot() =>
      export_service.archiveSnapshot(_db);

  Future<void> close() => _db.close();
}
