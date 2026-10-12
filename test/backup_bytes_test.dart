// Backups made in memory (the website) and backups made on a phone are
// the same format: each opens with the other's reader.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/services/backup/backup_bytes.dart';
import 'package:project_1000/services/backup/backup_format.dart';
import 'package:project_1000/services/backup/import_service.dart';
import 'package:project_1000/services/cloud/cloud_migration.dart'
    show compareArchives;
import 'package:project_1000/state/app_store.dart';

import 'backup_test.dart' show fingerprint;
import 'helpers.dart';
import 'memories_test.dart' show fakePendingPhoto;

void main() {
  late TestArchive device;
  late AppStore store;
  late Directory exports;

  setUp(() async {
    device = await TestArchive.create();
    store = await device.open();
    exports = await Directory.systemTemp.createTemp('p1000_bytes_');
  });
  tearDown(() async {
    await device.dispose();
    await exports.delete(recursive: true);
  });

  Future<void> build() async {
    for (var n = 1; n <= 4; n++) {
      await store.addItem('Thing $n', n.isEven ? 'About $n' : '');
    }
    final ids = store.items.map((i) => i.id).toList();
    await store.saveOrder([ids[2], ids[0], ids[3], ids[1]]);
    await store.setCompleted(ids[0], true, on: CalendarDate(2031, 3, 4));
    await store.saveMemory(
      MemoryDraft(
        itemId: ids[0],
        title: 'A memory',
        body: 'ünïcödé ✓ 日本',
        date: CalendarDate(2031, 3, 4),
        location: 'Reykjavík',
        hashtags: parseHashtags('#travel #dream'),
        photos: [
          await fakePendingPhoto(store, 'one'),
          await fakePendingPhoto(store, 'two'),
        ],
      ),
    );
  }

  test('a phone backup opens in memory with every record and file', () async {
    await build();
    final zip = (await store.exportBackup(exports, '1.4.0+5')).file;
    final contents = readBackupBytes(await zip.readAsBytes());
    expect(
      compareArchives(contents.data, await store.archiveSnapshot()),
      isEmpty,
    );
    expect(contents.items.length, 4);
    expect(contents.photos.length, 2);
    expect(contents.missingPhotos, 0);
    expect(contents.files.keys.toSet(), mediaPathsOf(contents.data).toSet());
    for (final MapEntry(:key, :value) in contents.files.entries) {
      expect(value, await File(store.location.resolve(key)).readAsBytes());
    }
  });

  test('a backup made in memory imports on a phone identically', () async {
    await build();
    final before = await fingerprint(store);
    final data = await store.archiveSnapshot();
    final files = {
      for (final path in mediaPathsOf(data))
        path: await File(store.location.resolve(path)).readAsBytes(),
    };
    final zip = encodeBackupBytes(
      data: data,
      files: files,
      appVersion: 'web',
      exportedAt: DateTime.utc(2026, 10, 13),
    );
    final file = File('${exports.path}/web.zip')..writeAsBytesSync(zip);

    await device.dispose();
    device = await TestArchive.create();
    store = await device.open();
    final preview = await prepareImport(file.path, store.location);
    expect(preview.missingPhotoCount, 0);
    await store.importBackup(preview);
    expect(await fingerprint(store), before);
  });

  test('damaged, foreign and newer files are refused with a reason', () {
    Matcher problem(ImportProblem p) =>
        isA<ImportException>().having((e) => e.problem, 'problem', p);
    expect(
      () => readBackupBytes(Uint8List.fromList([1, 2, 3])),
      throwsA(problem(ImportProblem.notABackup)),
    );
    final notOurs = ZipEncoder().encodeBytes(
      Archive()..add(ArchiveFile.bytes('hello.txt', [104, 105])),
    );
    expect(
      () => readBackupBytes(notOurs),
      throwsA(problem(ImportProblem.notABackup)),
    );
    final data = {
      'dataFormatVersion': 2,
      'settings': <String, Object?>{},
      'profile': null,
      'journeys': [
        {
          'id': 'j1',
          'number': 1,
          'status': 'active',
          'startedOn': null,
          'completedOn': null,
          'snapshot': null,
          'createdAt': '2026-01-01T00:00:00Z',
          'archivedAt': null,
          'items': <Object?>[],
        },
      ],
    };
    final good = encodeBackupBytes(
      data: data,
      files: const {},
      appVersion: 'x',
      exportedAt: DateTime.utc(2026),
    );
    expect(readBackupBytes(good).items, isEmpty);

    // A changed data.json fails its checksum.
    final archive = ZipDecoder().decodeBytes(good);
    final tampered = Archive();
    for (final f in archive) {
      tampered.add(
        f.name == dataName
            ? ArchiveFile.bytes(dataName, [...f.readBytes()!, 32])
            : ArchiveFile.bytes(f.name, f.readBytes()!),
      );
    }
    expect(
      () => readBackupBytes(ZipEncoder().encodeBytes(tampered)),
      throwsA(problem(ImportProblem.corrupted)),
    );
  });
}
