import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/log.dart';
import '../../data/archive_backend.dart';
import '../../data/archive_location.dart';
import '../../data/archive_repository.dart';
import '../../data/local_archive.dart';
import '../../data/models.dart';
import '../media_store.dart';
import '../photo_storage.dart';
import 'cloud_archive.dart';
import 'cloud_media.dart';

/// Where a phone's copy of the account stands.
@immutable
class SyncStatus {
  const SyncStatus({
    this.pending = 0,
    this.offline = false,
    this.syncing = false,
    this.lastSynced,
  });

  /// Changes made on this phone that the account doesn't have yet.
  final int pending;

  /// The last attempt couldn't reach the account.
  final bool offline;
  final bool syncing;
  final DateTime? lastSynced;

  SyncStatus copyWith({
    int? pending,
    bool? offline,
    bool? syncing,
    DateTime? lastSynced,
  }) => SyncStatus(
    pending: pending ?? this.pending,
    offline: offline ?? this.offline,
    syncing: syncing ?? this.syncing,
    lastSynced: lastSynced ?? this.lastSynced,
  );
}

/// The signed-in account's list on a phone, usable offline.
///
/// The phone keeps a full copy of the account in its own database (the
/// same format as the phone's own archive, in `cloud_cache/<user id>/`),
/// so everything opens and can be changed without a connection:
///
/// * Every change is made in the copy first and recorded in an outbox
///   (`outbox.json`, kept on disk, so it survives restarts).
/// * Whenever the account can be reached, the outbox is sent in order
///   with the same retry-safe server functions the website uses, keeping
///   every id; then the copy catches up with changes made elsewhere
///   (`pull_changes`). The server's changes are only applied while
///   nothing is waiting to be sent, so a change made here is never
///   overwritten before it has reached the account.
/// * If a change can't be applied any more (for example the thing was
///   deleted on the website meanwhile), it is skipped and the copy is
///   rebuilt from the account, so both end up the same.
/// * Edits of the same thing on two devices: the last one to reach the
///   account wins.
/// * Starting a new journey needs a connection.
class SyncedArchive implements ArchiveBackend {
  SyncedArchive._(
    this.cacheRoot,
    this.cache,
    this.remote,
    this._outbox,
    this._stateFile,
    this._revision,
  );

  /// Opens (or creates) this phone's copy of the signed-in account in
  /// [root]. The first time, the account must be reachable to fill it.
  static Future<SyncedArchive> open({
    required Directory root,
    required SupabaseClient client,
    DatabaseFactory? factory,
  }) async {
    final dir = cacheDir(root, client.auth.currentUser!.id);
    await dir.create(recursive: true);
    final cache = await LocalArchive.open(dir, factory: factory);
    final remote = CloudArchive(client, CloudMedia(client));
    final stateFile = File(p.join(dir.path, 'sync.json'));
    int? revision;
    if (await stateFile.exists()) {
      try {
        revision =
            (jsonDecode(await stateFile.readAsString()) as Map)['revision']
                as int?;
      } catch (e) {
        logError('sync.json unreadable', e);
      }
    }
    final archive = SyncedArchive._(
      dir,
      cache,
      remote,
      await _Outbox.load(File(p.join(dir.path, 'outbox.json'))),
      stateFile,
      revision,
    );
    archive.status.value = SyncStatus(pending: archive._outbox.length);
    try {
      if (revision == null) await archive._rebuild();
      // A brand-new account has no journey yet (nothing was copied into
      // it): start Journey 1 in the account, as a new phone does, and
      // fetch it. Also repairs a copy made before this was done.
      if ((await cache.db.query(
        'journeys',
        where: "status = 'active'",
      )).isEmpty) {
        await remote.activeJourney();
        await archive._rebuild();
      }
    } catch (_) {
      await cache.close();
      rethrow;
    }
    return archive;
  }

  static Directory cacheDir(Directory root, String userId) =>
      Directory(p.join(root.path, 'cloud_cache', userId));

  /// Removes every account copy on this phone (after signing out).
  static Future<void> deleteAll(Directory root) async {
    final dir = Directory(p.join(root.path, 'cloud_cache'));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  final Directory cacheRoot;
  final LocalArchive cache;
  final CloudArchive remote;
  final _Outbox _outbox;
  final File _stateFile;
  int? _revision;

  final status = ValueNotifier(const SyncStatus());

  /// Bumped whenever the copy changed because of the account (another
  /// device's changes arrived), so the app can reload.
  final dataVersion = ValueNotifier(0);

  ArchiveLocation get location => cache.location;
  int get pending => _outbox.length;

  Future<void> _lock = Future.value();
  Future<void>? _syncing;
  Timer? _retry;
  bool _closed = false;

  /// Runs [f] with no other copy change or outbox change in between.
  Future<T> _locked<T>(Future<T> Function() f) {
    final result = _lock.then((_) => f());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  // ---------------------------------------------------------------- reads

  @override
  Future<Journey> activeJourney() => cache.activeJourney();

  @override
  Future<Profile> loadProfile() => cache.loadProfile();

  @override
  Future<List<BucketItem>> loadItems({String? journeyId}) =>
      cache.loadItems(journeyId: journeyId);

  @override
  Future<Map<String, int>> memoryCounts({String? journeyId}) =>
      cache.memoryCounts(journeyId: journeyId);

  @override
  Future<Set<String>> searchItemIds(String query, {String? journeyId}) =>
      cache.searchItemIds(query, journeyId: journeyId);

  @override
  Future<List<Memory>> loadMemories(String itemId) =>
      cache.loadMemories(itemId);

  @override
  Future<List<Memory>> loadMemoriesByIds(List<String> ids) =>
      cache.loadMemoriesByIds(ids);

  @override
  Future<List<JourneySummary>> journeySummaries() => cache.journeySummaries();

  @override
  Future<List<AlbumEntry>> albumOutline(String journeyId) =>
      cache.albumOutline(journeyId);

  @override
  Future<String?> getSetting(String key) => cache.getSetting(key);

  // --------------------------------------------------------------- writes

  /// Makes a change in the copy, records it for the account, and tries
  /// to send it right away.
  Future<T> _change<T>(
    Future<(T, Map<String, Object?>)> Function() apply,
  ) async {
    final result = await _locked(() async {
      final (value, op) = await apply();
      await _outbox.add(op);
      _setStatus(pending: _outbox.length);
      return value;
    });
    unawaited(sync());
    return result;
  }

  @override
  Future<BucketItem> addItem(String title, String description) =>
      _change(() async {
        final item = await cache.addItem(title, description);
        return (
          item,
          {
            'op': 'addItem',
            'id': item.id,
            'title': title,
            'description': description,
          },
        );
      });

  @override
  Future<void> updateItemText(String id, String title, String description) =>
      _change(() async {
        await cache.updateItemText(id, title, description);
        return (
          null,
          {
            'op': 'updateItem',
            'id': id,
            'title': title,
            'description': description,
          },
        );
      });

  @override
  Future<void> setCompleted(String id, bool completed, {CalendarDate? on}) {
    // The day is fixed now, so the account gets the day it happened.
    final day = on ?? CalendarDate.today();
    return _change(() async {
      await cache.setCompleted(id, completed, on: day);
      return (
        null,
        {
          'op': 'setCompleted',
          'id': id,
          'completed': completed,
          'on': day.toIso(),
        },
      );
    });
  }

  @override
  Future<void> deleteItem(String id) => _change(() async {
    await cache.deleteItem(id);
    return (null, {'op': 'deleteItem', 'id': id});
  });

  @override
  Future<void> saveOrder(List<String> orderedIds) => _change(() async {
    await cache.saveOrder(orderedIds);
    return (null, {'op': 'saveOrder', 'ids': orderedIds});
  });

  @override
  Future<String> saveMemory(MemoryDraft draft) => _change(() async {
    final newPhotos = {
      for (final ph in draft.photos)
        if (PhotoStorage.isPending(ph)) ph.id,
    };
    final id = await cache.saveMemory(draft);
    final memory = (await cache.loadMemoriesByIds([id])).single;
    return (
      id,
      {
        'op': 'saveMemory',
        'memory': {
          'id': memory.id,
          'itemId': memory.itemId,
          'title': memory.title,
          'text': memory.body,
          'date': memory.date.toIso(),
          'location': memory.location,
          'hashtags': memory.hashtags,
          'photos': [
            for (final ph in memory.photos)
              {
                'id': ph.id,
                'file': ph.file,
                'thumb': ph.thumb,
                'width': ph.width,
                'height': ph.height,
                'createdAt': ph.createdAt.toUtc().toIso8601String(),
              },
          ],
        },
        // Files to upload from this phone (new photos only).
        'uploads': [
          for (final ph in memory.photos)
            if (newPhotos.contains(ph.id)) ...[ph.file, ph.thumb],
        ],
      },
    );
  });

  @override
  Future<void> deleteMemory(String id) => _change(() async {
    await cache.deleteMemory(id);
    return (null, {'op': 'deleteMemory', 'id': id});
  });

  @override
  Future<void> setJourneyStart(CalendarDate? date) => _change(() async {
    await cache.setJourneyStart(date);
    return (null, {'op': 'setJourneyStart', 'date': date?.toIso()});
  });

  /// Needs the account: everything waiting is sent first, then the
  /// journey is archived there and the copy rebuilt from it.
  @override
  Future<Journey> startNewJourney({
    required CalendarDate? startedOn,
    required CalendarDate completedOn,
    required Profile profile,
    required CalendarDate newStartedOn,
    required bool reuseList,
  }) async {
    await sync();
    if (_outbox.length > 0) {
      throw CloudUnavailableException('changes still waiting to be sent');
    }
    final journey = await remote.startNewJourney(
      startedOn: startedOn,
      completedOn: completedOn,
      profile: profile,
      newStartedOn: newStartedOn,
      reuseList: reuseList,
    );
    await _rebuild();
    return journey;
  }

  @override
  Future<void> saveProfile(Profile profile) => _change(() async {
    await cache.saveProfile(profile);
    return (null, {'op': 'saveProfile', 'profile': profile.toJson()});
  });

  @override
  Future<void> setProfilePhoto(Profile current, Uint8List jpeg) =>
      _change(() async {
        await cache.setProfilePhoto(current, jpeg);
        final saved = await cache.loadProfile();
        return (
          null,
          {
            'op': 'setProfilePhoto',
            'profile': saved.toJson(),
            'old': current.photo,
          },
        );
      });

  @override
  Future<void> removeProfilePhoto(Profile current) => _change(() async {
    await cache.removeProfilePhoto(current);
    return (null, {'op': 'removeProfilePhoto', 'profile': current.toJson()});
  });

  @override
  Future<void> setSetting(String key, String value) => _change(() async {
    await cache.setSetting(key, value);
    return (null, {'op': 'setSetting', 'key': key, 'value': value});
  });

  // ----------------------------------------------------------------- sync

  /// Sends everything waiting, then brings in changes made elsewhere.
  /// Safe to call any time; concurrent calls share one run. Never throws:
  /// problems are reflected in [status].
  Future<void> sync() => _syncing ??= _sync().whenComplete(() {
    _syncing = null;
  });

  Future<void> _sync() async {
    if (_closed) return;
    _setStatus(syncing: true);
    var dropped = false;
    try {
      for (var round = 0; round < 5; round++) {
        // 1. Send the outbox, oldest first.
        while (_outbox.length > 0) {
          final op = _outbox.first;
          try {
            await _send(op);
          } catch (e, s) {
            // Only a definite refusal (e.g. the thing was deleted
            // elsewhere) skips a change; anything else — offline, a
            // storage hiccup — keeps it waiting and retries later, so a
            // change is never lost to a temporary problem.
            if (!_refused(e)) rethrow;
            logError('Skipped a change the account refused: ${op['op']}', e, s);
            dropped = true;
          }
          await _locked(() async {
            await _outbox.removeFirst();
            _setStatus(pending: _outbox.length);
          });
        }
        // 2. Catch up — only applied while nothing is waiting.
        final applied = dropped || _revision == null
            ? await _rebuild()
            : await _pull();
        if (applied) {
          dropped = false;
          break;
        }
      }
      _setStatus(offline: false, lastSynced: DateTime.now());
    } catch (e, s) {
      if (!_isOffline(e)) logError('Sync failed', e, s);
      _setStatus(offline: true);
      _scheduleRetry();
    } finally {
      _setStatus(syncing: false);
    }
  }

  /// The account definitely won't accept this change, now or later.
  static bool _refused(Object e) {
    if (e is ItemNotFoundException ||
        e is StaleDataException ||
        e is ListFullException ||
        e is JourneyNotCompleteException ||
        e is _Unsendable) {
      return true;
    }
    if (e is PostgrestException) {
      final code = e.code ?? '';
      // PT4xx: the app's own refusals; 22/23: invalid data.
      return code.startsWith('PT4') ||
          code.startsWith('22') ||
          code.startsWith('23');
    }
    return false;
  }

  static bool _isOffline(Object e) =>
      e is CloudUnavailableException ||
      e.toString().contains('SocketException') ||
      e.toString().contains('ClientException');

  void _scheduleRetry() {
    if (_closed || (_retry?.isActive ?? false)) return;
    _retry = Timer(const Duration(minutes: 1), () {
      if (_outbox.length > 0 || status.value.offline) unawaited(sync());
    });
  }

  void _setStatus({
    int? pending,
    bool? offline,
    bool? syncing,
    DateTime? lastSynced,
  }) {
    if (_closed) return;
    status.value = status.value.copyWith(
      pending: pending,
      offline: offline,
      syncing: syncing,
      lastSynced: lastSynced,
    );
  }

  Future<void> _send(Map<String, Object?> op) async {
    String s(String k) => op[k] as String;
    switch (op['op']) {
      case 'addItem':
        await remote.addItemWithId(s('id'), s('title'), s('description'));
      case 'updateItem':
        await remote.updateItemTextChecked(
          s('id'),
          s('title'),
          s('description'),
          checkRevision: false,
        );
      case 'setCompleted':
        await remote.setCompleted(
          s('id'),
          op['completed'] as bool,
          on: CalendarDate.parse(s('on')),
        );
      case 'deleteItem':
        await remote.deleteItem(s('id'));
      case 'saveOrder':
        await remote.saveOrder((op['ids'] as List).cast<String>());
      case 'saveMemory':
        final uploads = <String, Uint8List>{};
        for (final path in (op['uploads'] as List).cast<String>()) {
          final f = File(cache.location.resolve(path));
          if (await f.exists()) uploads[path] = await f.readAsBytes();
        }
        await remote.saveMemoryRow(
          (op['memory'] as Map).cast(),
          uploads: uploads,
        );
      case 'deleteMemory':
        await remote.deleteMemory(s('id'));
      case 'setJourneyStart':
        final d = op['date'] as String?;
        await remote.setJourneyStart(d == null ? null : CalendarDate.parse(d));
      case 'saveProfile':
        await remote.saveProfile(Profile.fromJson(op['profile'] as Map));
      case 'setProfilePhoto':
        final profile = Profile.fromJson(op['profile'] as Map);
        final f = File(cache.location.resolve(profile.photo!));
        if (!await f.exists()) throw const _Unsendable('picture file gone');
        await remote.setProfilePhotoAt(
          profile,
          profile.photo!,
          await f.readAsBytes(),
          oldPhoto: op['old'] as String?,
        );
      case 'removeProfilePhoto':
        await remote.removeProfilePhoto(Profile.fromJson(op['profile'] as Map));
      case 'setSetting':
        await remote.setSetting(s('key'), s('value'));
      default:
        throw _Unsendable('unknown change ${op['op']}');
    }
  }

  /// Applies the account's changes since the last sync. Returns false if
  /// something new is waiting to be sent (then nothing is applied).
  Future<bool> _pull() async {
    final changes = await remote.pullChanges(_revision ?? 0);
    try {
      return await _apply(changes, full: false);
    } catch (e, s) {
      // E.g. an item numbered differently by the account than offline
      // here: start the copy over from the account.
      logError('Copy update failed; rebuilding', e, s);
      return _rebuild();
    }
  }

  /// Replaces the copy with the account's current list. Returns false if
  /// something new is waiting to be sent (then nothing is replaced).
  Future<bool> _rebuild() async =>
      _apply(await remote.pullChanges(0), full: true);

  Future<bool> _apply(Map<String, Object?> changes, {required bool full}) =>
      _locked(() async {
        if (_outbox.length > 0) return false;
        final rows =
            (changes['journeys'] as List).length +
            (changes['items'] as List).length +
            (changes['memories'] as List).length +
            (changes['photos'] as List).length +
            (changes['profiles'] as List).length +
            (changes['settings'] as List).length +
            (changes['deletions'] as List).length;
        await cache.db.transaction((txn) async {
          if (full) {
            for (final t in [
              'photos',
              'memory_tags',
              'memories',
              'items',
              'journeys',
              'profile',
              'settings',
            ]) {
              await txn.delete(t);
            }
          } else {
            await _applyDeletions(txn, changes['deletions'] as List);
          }
          await _applyRows(txn, changes);
        });
        _revision = changes['revision'] as int;
        await _saveState();
        if (full || rows > 0) dataVersion.value++;
        return true;
      });

  static Future<void> _applyDeletions(Transaction txn, List deletions) async {
    // Children first; cascades in the cache take care of the rest.
    const order = [
      'photos',
      'memories',
      'items',
      'journeys',
      'settings',
      'profiles',
    ];
    final sorted = deletions.cast<Map>().toList()
      ..sort(
        (a, b) => order
            .indexOf(a['table'] as String)
            .compareTo(order.indexOf(b['table'] as String)),
      );
    for (final d in sorted) {
      final id = d['id'] as String;
      switch (d['table']) {
        case 'photos' || 'memories' || 'items' || 'journeys':
          await txn.delete(
            d['table'] as String,
            where: 'id = ?',
            whereArgs: [id],
          );
        case 'settings':
          await txn.delete('settings', where: 'key = ?', whereArgs: [id]);
        case 'profiles':
          await txn.delete('profile');
      }
    }
  }

  static String _ts(Object? v) =>
      DateTime.parse('$v').toUtc().toIso8601String();
  static String? _tsOrNull(Object? v) => v == null ? null : _ts(v);

  /// Inserts or updates every row (no SQLite upsert syntax: Android 7's
  /// SQLite predates it).
  static Future<void> _applyRows(Transaction txn, Map changes) async {
    Future<void> put(String table, String key, Map<String, Object?> row) async {
      final n = await txn.update(
        table,
        row,
        where: '$key = ?',
        whereArgs: [row[key]],
      );
      if (n == 0) await txn.insert(table, row);
    }

    for (final j in (changes['journeys'] as List).cast<Map>()) {
      await put('journeys', 'id', {
        'id': j['id'],
        'number': j['number'],
        'status': j['status'],
        'started_on': j['started_on'],
        'completed_on': j['completed_on'],
        'snapshot': j['snapshot'] == null ? null : jsonEncode(j['snapshot']),
        'created_at': _ts(j['created_at']),
        'archived_at': _tsOrNull(j['archived_at']),
      });
    }
    for (final i in (changes['items'] as List).cast<Map>()) {
      await put('items', 'id', {
        'id': i['id'],
        'journey_id': i['journey_id'],
        'number': i['number'],
        'position': i['position'],
        'title': i['title'],
        'description': i['description'],
        'is_completed': i['is_completed'] == true ? 1 : 0,
        'completed_on': i['completed_on'],
        'created_at': _ts(i['created_at']),
        'updated_at': _ts(i['updated_at']),
      });
    }
    for (final m in (changes['memories'] as List).cast<Map>()) {
      await put('memories', 'id', {
        'id': m['id'],
        'item_id': m['item_id'],
        'position': m['position'],
        'title': m['title'],
        'body': m['body'],
        'date': m['date'],
        'location': m['location'],
        'created_at': _ts(m['created_at']),
        'updated_at': _ts(m['updated_at']),
      });
      await txn.delete(
        'memory_tags',
        where: 'memory_id = ?',
        whereArgs: [m['id']],
      );
      final tags = (m['hashtags'] as List).cast<String>();
      for (var k = 0; k < tags.length; k++) {
        await txn.insert('memory_tags', {
          'memory_id': m['id'],
          'position': k,
          'tag': tags[k],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    for (final ph in (changes['photos'] as List).cast<Map>()) {
      await put('photos', 'id', {
        'id': ph['id'],
        'memory_id': ph['memory_id'],
        'position': ph['position'],
        'file': ph['file'],
        'thumb': ph['thumb'],
        'width': ph['width'],
        'height': ph['height'],
        'created_at': _ts(ph['created_at']),
      });
    }
    for (final pr in (changes['profiles'] as List).cast<Map>()) {
      await put('profile', 'id', {
        'id': 1,
        'name': pr['name'],
        'nickname': pr['nickname'],
        'age': pr['age'],
        'started_on': pr['started_on'],
        'bio': pr['bio'],
        'photo': pr['photo'],
        'updated_at': _ts(pr['updated_at']),
      });
    }
    for (final st in (changes['settings'] as List).cast<Map>()) {
      await put('settings', 'key', {'key': st['key'], 'value': st['value']});
    }
  }

  Future<void> _saveState() async {
    final tmp = File('${_stateFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({'revision': _revision}), flush: true);
    await tmp.rename(_stateFile.path);
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _syncing;
    await _lock;
    await cache.close();
  }
}

/// The changes made on this phone that the account doesn't have yet, in
/// order, saved to disk after every change.
class _Outbox {
  _Outbox(this._file, this._ops);

  static Future<_Outbox> load(File file) async {
    var ops = <Map<String, Object?>>[];
    if (await file.exists()) {
      ops = [
        for (final o in jsonDecode(await file.readAsString()) as List)
          (o as Map).cast<String, Object?>(),
      ];
    }
    return _Outbox(file, ops);
  }

  final File _file;
  final List<Map<String, Object?>> _ops;

  int get length => _ops.length;
  Map<String, Object?> get first => _ops.first;

  Future<void> add(Map<String, Object?> op) async {
    _ops.add(op);
    await _save();
  }

  Future<void> removeFirst() async {
    _ops.removeAt(0);
    await _save();
  }

  Future<void> _save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_ops), flush: true);
    await tmp.rename(_file.path);
  }
}

/// Photos of the account's copy on this phone: kept in the copy's
/// folder, downloaded from the account the first time they are needed
/// (so photos seen once stay available offline).
class SyncedMedia implements MediaStore {
  SyncedMedia(this.archive, this.cloud)
    : _local = LocalMedia(archive.location, archive.cache.photos);

  final SyncedArchive archive;
  final CloudMedia cloud;
  final LocalMedia _local;

  File _file(String path) => File(archive.location.resolve(path));

  Future<Uint8List?> _fetch(String path) async {
    final bytes = await cloud.read(path);
    if (bytes == null) return null;
    try {
      final f = _file(path);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
    } catch (e) {
      logError('Could not keep $path on this phone', e);
    }
    return bytes;
  }

  @override
  ImageProvider image(String path) {
    if (_file(path).existsSync()) return _local.image(path);
    return BytesImage('synced:${cloud.keyOf(path)}', () async {
      final bytes = await _fetch(path);
      if (bytes == null) throw StateError('Photo unavailable: $path');
      return bytes;
    });
  }

  @override
  Future<String?> localFile(String path) async {
    if (await _file(path).exists()) return _file(path).path;
    return await _fetch(path) == null ? null : _file(path).path;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final f = _file(path);
    if (await f.exists()) return f.readAsBytes();
    return _fetch(path);
  }

  @override
  Future<PhotoRef> addPending(XFile picked) => _local.addPending(picked);

  @override
  Future<void> discard(Iterable<PhotoRef> photos) => _local.discard(photos);
}

/// A recorded change that can never be sent (its file is gone).
class _Unsendable implements Exception {
  const _Unsendable(this.reason);

  final String reason;

  @override
  String toString() => 'Unsendable change: $reason';
}
