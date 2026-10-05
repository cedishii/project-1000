import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

class ListFullException implements Exception {
  @override
  String toString() => 'The list already has $maxItems things.';
}

class ItemNotFoundException implements Exception {}

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

/// All reads and writes of the archive database. Every multi-step write
/// runs inside a transaction so it either fully happens or not at all.
class ArchiveRepository {
  ArchiveRepository(this.db);

  final Database db;
  static const _uuid = Uuid();

  static String newId() => _uuid.v4();
  static String _now() => DateTime.now().toUtc().toIso8601String();

  // ---------------------------------------------------------------- items

  /// All items in the user's order. This is the only ordering the app
  /// ever uses for the list.
  Future<List<BucketItem>> loadItems() async {
    final rows = await db.query('items', orderBy: 'position, rowid');
    return rows.map(_itemFromRow).toList();
  }

  Future<BucketItem?> getItem(String id) async {
    final rows = await db.query('items', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _itemFromRow(rows.first);
  }

  /// Adds a new item at the end of the list.
  ///
  /// It gets the lowest number not currently in use, so the list always
  /// stays within #1–#1000 and existing numbers never change.
  Future<BucketItem> addItem(String title, String description) {
    return db.transaction((txn) async {
      final numbers = (await txn.query(
        'items',
        columns: ['number'],
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
            await txn.rawQuery('SELECT MAX(position) FROM items'),
          ) ??
          -1;
      final now = _now();
      final row = {
        'id': newId(),
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
      where: 'id = ?',
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
      await txn.delete('items', where: 'id = ?', whereArgs: [id]);
      return _filesOf(files);
    });
  }

  /// Saves a new order. [orderedIds] must contain exactly the current
  /// items; otherwise nothing is changed.
  Future<void> saveOrder(List<String> orderedIds) {
    return db.transaction((txn) async {
      final current = (await txn.query('items', columns: ['id', 'position']));
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

  /// Number of memories per item id.
  Future<Map<String, int>> memoryCounts() async {
    final rows = await db.rawQuery(
      'SELECT item_id, COUNT(*) AS c FROM memories GROUP BY item_id',
    );
    return {for (final r in rows) r['item_id'] as String: r['c'] as int};
  }

  /// Ids of items matching [query] in their number, title, description,
  /// or any memory's title, text, location or hashtags.
  ///
  /// Returns a set: callers filter the list they already have, so the
  /// user's order is untouched.
  Future<Set<String>> searchItemIds(String query) async {
    final term = query.trim().replaceFirst(RegExp(r'^#'), '');
    if (term.isEmpty) return {};
    final like =
        '%${term.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%';
    final number = int.tryParse(term);
    final rows = await db.rawQuery(
      '''
      SELECT id FROM items
        WHERE number = ? OR title LIKE ? ESCAPE '\\'
           OR description LIKE ? ESCAPE '\\'
      UNION
      SELECT item_id FROM memories
        WHERE title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\'
           OR location LIKE ? ESCAPE '\\'
      UNION
      SELECT m.item_id FROM memory_tags t JOIN memories m ON m.id = t.memory_id
        WHERE t.tag LIKE ? ESCAPE '\\'
    ''',
      [number ?? -1, like, like, like, like, like, like],
    );
    return {for (final r in rows) r['id'] as String};
  }

  // ------------------------------------------------------------- memories

  Future<List<Memory>> loadMemories(String itemId) async {
    final rows = await db.query(
      'memories',
      where: 'item_id = ?',
      whereArgs: [itemId],
      orderBy: 'position, rowid',
    );
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
    return [
      for (final r in rows)
        _memoryFromRow(
          r,
          [
            for (final t in tagRows)
              if (t['memory_id'] == r['id']) t['tag'] as String,
          ],
          [
            for (final p in photoRows)
              if (p['memory_id'] == r['id']) photoFromRow(p),
          ],
        ),
    ];
  }

  /// Creates or updates a memory with its tags and photos.
  /// Returns the photo files (relative paths) that were removed.
  Future<(String, List<String>)> saveMemory(MemoryDraft d) {
    return db.transaction((txn) async {
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
      await txn.delete('memories', where: 'id = ?', whereArgs: [id]);
      return _filesOf(files);
    });
  }

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

  static BucketItem _itemFromRow(Map<String, Object?> r) => BucketItem(
    id: r['id'] as String,
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
