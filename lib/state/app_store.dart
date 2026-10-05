import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/archive_location.dart';
import '../data/archive_repository.dart';
import '../data/database.dart';
import '../data/models.dart';
import '../services/backup/export_service.dart' as export_service;
import '../services/backup/export_service.dart' show ExportResult;
import '../services/backup/import_service.dart';
import '../services/photo_storage.dart';

/// App-wide state: the list (in the user's order), memory counts and
/// settings. Screens listen to it and call its methods to change data.
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

  /// Bumped whenever memories change, so open screens can reload.
  int memoryRevision = 0;

  /// The list in the user's saved order. Never sorted by the app.
  List<BucketItem> get items => _items;
  int get completedCount => _items.where((i) => i.isCompleted).length;
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

  Future<void> updateItemText(String id, String title, String description) async {
    await _repo.updateItemText(id, title, description);
    await _reload();
  }

  Future<void> setCompleted(String id, bool completed, {CalendarDate? on}) async {
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
      (id, removedFiles) = await _repo.saveMemory(MemoryDraft(
        id: draft.id,
        itemId: draft.itemId,
        title: draft.title,
        body: draft.body,
        date: draft.date,
        location: draft.location,
        hashtags: draft.hashtags,
        photos: committed,
      ));
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
        dev.log('Could not delete $rel: $e', name: 'archive');
      }
    }
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
  Future<ExportResult> exportBackup(Directory outDir, String appVersion) =>
      export_service.exportBackup(
        db: _db,
        archiveDir: location.live,
        outDir: outDir,
        appVersion: appVersion,
      );

  Future<void> close() => _db.close();
}
