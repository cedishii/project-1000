import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../data/archive_backend.dart';
import '../data/archive_location.dart';
import '../data/archive_repository.dart';
import '../data/local_archive.dart';
import '../data/models.dart';
import '../data/progression.dart';
import '../services/backup/export_service.dart' as export_service;
import '../services/backup/export_service.dart' show ExportResult;
import '../services/backup/import_service.dart';
import '../services/cloud/synced_archive.dart';
import '../services/media_store.dart';
import '../services/photo_storage.dart';

/// App-wide state: the current journey's list (in the user's order),
/// memory counts, the profile and settings. Screens listen to it and
/// call its methods to change data.
///
/// The data itself lives in an [ArchiveBackend]: this phone's archive
/// ([LocalArchive]) or the signed-in cloud account. Backup export and
/// import exist only for the local archive ([isLocal]).
class AppStore extends ChangeNotifier {
  AppStore(this.backend, this.media, {this.account, this.isOwner = false})
    : _local = null {
    // Changes made on other devices arrived in this phone's copy.
    if (backend case final SyncedArchive synced) {
      synced.dataVersion.addListener(_onRemoteChange);
    }
  }

  void _onRemoteChange() {
    memoryRevision++;
    journeyRevision++;
    load().catchError((Object e, StackTrace s) {});
  }

  /// How this phone's copy of the account stands (null when the archive
  /// isn't a synced copy: the phone's own, or the website).
  ValueListenable<SyncStatus>? get syncStatus => switch (backend) {
    SyncedArchive(:final status) => status,
    _ => null,
  };

  /// Brings in changes made elsewhere: syncs this phone's copy, or
  /// reloads the account's list on the website.
  Future<void> refresh() async {
    if (backend case final SyncedArchive synced) {
      await synced.sync();
    } else if (!isLocal) {
      await load();
    }
  }

  AppStore._local(LocalArchive local)
    : backend = local,
      media = LocalMedia(local.location, local.photos),
      account = null,
      isOwner = false,
      _local = local;

  /// Opens the archive in the app's private documents folder.
  static Future<AppStore> open({
    Directory? root,
    DatabaseFactory? factory,
  }) async {
    final dir = root ?? await getApplicationDocumentsDirectory();
    var rolledBack = false;
    final local = await LocalArchive.open(
      dir,
      factory: factory,
      onPrepared: (r) => rolledBack = r,
    );
    final store = AppStore._local(local)
      ..recoveredFromInterruptedImport = rolledBack;
    await store.load();
    return store;
  }

  final ArchiveBackend backend;
  final MediaStore media;

  /// The signed-in account (email) when the archive is in the cloud.
  final String? account;

  /// The cloud account is Project: 1000's owner (may manage members).
  final bool isOwner;
  final LocalArchive? _local;

  /// True when the archive is this phone's own (not a cloud account).
  bool get isLocal => _local != null;

  LocalArchive get _localArchive {
    final l = _local;
    if (l == null) throw StateError('Only available for the local archive');
    return l;
  }

  /// The local archive's folders (local archive only).
  ArchiveLocation get location => _localArchive.location;

  /// The local archive's photo files (local archive only).
  PhotoStorage get photos => _localArchive.photos;

  ArchiveRepository get repository => _localArchive.repository;

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

  /// Loads everything from the backend (on opening, or to refresh after
  /// another device changed something).
  Future<void> load() async {
    await _reload();
    await _loadSettings();
  }

  Future<void> _reload() async {
    _journey = await backend.activeJourney();
    _profile = await backend.loadProfile();
    _items = List.unmodifiable(await backend.loadItems());
    _memoryCounts = await backend.memoryCounts();
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    _themeMode = switch (await backend.getSetting('theme_mode')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  // ---------------------------------------------------------------- items

  Future<BucketItem> addItem(String title, String description) async {
    final item = await backend.addItem(title, description);
    await _reload();
    return item;
  }

  Future<void> updateItemText(
    String id,
    String title,
    String description,
  ) async {
    await backend.updateItemText(id, title, description);
    await _reload();
  }

  Future<void> setCompleted(
    String id,
    bool completed, {
    CalendarDate? on,
  }) async {
    await backend.setCompleted(id, completed, on: on);
    await _reload();
  }

  Future<void> deleteItem(String id) async {
    await backend.deleteItem(id);
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
      await backend.saveOrder(orderedIds);
    } finally {
      await _reload();
    }
  }

  Future<Set<String>> search(String query) => backend.searchItemIds(query);

  // ------------------------------------------------------------- memories

  Future<List<Memory>> loadMemories(String itemId) =>
      backend.loadMemories(itemId);

  /// Saves a memory with its photos. Nothing is half-saved: if storing
  /// the memory fails, its new photos are not kept either.
  Future<String> saveMemory(MemoryDraft draft) async {
    final id = await backend.saveMemory(draft);
    memoryRevision++;
    await _reload();
    return id;
  }

  Future<void> deleteMemory(String id) async {
    await backend.deleteMemory(id);
    memoryRevision++;
    await _reload();
  }

  // ------------------------------------------------------------- journeys

  Future<List<JourneySummary>> journeySummaries() => backend.journeySummaries();

  /// The items of any journey, in that journey's saved order.
  Future<List<BucketItem>> loadJourneyItems(String journeyId) =>
      backend.loadItems(journeyId: journeyId);

  Future<Map<String, int>> memoryCountsFor(String journeyId) =>
      backend.memoryCounts(journeyId: journeyId);

  Future<Set<String>> searchJourney(String journeyId, String query) =>
      backend.searchItemIds(query, journeyId: journeyId);

  Future<List<AlbumEntry>> albumOutline(String journeyId) =>
      backend.albumOutline(journeyId);

  Future<List<Memory>> loadMemoriesByIds(List<String> ids) =>
      backend.loadMemoriesByIds(ids);

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
    await backend.setJourneyStart(date);
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
    final next = await backend.startNewJourney(
      startedOn: startOf(_journey),
      completedOn: lastCompletedOn ?? CalendarDate.today(),
      profile: _profile,
      newStartedOn: newStartedOn,
      reuseList: reuseList,
    );
    journeyRevision++;
    memoryRevision++;
    await _reload();
    return next;
  }

  // -------------------------------------------------------------- profile

  /// Saves the profile's text fields. The picture is changed with
  /// [setProfilePhoto] / [removeProfilePhoto].
  Future<void> saveProfile(Profile p) async {
    await backend.saveProfile(
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

  /// Stores [jpeg] (already cropped) as the profile picture.
  Future<void> setProfilePhoto(Uint8List jpeg) async {
    await backend.setProfilePhoto(_profile, jpeg);
    journeyRevision++;
    await _reload();
  }

  Future<void> removeProfilePhoto() async {
    await backend.removeProfilePhoto(_profile);
    journeyRevision++;
    await _reload();
  }

  // ------------------------------------------------------------- settings

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    await backend.setSetting('theme_mode', mode.name);
  }

  // ------------------------------------------------- local archive only

  /// Closes the database, runs [swap] (which replaces the archive folder
  /// on disk) and reopens. If [swap] throws, the existing archive is
  /// reopened unchanged and the error is rethrown.
  Future<void> replaceArchive(Future<void> Function() swap) async {
    Object? error;
    StackTrace? stack;
    try {
      await _localArchive.replace(swap);
    } catch (e, s) {
      error = e;
      stack = s;
    }
    memoryRevision++;
    journeyRevision++;
    await load();
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }

  /// Replaces the whole archive with a validated backup. The current
  /// archive stays in place until the new one is completely built.
  Future<void> importBackup(ImportPreview preview) async {
    await buildIncomingArchive(
      preview,
      location,
      factory: _localArchive.factory,
    );
    await replaceArchive(location.swapInIncoming);
  }

  /// Writes a backup .zip into [outDir].
  Future<ExportResult> exportBackup(
    Directory outDir,
    String appVersion, {
    void Function(double progress)? onProgress,
  }) => export_service.exportBackup(
    db: _localArchive.db,
    archiveDir: location.live,
    outDir: outDir,
    appVersion: appVersion,
    onProgress: onProgress,
  );

  /// The whole local archive as the backup's data.json structure
  /// (read-only).
  Future<Map<String, Object?>> archiveSnapshot() =>
      export_service.archiveSnapshot(_localArchive.db);

  Future<void> close() async {
    await _local?.close();
    if (backend case final SyncedArchive synced) {
      synced.dataVersion.removeListener(_onRemoteChange);
      await synced.close();
    }
  }
}
