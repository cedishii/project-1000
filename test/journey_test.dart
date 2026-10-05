import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/data/progression.dart';
import 'package:project_1000/services/album/album_pdf.dart';
import 'package:project_1000/services/album/album_plan.dart';
import 'package:project_1000/services/backup/backup_format.dart';
import 'package:project_1000/services/backup/import_service.dart';
import 'package:project_1000/services/photo_storage.dart';
import 'package:project_1000/state/app_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';
import 'memories_test.dart' show fakePendingPhoto;

/// Adds [n] things to the current journey directly in the database (fast),
/// in reverse number order so list order ≠ number order, with the first
/// [completed] (by number) completed on scattered dates. Restarts the
/// store so it reloads.
Future<AppStore> fill(
  TestArchive archive,
  AppStore store,
  int n, {
  int completed = 0,
  String prefix = 'Thing',
}) async {
  final db = store.repository.db;
  final journey = store.journey.id;
  final now = DateTime.utc(2030).toIso8601String();
  final batch = db.batch();
  for (var i = 0; i < n; i++) {
    final day = DateTime(2030, 1, 1).add(Duration(days: (i * 37) % 900));
    batch.insert('items', {
      'id': ArchiveRepository.newId(),
      'journey_id': journey,
      'number': i + 1,
      'position': n - 1 - i,
      'title': '$prefix ${i + 1}',
      'description': i.isEven ? 'About ${i + 1}' : '',
      'is_completed': i < completed ? 1 : 0,
      'completed_on': i < completed
          ? CalendarDate.fromDateTime(day).toIso()
          : null,
      'created_at': now,
      'updated_at': now,
    });
  }
  await batch.commit(noResult: true);
  return archive.restart();
}

/// Everything about every journey, comparable as text.
Future<String> fullFingerprint(AppStore store) async {
  final out = StringBuffer();
  final pr = store.profile;
  out.writeln(
    'profile ${pr.name}|${pr.nickname}|${pr.age}|${pr.startedOn}|${pr.bio}|'
    '${pr.photo == null ? '-' : sha256.convert(File(store.location.resolve(pr.photo!)).readAsBytesSync())}',
  );
  for (final s in await store.journeySummaries()) {
    final j = s.journey;
    final snap = j.snapshot;
    out.writeln(
      'journey ${j.id}|${j.number}|${j.status}|${j.startedOn}|'
      '${j.completedOn}|${snap?.name}|${snap?.bio}|'
      '${snap?.photo == null ? '-' : sha256.convert(File(store.location.resolve(snap!.photo!)).readAsBytesSync())}|'
      '${s.itemCount}|${s.completedCount}|${s.memoryCount}|${s.photoCount}',
    );
    for (final i in await store.loadJourneyItems(j.id)) {
      out.writeln(
        '  ${[i.id, i.number, i.position, i.title, i.description, i.isCompleted, i.completedOn].join('|')}',
      );
      for (final m in await store.loadMemories(i.id)) {
        out.writeln(
          '    ${[m.id, m.title, m.body, m.date, m.location, m.hashtags.join(',')].join('|')}',
        );
        for (final ph in m.photos) {
          out.writeln(
            '      ${ph.id}|${sha256.convert(File(store.location.resolve(ph.file)).readAsBytesSync())}',
          );
        }
      }
    }
  }
  return out.toString();
}

void main() {
  late TestArchive archive;
  late AppStore store;

  setUp(() async {
    archive = await TestArchive.create();
    store = await archive.open();
  });
  tearDown(() => archive.dispose());

  group('EXP and levels', () {
    for (final (done, exp, level, pct) in [
      (0, 0, 0, 0.0), // Test 1
      (1, 1000, 0, 0.001), // Test 2
      (10, 10000, 1, 0.01), // Test 3
      (37, 37000, 3, 0.037),
      (100, 100000, 10, 0.1), // Test 4
      (250, 250000, 25, 0.25),
      (500, 500000, 50, 0.5), // Test 5
      (990, 990000, 99, 0.99), // Test 6
      (1000, 1000000, 100, 1.0), // Test 7
    ]) {
      test('$done completed → $exp EXP, Level $level', () {
        final p = Progression(done);
        expect(p.exp, exp);
        expect(p.level, level);
        expect(p.journeyFraction, closeTo(pct, 1e-9));
        expect(p.remaining, maxItems - done);
      });
    }

    test('progress within a level', () {
      final p = Progression(37);
      expect(p.expIntoLevel, 7000);
      expect(p.expToNextLevel, 3000);
      expect(Progression(370).level, 37);
      final max = Progression(1000);
      expect(max.isMaxLevel, isTrue);
      expect(max.expToNextLevel, 0);
      expect(max.isComplete, isTrue);
      expect(Progression(5000).level, maxLevel, reason: 'clamped');
      expect(Progression(-3).exp, 0, reason: 'clamped');
    });

    test('Tests 8 & 9: completing, un-completing and restarting always '
        'match the list, and can\'t farm EXP', () async {
      store = await fill(archive, store, 20, completed: 9);
      expect(store.progression.exp, 9000);
      expect(store.progression.level, 0);
      final next = store.items.firstWhere((i) => !i.isCompleted);
      await store.setCompleted(next.id, true);
      expect(store.progression.exp, 10000);
      expect(store.progression.level, 1);
      for (var k = 0; k < 5; k++) {
        await store.setCompleted(next.id, false);
        await store.setCompleted(next.id, true);
      }
      expect(store.progression.exp, 10000, reason: 'no farming');
      await store.setCompleted(next.id, false);
      expect(store.progression.exp, 9000);
      expect(store.progression.level, 0);
      expect(
        store.itemById(next.id)!.completedOn,
        isNotNull,
        reason: 'history kept',
      );
      store = await archive.restart();
      expect(store.progression.exp, 9000);
      expect(store.progression.level, 0);
    });
  });

  group('journeys', () {
    test('a fresh install has Journey 1, empty, and an empty profile', () {
      expect(store.journey.number, 1);
      expect(store.journey.isActive, isTrue);
      expect(store.items, isEmpty);
      expect(store.profile.isEmpty, isTrue);
      expect(store.startOf(store.journey), isNull);
    });

    test('a journey can\'t be archived before 1,000 / 1,000', () async {
      store = await fill(archive, store, 1000, completed: 999);
      final before = await fullFingerprint(store);
      await expectLater(
        store.startNewJourney(
          newStartedOn: CalendarDate(2031, 6, 15),
          reuseList: true,
        ),
        throwsA(isA<JourneyNotCompleteException>()),
      );
      expect(await fullFingerprint(store), before);
    });

    Future<void> completeJourney1() async {
      store = await fill(archive, store, 1000, completed: 1000);
      await store.saveProfile(
        Profile(
          name: 'Cedrick',
          nickname: 'Ced',
          age: 25,
          startedOn: CalendarDate(2026, 10, 6),
          bio: 'Then',
        ),
      );
      await store.setProfilePhoto(Uint8List.fromList([1, 2, 3, 4]));
      final first = store.items.last; // #001 (list is reversed)
      final photo = await fakePendingPhoto(store, 'japan');
      await store.saveMemory(
        MemoryDraft(
          itemId: first.id,
          title: 'First day in Tokyo',
          body: 'Ramen.',
          date: CalendarDate(2028, 3, 18),
          location: 'Tokyo',
          hashtags: ['japan'],
          photos: [photo],
        ),
      );
    }

    test('Tests 10, 14–18: complete, archive, start Journey 2 (reuse list), '
        'and Journey 1 stays intact and separate', () async {
      await completeJourney1();
      expect(store.progression.isComplete, isTrue);
      expect(store.progression.level, 100);
      final j1 = store.journey;
      final j1Items = store.items;
      final j1Before = await fullFingerprint(store);

      await store.startNewJourney(
        newStartedOn: CalendarDate(2031, 6, 15),
        reuseList: true,
      );
      // Test 14: Journey 2 starts at zero.
      expect(store.journey.number, 2);
      expect(store.journey.startedOn, CalendarDate(2031, 6, 15));
      expect(store.completedCount, 0);
      expect(store.progression.exp, 0);
      expect(store.progression.level, 0);
      // Test 16: same titles, numbers and order; nothing else.
      expect(store.items.length, 1000);
      expect(store.items.map((i) => (i.number, i.title, i.description)), [
        for (final i in j1Items) (i.number, i.title, i.description),
      ]);
      expect(store.items.every((i) => !i.isCompleted), isTrue);
      expect(store.items.every((i) => i.completedOn == null), isTrue);
      expect(
        store.items
            .map((i) => i.id)
            .toSet()
            .intersection(j1Items.map((i) => i.id).toSet()),
        isEmpty,
      );
      // Test 15: no memories leak into Journey 2.
      for (final i in store.items) {
        expect(store.memoryCountOf(i.id), 0);
      }
      final j2First = store.items.last;
      expect(await store.loadMemories(j2First.id), isEmpty);
      expect(await store.search('tokyo'), isEmpty);

      // Tests 17/18: Journey 1 is archived, whole and read-only.
      final summaries = await store.journeySummaries();
      expect(summaries.map((s) => s.journey.number), [1, 2]);
      final a1 = summaries.first;
      expect(a1.journey.id, j1.id);
      expect(a1.journey.isArchived, isTrue);
      expect(a1.journey.startedOn, CalendarDate(2026, 10, 6));
      expect(a1.journey.completedOn, isNotNull);
      expect(a1.journey.snapshot!.nickname, 'Ced');
      expect(a1.journey.snapshot!.bio, 'Then');
      expect(a1.completedCount, 1000);
      expect(a1.memoryCount, 1);
      expect(a1.photoCount, 1);
      expect(await store.searchJourney(j1.id, 'tokyo'), {j1Items.last.id});

      // The archived profile photo is its own copy: changing the current
      // one doesn't touch it.
      await store.saveProfile(const Profile(name: 'Cedrick', bio: 'Now'));
      await store.setProfilePhoto(Uint8List.fromList([9, 9]));
      final snapPhoto = a1.journey.snapshot!.photo!;
      expect(File(store.location.resolve(snapPhoto)).readAsBytesSync(), [
        1,
        2,
        3,
        4,
      ]);

      // Archived items, memories and photos can't be changed.
      final old = j1Items.last;
      final oldMemory = (await store.loadMemories(old.id)).single;
      for (final attempt in <Future<void> Function()>[
        () => store.setCompleted(old.id, false),
        () => store.updateItemText(old.id, 'x', ''),
        () => store.deleteItem(old.id),
        () => store.deleteMemory(oldMemory.id),
        () => store.saveMemory(
          MemoryDraft(
            itemId: old.id,
            title: 'x',
            body: '',
            date: CalendarDate(2032, 1, 1),
            location: '',
            hashtags: const [],
            photos: const [],
          ),
        ),
      ]) {
        await expectLater(attempt(), throwsA(isA<ItemNotFoundException>()));
      }

      // Journey 1's own record (items, memories, photos) is unchanged.
      store = await archive.restart();
      final after = await fullFingerprint(store);
      String journeyOne(String f) => f
          .split('\n')
          .skipWhile((l) => !l.startsWith('journey ${j1.id}'))
          .skip(1)
          .takeWhile((l) => l.startsWith(' '))
          .join('\n');
      expect(journeyOne(after), journeyOne(j1Before));
      expect(journeyOne(after), contains('First day in Tokyo'));
    });

    test('starting with a new list gives an empty Journey 2', () async {
      await completeJourney1();
      await store.startNewJourney(
        newStartedOn: CalendarDate(2031, 6, 15),
        reuseList: false,
      );
      expect(store.journey.number, 2);
      expect(store.items, isEmpty);
      final added = await store.addItem('New first thing', '');
      expect(added.number, 1, reason: 'numbers are per journey');
      store = await archive.restart();
      expect(store.journey.number, 2);
      expect(titlesOf(store), ['New first thing']);
    });

    test('the album follows the list order exactly (Test 11), with every '
        'memory field (Test 12)', () async {
      await completeJourney1();
      final outline = await store.albumOutline(store.journey.id);
      expect(outline.length, 1000);
      expect(
        outline.map((e) => e.item.id).toList(),
        store.items.map((i) => i.id).toList(),
        reason: 'list order, not number or completion date',
      );
      expect(outline.first.item.number, 1000);
      final pages = planAlbum(outline);
      expect(pages.first, isA<AlbumCoverPage>());
      expect(pages[1], isA<AlbumIntroPage>());
      expect(pages.last, isA<AlbumClosingPage>());
      final inPages = [
        for (final pg in pages)
          if (pg is AlbumItemPage)
            pg.item.id
          else if (pg is AlbumListPage)
            ...pg.items.map((i) => i.id),
      ];
      expect(inPages, store.items.map((i) => i.id).toList());

      final itemPage = pages.whereType<AlbumItemPage>().single;
      final m = (await store.loadMemoriesByIds([itemPage.memories.single.id]))
          .single;
      expect(m.title, 'First day in Tokyo');
      expect(m.body, 'Ramen.');
      expect(m.location, 'Tokyo');
      expect(m.date, CalendarDate(2028, 3, 18));
      expect(m.hashtags, ['japan']);
      expect(m.photos, hasLength(1));
    });

    test('only completed things appear in an album in progress', () async {
      store = await fill(archive, store, 30, completed: 12);
      final outline = await store.albumOutline(store.journey.id);
      expect(outline.length, 12);
      expect(outline.every((e) => e.item.isCompleted), isTrue);
      expect(planAlbum(const []).whereType<AlbumEmptyPage>(), hasLength(1));
    });

    test('long memory lists are split over pages, in order, and numbered', () {
      final item = BucketItem(
        id: 'i',
        journeyId: 'j',
        number: 205,
        position: 0,
        title: 'Travel to Japan',
        description: '',
        isCompleted: true,
        completedOn: CalendarDate(2028, 3, 18),
        createdAt: DateTime.utc(2028),
        updatedAt: DateTime.utc(2028),
      );
      final memories = [
        for (var i = 0; i < 9; i++)
          AlbumMemoryMeta(id: 'm$i', textLength: 900, photoCount: i % 3),
      ];
      final pages = planAlbum([AlbumEntry(item: item, memories: memories)])
          .whereType<AlbumItemPage>()
          .toList();
      expect(pages.length, greaterThan(1));
      expect(
        [for (final pg in pages) ...pg.memories.map((m) => m.id)],
        [for (final m in memories) m.id],
      );
      expect(pages.map((pg) => pg.firstMemory).first, 0);
      expect(pages.last.firstMemory + pages.last.memories.length, 9);
      expect(pages.skip(1).every((pg) => pg.isContinued), isTrue);
    });
  });

  test('Test 13: the Life Album PDF is written, with real and missing '
      'photos and text the fonts can\'t draw', () async {
    final dir = await Directory.systemTemp.createTemp('p1000_pdf_');
    addTearDown(() => dir.delete(recursive: true));
    final photo = File(p.join(dir.path, 'a.jpg'))
      ..writeAsBytesSync(
        img.encodeJpg(
          img.Image(width: 300, height: 200)..clear(img.ColorRgb8(200, 80, 40)),
        ),
      );
    final broken = File(p.join(dir.path, 'broken.jpg'))
      ..writeAsBytesSync([1, 2, 3]);
    Future<ShrunkImage?> prepare(String path) async {
      final decoded = img.decodeImage(File(path).readAsBytesSync());
      if (decoded == null) return null;
      return ShrunkImage(
        Uint8List.fromList(img.encodeJpg(decoded)),
        decoded.width,
        decoded.height,
      );
    }

    Uint8List asset(String name) => File(name).readAsBytesSync();
    final long = List.filled(400, 'A long memory that goes on.').join(' ');
    final files = await exportAlbumPdf(
      content: AlbumPdfContent(
        journeyNumber: 1,
        datesLine: 'October 6, 2026 → June 14, 2031',
        thingsLine: '1,000 THINGS COMPLETED',
        name: 'Cedrick Miguel P. Kaneko',
        nickname: 'Ced',
        profilePhoto: PdfPhoto(photo.path),
        facts: const [('Started', 'October 6, 2026')],
        bio: 'Bio with ünïcödé ✓ 日本 🙂',
        closingTitle: 'THAT WAS JOURNEY 1.',
        closingLines: const ['1,000 THINGS.'],
        closingFacts: const [('Started', 'October 6, 2026')],
        entries: [
          for (var i = 1; i <= 30; i++)
            PdfEntry(
              number: formatNumber(i),
              title: 'Thing $i',
              description: i.isEven ? 'Description' : '',
              completed: 'Completed March 18, 2028',
              memories: [
                if (i % 3 == 0)
                  PdfMemory(
                    title: 'Memory',
                    body: i == 3 ? long : 'Short text 日本',
                    date: 'March 18, 2028',
                    location: 'Tokyo',
                    hashtags: const ['japan'],
                    photos: [
                      PdfPhoto(photo.path),
                      PdfPhoto(broken.path),
                      const PdfPhoto(null),
                      PdfPhoto(photo.path),
                    ],
                  ),
              ],
            ),
        ],
      ),
      assets: AlbumPdfAssets(
        heading: asset('assets/fonts/pdf/Fredoka-SemiBold.ttf'),
        regular: asset('assets/fonts/pdf/NotoSans-Regular.ttf'),
        bold: asset('assets/fonts/pdf/NotoSans-Bold.ttf'),
        italic: asset('assets/fonts/pdf/NotoSans-Italic.ttf'),
        emblem: asset('assets/branding/emblem.png'),
        fallbacks: [
          asset('assets/fonts/pdf/NotoSansMath-Arrows.ttf'),
          asset('assets/fonts/pdf/NotoSansSymbols2-Subset.ttf'),
        ],
      ),
      outDir: Directory(p.join(dir.path, 'out')),
      workDir: Directory(p.join(dir.path, 'work')),
      prepare: prepare,
    );
    expect(files.map((f) => p.basename(f.path)), [
      'My-1000-Things-Journey-1.pdf',
    ]);
    final bytes = files.single.readAsBytesSync();
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(latin1.decode(bytes.sublist(bytes.length - 8)), contains('%%EOF'));
    expect(Directory(p.join(dir.path, 'work')).existsSync(), isFalse);
    // Keep a copy for manual inspection when asked to.
    final keep = Platform.environment['P1000_KEEP_PDF'];
    if (keep != null) files.single.copySync(keep);
  });

  group('Test 19: backup and restore', () {
    late Directory exports;
    setUp(() async {
      exports = await Directory.systemTemp.createTemp('p1000_exports_');
    });
    tearDown(() => exports.delete(recursive: true));

    test('every journey, the profile and its photos survive export → fresh '
        'install → import', () async {
      store = await fill(archive, store, 1000, completed: 1000);
      await store.saveProfile(
        Profile(
          name: 'Cedrick Miguel P. Kaneko',
          nickname: 'Ced',
          age: 25,
          startedOn: CalendarDate(2026, 10, 6),
          bio: 'Line one\nLine two',
        ),
      );
      await store.setProfilePhoto(Uint8List.fromList([7, 7, 7]));
      final first = store.items.last;
      await store.saveMemory(
        MemoryDraft(
          itemId: first.id,
          title: 'Kept',
          body: 'Journey 1 memory',
          date: CalendarDate(2028, 3, 18),
          location: 'Tokyo',
          hashtags: ['japan'],
          photos: [await fakePendingPhoto(store, 'j1')],
        ),
      );
      await store.startNewJourney(
        newStartedOn: CalendarDate(2031, 6, 15),
        reuseList: true,
      );
      await store.setCompleted(store.items[3].id, true);
      await store.saveMemory(
        MemoryDraft(
          itemId: store.items[3].id,
          title: 'Journey 2',
          body: '',
          date: CalendarDate(2032, 1, 2),
          location: '',
          hashtags: const [],
          photos: [await fakePendingPhoto(store, 'j2')],
        ),
      );
      final before = await fullFingerprint(store);

      final zip = (await store.exportBackup(exports, '1.1.0+2')).file;
      await archive.dispose();
      archive = await TestArchive.create();
      store = await archive.open();
      final preview = await prepareImport(zip.path, store.location);
      expect(preview.journeyCount, 2);
      expect(preview.itemCount, 2000);
      expect(preview.memoryCount, 2);
      expect(preview.photoCount, 2);
      expect(preview.missingPhotoCount, 0);
      expect(preview.itemIds.length, 1000);
      await store.importBackup(preview);
      expect(await fullFingerprint(store), before);
      store = await archive.restart();
      expect(await fullFingerprint(store), before);
      expect(store.journey.number, 2);
      expect(store.progression.exp, 1000);
    });

    test('a backup from version 1.0 (one list) imports as Journey 1', () async {
      store = await fill(archive, store, 12, completed: 5);
      final zip = (await store.exportBackup(exports, '1.0.0+1')).file;
      // Rewrite it the way 1.0 wrote backups.
      final entries = {
        for (final f in ZipDecoder().decodeBytes(zip.readAsBytesSync()))
          if (f.isFile) f.name: f.readBytes()!,
      };
      final data = jsonDecode(utf8.decode(entries[dataName]!)) as Map;
      final v1 = {
        'dataFormatVersion': 1,
        'settings': data['settings'],
        'items': ((data['journeys'] as List).single as Map)['items'],
      };
      final v1Bytes = utf8.encode(jsonEncode(v1));
      final manifest = jsonDecode(utf8.decode(entries[manifestName]!)) as Map;
      manifest['dataFormatVersion'] = 1;
      (manifest['data'] as Map)['sha256'] = sha256.convert(v1Bytes).toString();
      final out = Archive()
        ..addFile(ArchiveFile.bytes(dataName, v1Bytes))
        ..addFile(
          ArchiveFile.bytes(manifestName, utf8.encode(jsonEncode(manifest))),
        );
      final v1Zip = File(p.join(exports.path, 'v1.zip'))
        ..writeAsBytesSync(ZipEncoder().encodeBytes(out));
      final titles = titlesOf(store);

      await archive.dispose();
      archive = await TestArchive.create();
      store = await archive.open();
      final preview = await prepareImport(v1Zip.path, store.location);
      expect(preview.journeyCount, 1);
      expect(preview.itemCount, 12);
      await store.importBackup(preview);
      expect(store.journey.number, 1);
      expect(store.journey.isActive, isTrue);
      expect(titlesOf(store), titles);
      expect(store.progression.exp, 5000);
      expect(store.profile.isEmpty, isTrue);
    });

    test('a backup with two active journeys is rejected', () async {
      store = await fill(archive, store, 3);
      final zip = (await store.exportBackup(exports, '1.1.0+2')).file;
      final entries = {
        for (final f in ZipDecoder().decodeBytes(zip.readAsBytesSync()))
          if (f.isFile) f.name: f.readBytes()!,
      };
      final data = jsonDecode(utf8.decode(entries[dataName]!)) as Map;
      final j = (data['journeys'] as List).single as Map;
      (data['journeys'] as List).add({
        ...j,
        'id': 'other',
        'number': 2,
        'items': [],
      });
      final bytes = utf8.encode(jsonEncode(data));
      final manifest = jsonDecode(utf8.decode(entries[manifestName]!)) as Map;
      (manifest['data'] as Map)['sha256'] = sha256.convert(bytes).toString();
      final out = Archive()
        ..addFile(ArchiveFile.bytes(dataName, bytes))
        ..addFile(
          ArchiveFile.bytes(manifestName, utf8.encode(jsonEncode(manifest))),
        );
      final bad = File(p.join(exports.path, 'bad.zip'))
        ..writeAsBytesSync(ZipEncoder().encodeBytes(out));
      await expectLater(
        prepareImport(bad.path, store.location),
        throwsA(
          isA<ImportException>().having(
            (e) => e.problem,
            'problem',
            ImportProblem.invalidData,
          ),
        ),
      );
    });
  });

  test(
    'a phone with the 1.0 database upgrades without losing anything',
    () async {
      await store.close();
      // Recreate the archive exactly as version 1.0 left it.
      final path = store.location.dbPath;
      await File(path).delete();
      final db = await databaseFactoryFfi.openDatabase(path);
      await db.execute('''
      CREATE TABLE items (
        id TEXT PRIMARY KEY,
        number INTEGER NOT NULL UNIQUE CHECK (number BETWEEN 1 AND 1000),
        position INTEGER NOT NULL, title TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        is_completed INTEGER NOT NULL DEFAULT 0, completed_on TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''');
      await db.execute('CREATE INDEX items_position ON items(position)');
      await db.execute('''
      CREATE TABLE memories (
        id TEXT PRIMARY KEY,
        item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        position INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL DEFAULT '', date TEXT NOT NULL,
        location TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''');
      await db.execute('''
      CREATE TABLE memory_tags (
        memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        position INTEGER NOT NULL, tag TEXT NOT NULL,
        PRIMARY KEY (memory_id, tag))''');
      await db.execute('''
      CREATE TABLE photos (
        id TEXT PRIMARY KEY,
        memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        position INTEGER NOT NULL, file TEXT NOT NULL, thumb TEXT NOT NULL,
        width INTEGER, height INTEGER, created_at TEXT NOT NULL)''');
      await db.execute(
        'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      const t = '2026-10-06T00:00:00.000Z';
      for (var n = 1; n <= 127; n++) {
        await db.insert('items', {
          'id': 'item$n',
          'number': n,
          'position': 127 - n,
          'title': 'Old $n',
          'description': '',
          'is_completed': n % 25 == 0 ? 1 : 0,
          'completed_on': n % 25 == 0 ? '2026-01-0${n ~/ 25}' : null,
          'created_at': t,
          'updated_at': t,
        });
      }
      await db.insert('memories', {
        'id': 'mem',
        'item_id': 'item25',
        'position': 0,
        'title': 'Kept',
        'body': 'Body',
        'date': '2026-01-01',
        'created_at': t,
        'updated_at': t,
      });
      await db.insert('memory_tags', {
        'memory_id': 'mem',
        'position': 0,
        'tag': 'tag',
      });
      await db.insert('photos', {
        'id': 'ph',
        'memory_id': 'mem',
        'position': 0,
        'file': 'photos/ph.jpg',
        'thumb': 'thumbs/ph.jpg',
        'created_at': t,
      });
      await db.insert('settings', {'key': 'theme_mode', 'value': 'dark'});
      await db.setVersion(1);
      await db.close();

      store = await archive.open();
      expect(store.items.length, 127);
      expect(store.items.first.number, 127, reason: 'saved order kept');
      expect(store.items.map((i) => i.title).last, 'Old 1');
      expect(store.completedCount, 5);
      expect(store.progression.exp, 5000);
      expect(store.journey.number, 1);
      final m = (await store.loadMemories('item25')).single;
      expect(m.title, 'Kept');
      expect(m.hashtags, ['tag']);
      expect(m.photos.single.id, 'ph');
      expect(store.themeMode.name, 'dark');
      // Relationships are still enforced after the rebuild.
      await store.deleteItem('item25');
      expect(
        await store.repository.db.query('memories', where: "id = 'mem'"),
        isEmpty,
      );
      final added = await store.addItem('New', '');
      expect(added.number, 25, reason: 'lowest free number');
    },
  );
}
