import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/state/app_store.dart';

import 'helpers.dart';

/// Makes a pending photo the way PhotoStorage.addPending does, without
/// needing the platform image decoder.
Future<PhotoRef> fakePendingPhoto(AppStore store, String content) async {
  final id = ArchiveRepository.newId();
  final dir = Directory(store.location.resolve('pending'));
  await dir.create(recursive: true);
  await File(store.location.resolve('pending/$id.jpg')).writeAsString(content);
  await File(store.location.resolve('pending/${id}_t.jpg'))
      .writeAsString('thumb $content');
  return PhotoRef(
    id: id,
    memoryId: '',
    position: 0,
    file: 'pending/$id.jpg',
    thumb: 'pending/${id}_t.jpg',
    width: 100,
    height: 80,
    createdAt: DateTime.utc(2030),
  );
}

void main() {
  late TestArchive archive;
  late AppStore store;

  setUp(() async {
    archive = await TestArchive.create();
    store = await archive.open();
    await store.addItem('Travel to Japan', '');
    await store.addItem('Watch the Northern Lights', '');
  });
  tearDown(() => archive.dispose());

  MemoryDraft draft(String itemId, String title,
          {List<PhotoRef> photos = const [], List<String> tags = const []}) =>
      MemoryDraft(
        itemId: itemId,
        title: title,
        body: 'Text of $title',
        date: CalendarDate(2032, 9, 18),
        location: 'Iceland',
        hashtags: tags,
        photos: photos,
      );

  test('multiple memories stay with their own item, in the order added',
      () async {
    final japan = store.items[0].id, lights = store.items[1].id;
    for (final t in ['Planning', 'Airport', 'First day', 'Final day',
        'Reflection']) {
      await store.saveMemory(draft(japan, t));
    }
    await store.saveMemory(draft(lights, 'Finally saw them',
        tags: parseHashtags('#travel #Iceland #dream')));

    store = await archive.restart();
    final j = await store.loadMemories(japan);
    final l = await store.loadMemories(lights);
    expect(j.map((m) => m.title),
        ['Planning', 'Airport', 'First day', 'Final day', 'Reflection']);
    expect(l.single.title, 'Finally saw them');
    expect(l.single.hashtags, ['travel', 'iceland', 'dream']);
    expect(l.single.date, CalendarDate(2032, 9, 18));
    expect(l.single.location, 'Iceland');
    expect(store.memoryCountOf(japan), 5);
    // Adding memories never moves items.
    expect(numbersOf(store), [1, 2]);
  });

  test('editing a memory keeps its place and identity', () async {
    final japan = store.items[0].id;
    await store.saveMemory(draft(japan, 'A'));
    await store.saveMemory(draft(japan, 'B'));
    final b = (await store.loadMemories(japan))[1];
    await store.saveMemory(MemoryDraft(
      id: b.id,
      itemId: japan,
      title: 'B edited',
      body: '',
      date: CalendarDate(2033, 1, 1),
      location: '',
      hashtags: ['x'],
      photos: const [],
    ));
    final after = await store.loadMemories(japan);
    expect(after.map((m) => m.title), ['A', 'B edited']);
    expect(after[1].id, b.id);
    expect(after[1].hashtags, ['x']);
  });

  test('photos are moved into the archive on save and belong to the right '
      'memory', () async {
    final japan = store.items[0].id, lights = store.items[1].id;
    final p1 = await fakePendingPhoto(store, 'one');
    final p2 = await fakePendingPhoto(store, 'two');
    final p3 = await fakePendingPhoto(store, 'three');
    await store.saveMemory(draft(japan, 'With two', photos: [p1, p2]));
    await store.saveMemory(draft(lights, 'With one', photos: [p3]));

    store = await archive.restart(); // also clears pending/
    final j = (await store.loadMemories(japan)).single;
    final l = (await store.loadMemories(lights)).single;
    expect(j.photos.map((p) => p.id), [p1.id, p2.id]);
    expect(l.photos.map((p) => p.id), [p3.id]);
    for (final ph in [...j.photos, ...l.photos]) {
      expect(ph.file, startsWith('photos/'));
      expect(ph.thumb, startsWith('thumbs/'));
      expect(File(store.location.resolve(ph.file)).existsSync(), isTrue);
      expect(File(store.location.resolve(ph.thumb)).existsSync(), isTrue);
    }
    expect(File(store.location.resolve(j.photos[1].file)).readAsStringSync(),
        'two');
  });

  test('removing a photo from a memory deletes its files', () async {
    final japan = store.items[0].id;
    final p1 = await fakePendingPhoto(store, 'one');
    final p2 = await fakePendingPhoto(store, 'two');
    await store.saveMemory(draft(japan, 'M', photos: [p1, p2]));
    final m = (await store.loadMemories(japan)).single;
    final removed = m.photos[0];
    await store.saveMemory(MemoryDraft(
      id: m.id,
      itemId: japan,
      title: m.title,
      body: m.body,
      date: m.date,
      location: m.location,
      hashtags: m.hashtags,
      photos: [m.photos[1]],
    ));
    expect((await store.loadMemories(japan)).single.photos.single.id, p2.id);
    expect(File(store.location.resolve(removed.file)).existsSync(), isFalse);
    expect(File(store.location.resolve(removed.thumb)).existsSync(), isFalse);
  });

  test('deleting an item removes its memories, tags, photo rows and files, '
      'and nothing else', () async {
    final japan = store.items[0].id, lights = store.items[1].id;
    final p1 = await fakePendingPhoto(store, 'one');
    final p2 = await fakePendingPhoto(store, 'two');
    await store.saveMemory(draft(japan, 'J', photos: [p1], tags: ['a']));
    await store.saveMemory(draft(lights, 'L', photos: [p2], tags: ['b']));
    final jPhoto = (await store.loadMemories(japan)).single.photos.single;
    final lPhoto = (await store.loadMemories(lights)).single.photos.single;

    await store.deleteItem(japan);

    expect(store.items.map((i) => i.id), [lights]);
    final db = store.repository.db;
    expect(await db.query('memories', where: 'item_id = ?', whereArgs: [japan]),
        isEmpty);
    expect(await db.query('photos', where: 'id = ?', whereArgs: [jPhoto.id]),
        isEmpty);
    expect(await db.query('memory_tags', where: 'tag = ?', whereArgs: ['a']),
        isEmpty);
    expect(File(store.location.resolve(jPhoto.file)).existsSync(), isFalse);
    // The other item is untouched.
    expect(File(store.location.resolve(lPhoto.file)).existsSync(), isTrue);
    expect((await store.loadMemories(lights)).single.hashtags, ['b']);
  });

  test('a failed save moves new photos back to pending (nothing half-saved)',
      () async {
    final p1 = await fakePendingPhoto(store, 'one');
    await expectLater(
        store.saveMemory(draft('no-such-item', 'X', photos: [p1])),
        throwsA(anything));
    expect(File(store.location.resolve(p1.file)).existsSync(), isTrue);
    expect(Directory(store.location.resolve('photos')).listSync(), isEmpty);
  });

  test('hashtag parsing', () {
    expect(parseHashtags('#Travel, japan  #dream #travel'),
        ['travel', 'japan', 'dream']);
    expect(parseHashtags('#日本 #café'), ['日本', 'café']);
    expect(parseHashtags('  # , '), isEmpty);
  });
}
