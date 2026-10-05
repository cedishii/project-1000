import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

class ListFullException implements Exception {
  @override
  String toString() => 'The list already has $maxItems things.';
}

/// Thrown when an item (or memory) is not on the current journey's list:
/// it was deleted, or it belongs to an archived journey, which is a
/// read-only historical record.
class ItemNotFoundException implements Exception {}

/// A journey can only be archived when all 1,000 things are completed.
class JourneyNotCompleteException implements Exception {}

/// Everything needed to save a memory (new or edited).
class MemoryDraft {
  MemoryDraft({
    this.id,
    required this.itemId,
    required this.title,
    required this.body,
    required this.date,
    required this.location,
    required this.hashtags,
    required this.photos,
  });

  /// Null for a new memory.
  final String? id;
  final String itemId;
  final String title;
  final String body;
  final CalendarDate date;
  final String location;
  final List<String> hashtags;

  /// The photos the memory should have, in display order. Existing photos
  /// not in this list are removed.
  final List<PhotoRef> photos;
}

/// The size of one memory, for laying out a Life Album.
class AlbumMemoryMeta {
  const AlbumMemoryMeta({
    required this.id,
    required this.textLength,
    required this.photoCount,
  });

  final String id;
  final int textLength;
  final int photoCount;
}

/// A completed item and the outline of its memories.
class AlbumEntry {
  const AlbumEntry({required this.item, required this.memories});

  final BucketItem item;
  final List<AlbumMemoryMeta> memories;
}

/// All reads and writes of the archive database. Every multi-step write
/// runs inside a transaction so it either fully happens or not at all.
///
/// The list, its memories and its photos can only be changed on the
/// active journey; archived journeys are read-only.
class ArchiveRepository {
  ArchiveRepository(this.db);

  final Database db;
  static const _uuid = Uuid();

  static String newId() => _uuid.v4();
  static String _now() => DateTime.now().toUtc().toIso8601String();

  /// SQL for the active journey's id.
  static const _active = "(SELECT id FROM journeys WHERE status = 'active')";

  // ---------------------------------------------------------------- items

  /// The items of [journeyId] (default: the active journey) in the
  /// user's order. This is the only ordering the app ever uses.
  Future<List<BucketItem>> loadItems({String? journeyId}) async {
    final rows = await db.query(
      'items',
      where: journeyId == null ? 'journey_id = $_active' : 'journey_id = ?',
      whereArgs: [?journeyId],
      orderBy: 'position, rowid',
    );
    return rows.map(_itemFromRow).toList();
  }

  Future<BucketItem?> getItem(String id) async {
    final rows = await db.query('items', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _itemFromRow(rows.first);
  }

  /// Adds a new item at the end of the current journey's list.
  ///
  /// It gets the lowest number not currently in use, so the list always
  /// stays within #1–#1000 and existing numbers never change.
  Future<BucketItem> addItem(String title, String description) {
    return db.transaction((txn) async {
      final journeyId = await _activeJourneyId(txn);
      final numbers = (await txn.query(
        'items',
        columns: ['number'],
        where: 'journey_id = ?',
        whereArgs: [journeyId],
        orderBy: 'number',
      )).map((r) => r['number'] as int).toList();
      if (numbers.length >= maxItems) throw ListFullException();
      var number = 1;
      for (final n in numbers) {
        if (n != number) break;
        number++;
      }
      final maxPos =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT MAX(position) FROM items WHERE journey_id = ?',
              [journeyId],
            ),
          ) ??
          -1;
      final now = _now();
      final row = {
        'id': newId(),
        'journey_id': journeyId,
        'number': number,
        'position': maxPos + 1,
        'title': title.trim(),
        'description': description.trim(),
        'is_completed': 0,
        'completed_on': null,
        'created_at': now,
        'updated_at': now,
      };
      await txn.insert(
        'items',
        row,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return _itemFromRow(row);
    });
  }

  Future<void> updateItemText(String id, String title, String description) =>
      _updateItem(id, {
        'title': title.trim(),
        'description': description.trim(),
      });

  /// Marks an item completed on [on], or not completed.
  ///
  /// Un-completing keeps the previous completion date on record.
  Future<void> setCompleted(String id, bool completed, {CalendarDate? on}) =>
      _updateItem(id, {
        'is_completed': completed ? 1 : 0,
        if (completed) 'completed_on': (on ?? CalendarDate.today()).toIso(),
      });

  Future<void> _updateItem(String id, Map<String, Object?> values) async {
    final count = await db.update(
      'items',
      {...values, 'updated_at': _now()},
      where: 'id = ? AND journey_id = $_active',
      whereArgs: [id],
    );
    if (count == 0) throw ItemNotFoundException();
  }

  /// Deletes an item with all its memories and photo records.
  /// Returns the photo files (relative paths) that are no longer used.
  Future<List<String>> deleteItem(String id) {
    return db.transaction((txn) async {
      final files = await txn.rawQuery(
        '''
        SELECT p.file, p.thumb FROM photos p
        JOIN memories m ON m.id = p.memory_id
        WHERE m.item_id = ?''',
        [id],
      );
      final n = await txn.delete(
        'items',
        where: 'id = ? AND journey_id = $_active',
        whereArgs: [id],
      );
      if (n == 0) throw ItemNotFoundException();
      return _filesOf(files);
    });
  }

  /// Saves a new order. [orderedIds] must contain exactly the current
  /// journey's items; otherwise nothing is changed.
  Future<void> saveOrder(List<String> orderedIds) {
    return db.transaction((txn) async {
      final current = await txn.query(
        'items',
        columns: ['id', 'position'],
        where: 'journey_id = $_active',
      );
      final positions = {
        for (final r in current) r['id'] as String: r['position'] as int,
      };
      if (orderedIds.length != positions.length ||
          orderedIds.toSet().length != orderedIds.length ||
          !orderedIds.every(positions.containsKey)) {
        throw StateError('Order does not match the current list');
      }
      final batch = txn.batch();
      for (var i = 0; i < orderedIds.length; i++) {
        if (positions[orderedIds[i]] != i) {
          batch.update(
            'items',
            {'position': i},
            where: 'id = ?',
            whereArgs: [orderedIds[i]],
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }

  /// Number of memories per item id, for the items of [journeyId]
  /// (default: the active journey).
  Future<Map<String, int>> memoryCounts({String? journeyId}) async {
    final rows = await db.rawQuery(
      '''
      SELECT m.item_id, COUNT(*) AS c FROM memories m
        JOIN items i ON i.id = m.item_id
        WHERE i.journey_id = ${journeyId == null ? _active : '?'}
        GROUP BY m.item_id''',
      [?journeyId],
    );
    return {for (final r in rows) r['item_id'] as String: r['c'] as int};
  }

  /// Ids of items matching [query] in their number, title, description,
  /// or any memory's title, text, location or hashtags.
  ///
  /// Returns a set: callers filter the list they already have, so the
  /// user's order is untouched. Only items of [journeyId] (default: the
  /// active journey) are returned.
  Future<Set<String>> searchItemIds(String query, {String? journeyId}) async {
    final term = query.trim().replaceFirst(RegExp(r'^#'), '');
    if (term.isEmpty) return {};
    final like =
        '%${term.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%';
    final number = int.tryParse(term);
    final rows = await db.rawQuery(
      '''
      SELECT id FROM items
        WHERE journey_id = ${journeyId == null ? _active : '?'} AND id IN (
          SELECT id FROM items
            WHERE number = ? OR title LIKE ? ESCAPE '\\'
               OR description LIKE ? ESCAPE '\\'
          UNION
          SELECT item_id FROM memories
            WHERE title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\'
               OR location LIKE ? ESCAPE '\\'
          UNION
          SELECT m.item_id FROM memory_tags t
            JOIN memories m ON m.id = t.memory_id
            WHERE t.tag LIKE ? ESCAPE '\\')
    ''',
      [?journeyId, number ?? -1, like, like, like, like, like, like],
    );
    return {for (final r in rows) r['id'] as String};
  }

  // ------------------------------------------------------------- memories

  /// An item's memories, in the order they were added.
  Future<List<Memory>> loadMemories(String itemId) async => _withDetails(
    await db.query(
      'memories',
      where: 'item_id = ?',
      whereArgs: [itemId],
      orderBy: 'position, rowid',
    ),
  );

  /// The memories with the given ids, in the order of [ids].
  Future<List<Memory>> loadMemoriesByIds(List<String> ids) async {
    final out = <String, Memory>{};
    // SQLite limits the number of parameters per statement.
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, (i + 500).clamp(0, ids.length));
      final marks = List.filled(chunk.length, '?').join(',');
      for (final m in await _withDetails(
        await db.query('memories', where: 'id IN ($marks)', whereArgs: chunk),
      )) {
        out[m.id] = m;
      }
    }
    return [for (final id in ids) ?out[id]];
  }

  Future<List<Memory>> _withDetails(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return [];
    final ids = rows.map((r) => r['id'] as String).toList();
    final marks = List.filled(ids.length, '?').join(',');
    final tagRows = await db.query(
      'memory_tags',
      where: 'memory_id IN ($marks)',
      whereArgs: ids,
      orderBy: 'position',
    );
    final photoRows = await db.query(
      'photos',
      where: 'memory_id IN ($marks)',
      whereArgs: ids,
      orderBy: 'position',
    );
    final tagsBy = <Object?, List<String>>{};
    for (final t in tagRows) {
      tagsBy.putIfAbsent(t['memory_id'], () => []).add(t['tag'] as String);
    }
    final photosBy = <Object?, List<PhotoRef>>{};
    for (final p in photoRows) {
      photosBy.putIfAbsent(p['memory_id'], () => []).add(photoFromRow(p));
    }
    return [
      for (final r in rows)
        _memoryFromRow(r, tagsBy[r['id']] ?? [], photosBy[r['id']] ?? []),
    ];
  }

  /// Creates or updates a memory with its tags and photos.
  /// Returns the photo files (relative paths) that were removed.
  Future<(String, List<String>)> saveMemory(MemoryDraft d) {
    return db.transaction((txn) async {
      await _requireActiveItem(txn, d.itemId);
      final now = _now();
      final id = d.id ?? newId();
      final values = {
        'title': d.title.trim(),
        'body': d.body.trim(),
        'date': d.date.toIso(),
        'location': d.location.trim(),
        'updated_at': now,
      };
      if (d.id == null) {
        final maxPos =
            Sqflite.firstIntValue(
              await txn.rawQuery(
                'SELECT MAX(position) FROM memories WHERE item_id = ?',
                [d.itemId],
              ),
            ) ??
            -1;
        await txn.insert('memories', {
          ...values,
          'id': id,
          'item_id': d.itemId,
          'position': maxPos + 1,
          'created_at': now,
        });
      } else {
        final n = await txn.update(
          'memories',
          values,
          where: 'id = ? AND item_id = ?',
          whereArgs: [id, d.itemId],
        );
        if (n == 0) throw ItemNotFoundException();
      }

      await txn.delete('memory_tags', where: 'memory_id = ?', whereArgs: [id]);
      for (var i = 0; i < d.hashtags.length; i++) {
        await txn.insert('memory_tags', {
          'memory_id': id,
          'position': i,
          'tag': d.hashtags[i],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }

      final existing = await txn.query(
        'photos',
        where: 'memory_id = ?',
        whereArgs: [id],
      );
      final keep = d.photos.map((p) => p.id).toSet();
      final removed = existing.where((r) => !keep.contains(r['id'])).toList();
      for (final r in removed) {
        await txn.delete('photos', where: 'id = ?', whereArgs: [r['id']]);
      }
      final existingIds = existing.map((r) => r['id']).toSet();
      for (var i = 0; i < d.photos.length; i++) {
        final ph = d.photos[i];
        if (existingIds.contains(ph.id)) {
          await txn.update(
            'photos',
            {'position': i},
            where: 'id = ?',
            whereArgs: [ph.id],
          );
        } else {
          await txn.insert('photos', {
            'id': ph.id,
            'memory_id': id,
            'position': i,
            'file': ph.file,
            'thumb': ph.thumb,
            'width': ph.width,
            'height': ph.height,
            'created_at': ph.createdAt.toUtc().toIso8601String(),
          });
        }
      }
      await txn.update(
        'items',
        {'updated_at': now},
        where: 'id = ?',
        whereArgs: [d.itemId],
      );
      return (id, _filesOf(removed));
    });
  }

  /// Deletes a memory. Returns its photo files (relative paths).
  Future<List<String>> deleteMemory(String id) {
    return db.transaction((txn) async {
      final files = await txn.query(
        'photos',
        columns: ['file', 'thumb'],
        where: 'memory_id = ?',
        whereArgs: [id],
      );
      final n = await txn.delete(
        'memories',
        where:
            'id = ? AND item_id IN '
            '(SELECT id FROM items WHERE journey_id = $_active)',
        whereArgs: [id],
      );
      if (n == 0) throw ItemNotFoundException();
      return _filesOf(files);
    });
  }

  Future<void> _requireActiveItem(Transaction txn, String itemId) async {
    final rows = await txn.rawQuery(
      'SELECT 1 FROM items WHERE id = ? AND journey_id = $_active',
      [itemId],
    );
    if (rows.isEmpty) throw ItemNotFoundException();
  }

  // ------------------------------------------------------------- journeys

  Future<String> _activeJourneyId(DatabaseExecutor e) async {
    final rows = await e.rawQuery(
      "SELECT id FROM journeys WHERE status = 'active'",
    );
    if (rows.isEmpty) throw StateError('No active journey');
    return rows.first['id'] as String;
  }

  /// All journeys, oldest first.
  Future<List<Journey>> loadJourneys() async => (await db.query(
    'journeys',
    orderBy: 'number',
  )).map(_journeyFromRow).toList();

  Future<Journey> activeJourney() async => _journeyFromRow(
    (await db.query('journeys', where: "status = 'active'")).single,
  );

  /// Every journey with its counts, oldest first.
  Future<List<JourneySummary>> journeySummaries() async {
    final rows = await db.rawQuery('''
      SELECT j.*,
        (SELECT COUNT(*) FROM items i WHERE i.journey_id = j.id) AS n_items,
        (SELECT COUNT(*) FROM items i
           WHERE i.journey_id = j.id AND i.is_completed = 1) AS n_completed,
        (SELECT COUNT(*) FROM memories m JOIN items i ON i.id = m.item_id
           WHERE i.journey_id = j.id) AS n_memories,
        (SELECT COUNT(*) FROM photos p
           JOIN memories m ON m.id = p.memory_id
           JOIN items i ON i.id = m.item_id
           WHERE i.journey_id = j.id) AS n_photos
      FROM journeys j ORDER BY j.number''');
    return [
      for (final r in rows)
        JourneySummary(
          journey: _journeyFromRow(r),
          itemCount: r['n_items'] as int,
          completedCount: r['n_completed'] as int,
          memoryCount: r['n_memories'] as int,
          photoCount: r['n_photos'] as int,
        ),
    ];
  }

  /// Archives the active journey (which must have all 1,000 things
  /// completed) and starts the next one. Nothing is deleted: the old
  /// journey keeps every item, memory and photo, and becomes read-only.
  ///
  /// With [reuseList], the new journey starts with a copy of the old
  /// list's numbers, titles, descriptions and order — all not completed,
  /// with no memories. Otherwise it starts empty.
  Future<Journey> archiveAndStartNew({
    required CalendarDate? startedOn,
    required CalendarDate completedOn,
    required Profile? snapshot,
    required CalendarDate newStartedOn,
    required bool reuseList,
  }) {
    return db.transaction((txn) async {
      final oldId = await _activeJourneyId(txn);
      final completed =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT COUNT(*) FROM items '
              'WHERE journey_id = ? AND is_completed = 1',
              [oldId],
            ),
          ) ??
          0;
      if (completed < maxItems) throw JourneyNotCompleteException();

      final now = _now();
      await txn.rawUpdate(
        '''
        UPDATE journeys SET status = 'archived',
          started_on = COALESCE(started_on, ?), completed_on = ?,
          snapshot = ?, archived_at = ?
        WHERE id = ?''',
        [
          startedOn?.toIso(),
          completedOn.toIso(),
          snapshot == null ? null : jsonEncode(snapshot.toJson()),
          now,
          oldId,
        ],
      );
      final number =
          (Sqflite.firstIntValue(
                await txn.rawQuery('SELECT MAX(number) FROM journeys'),
              ) ??
              0) +
          1;
      final newRow = {
        'id': newId(),
        'number': number,
        'status': 'active',
        'started_on': newStartedOn.toIso(),
        'created_at': now,
      };
      await txn.insert('journeys', newRow);
      if (reuseList) {
        final old = await txn.query(
          'items',
          where: 'journey_id = ?',
          whereArgs: [oldId],
          orderBy: 'position, rowid',
        );
        final batch = txn.batch();
        for (final r in old) {
          batch.insert('items', {
            'id': newId(),
            'journey_id': newRow['id'],
            'number': r['number'],
            'position': r['position'],
            'title': r['title'],
            'description': r['description'],
            'is_completed': 0,
            'completed_on': null,
            'created_at': now,
            'updated_at': now,
          });
        }
        await batch.commit(noResult: true);
      }
      return _journeyFromRow(newRow);
    });
  }

  /// Changes when the active journey started.
  Future<void> setJourneyStart(CalendarDate? date) => db.rawUpdate(
    "UPDATE journeys SET started_on = ? WHERE status = 'active'",
    [date?.toIso()],
  );

  /// The completed items of [journeyId] in list order, each with the
  /// size of its memories: enough to lay out a Life Album without
  /// loading every memory at once.
  Future<List<AlbumEntry>> albumOutline(String journeyId) async {
    final items = (await db.query(
      'items',
      where: 'journey_id = ? AND is_completed = 1',
      whereArgs: [journeyId],
      orderBy: 'position, rowid',
    )).map(_itemFromRow).toList();
    final rows = await db.rawQuery(
      '''
      SELECT m.id, m.item_id, LENGTH(m.body) + LENGTH(m.title) AS len,
        (SELECT COUNT(*) FROM photos p WHERE p.memory_id = m.id) AS photos
      FROM memories m JOIN items i ON i.id = m.item_id
      WHERE i.journey_id = ? AND i.is_completed = 1
      ORDER BY m.position, m.rowid''',
      [journeyId],
    );
    final byItem = <String, List<AlbumMemoryMeta>>{};
    for (final r in rows) {
      byItem
          .putIfAbsent(r['item_id'] as String, () => [])
          .add(
            AlbumMemoryMeta(
              id: r['id'] as String,
              textLength: (r['len'] as int?) ?? 0,
              photoCount: r['photos'] as int,
            ),
          );
    }
    return [
      for (final i in items)
        AlbumEntry(item: i, memories: byItem[i.id] ?? const []),
    ];
  }

  // -------------------------------------------------------------- profile

  Future<Profile> loadProfile() async {
    final rows = await db.query('profile', where: 'id = 1');
    if (rows.isEmpty) return const Profile();
    final r = rows.first;
    return Profile(
      name: r['name'] as String,
      nickname: r['nickname'] as String,
      age: r['age'] as int?,
      startedOn: r['started_on'] == null
          ? null
          : CalendarDate.parse(r['started_on'] as String),
      bio: r['bio'] as String,
      photo: r['photo'] as String?,
    );
  }

  Future<void> saveProfile(Profile p) => db.insert('profile', {
    'id': 1,
    'name': p.name.trim(),
    'nickname': p.nickname.trim(),
    'age': p.age,
    'started_on': p.startedOn?.toIso(),
    'bio': p.bio.trim(),
    'photo': p.photo,
    'updated_at': _now(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  // ------------------------------------------------------------- settings

  Future<String?> getSetting(String key) async {
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) => db.insert('settings', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  // -------------------------------------------------------------- mapping

  static List<String> _filesOf(List<Map<String, Object?>> rows) => [
    for (final r in rows) ...[r['file'] as String, r['thumb'] as String],
  ];

  static Journey _journeyFromRow(Map<String, Object?> r) => Journey(
    id: r['id'] as String,
    number: r['number'] as int,
    status: r['status'] == 'archived'
        ? JourneyStatus.archived
        : JourneyStatus.active,
    startedOn: r['started_on'] == null
        ? null
        : CalendarDate.parse(r['started_on'] as String),
    completedOn: r['completed_on'] == null
        ? null
        : CalendarDate.parse(r['completed_on'] as String),
    snapshot: r['snapshot'] == null
        ? null
        : Profile.fromJson(jsonDecode(r['snapshot'] as String) as Map),
    createdAt: DateTime.parse(r['created_at'] as String),
    archivedAt: r['archived_at'] == null
        ? null
        : DateTime.parse(r['archived_at'] as String),
  );

  static BucketItem _itemFromRow(Map<String, Object?> r) => BucketItem(
    id: r['id'] as String,
    journeyId: r['journey_id'] as String,
    number: r['number'] as int,
    position: r['position'] as int,
    title: r['title'] as String,
    description: r['description'] as String,
    isCompleted: r['is_completed'] == 1,
    completedOn: r['completed_on'] == null
        ? null
        : CalendarDate.parse(r['completed_on'] as String),
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );

  static Memory _memoryFromRow(
    Map<String, Object?> r,
    List<String> tags,
    List<PhotoRef> photos,
  ) => Memory(
    id: r['id'] as String,
    itemId: r['item_id'] as String,
    position: r['position'] as int,
    title: r['title'] as String,
    body: r['body'] as String,
    date: CalendarDate.parse(r['date'] as String),
    location: r['location'] as String,
    hashtags: tags,
    photos: photos,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );

  static PhotoRef photoFromRow(Map<String, Object?> r) => PhotoRef(
    id: r['id'] as String,
    memoryId: r['memory_id'] as String,
    position: r['position'] as int,
    file: r['file'] as String,
    thumb: r['thumb'] as String,
    width: r['width'] as int?,
    height: r['height'] as int?,
    createdAt: DateTime.parse(r['created_at'] as String),
  );
}
