import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/services/backup/backup_format.dart';
import 'package:project_1000/services/backup/import_service.dart';
import 'package:project_1000/state/app_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers.dart';
import 'memories_test.dart' show fakePendingPhoto;

/// Everything the user would care about, in a comparable form.
Future<String> fingerprint(AppStore store) async {
  final out = StringBuffer();
  for (final i in store.items) {
    out.writeln(
      [
        i.id,
        i.number,
        i.position,
        i.title,
        i.description,
        i.isCompleted,
        i.completedOn,
        i.createdAt.toIso8601String(),
        i.updatedAt.toIso8601String(),
      ].join('|'),
    );
    for (final m in await store.loadMemories(i.id)) {
      out.writeln(
        '  ${[m.id, m.position, m.title, m.body, m.date, m.location, m.hashtags.join(','), m.createdAt.toIso8601String()].join('|')}',
      );
      for (final ph in m.photos) {
        final bytes = File(store.location.resolve(ph.file)).readAsBytesSync();
        out.writeln(
          '    ${[ph.id, ph.position, ph.file, ph.thumb, ph.width, ph.height, sha256.convert(bytes)].join('|')}',
        );
      }
    }
  }
  out.writeln('theme=${store.themeMode}');
  return out.toString();
}

void main() {
  late TestArchive device;
  late AppStore store;
  late Directory exports;

  setUp(() async {
    device = await TestArchive.create();
    store = await device.open();
    exports = await Directory.systemTemp.createTemp('p1000_exports_');
  });
  tearDown(() async {
    await device.dispose();
    await exports.delete(recursive: true);
  });

  /// Phase 7 test data: reordered, non-consecutive completions,
  /// descriptions, several memories with tags, dates, locations, photos.
  Future<void> buildRichArchive() async {
    for (var n = 1; n <= 8; n++) {
      await store.addItem('Thing $n', n.isEven ? 'Description of $n' : '');
    }
    final ids = store.items.map((i) => i.id).toList();
    await store.saveOrder([
      ids[5],
      ids[0],
      ids[7],
      ids[2],
      ids[1],
      ids[3],
      ids[6],
      ids[4],
    ]);
    await store.setCompleted(ids[0], true, on: CalendarDate(2031, 3, 4));
    await store.setCompleted(ids[3], true, on: CalendarDate(2032, 9, 18));
    await store.setCompleted(ids[6], true);
    await store.setCompleted(ids[6], false); // keeps its old date
    for (final (idx, n) in [(0, 3), (3, 2), (5, 1)]) {
      for (var k = 0; k < n; k++) {
        await store.saveMemory(
          MemoryDraft(
            itemId: ids[idx],
            title: 'Memory $k of $idx',
            body: 'Text $k — ünïcödé ✓ 日本',
            date: CalendarDate(2030 + k, 1 + k, 10 + k),
            location: k.isEven ? 'Reykjavík, Iceland' : '',
            hashtags: parseHashtags('#travel #dream$k'),
            photos: [
              for (var f = 0; f < k + 1; f++)
                await fakePendingPhoto(store, 'photo $idx-$k-$f'),
            ],
          ),
        );
      }
    }
    await store.setThemeMode(ThemeMode.dark);
  }

  Future<File> export() async =>
      (await store.exportBackup(exports, '1.0.0+1')).file;

  test(
    'Phase 7: export → reset → import restores everything identically',
    () async {
      await buildRichArchive();
      final before = await fingerprint(store);
      final zip = await export();
      expect(p.basename(zip.path), startsWith('1000-things-backup-'));

      // Reset: wipe this device's data completely.
      await device.dispose();
      device = await TestArchive.create();
      store = await device.open();
      expect(store.items, isEmpty);

      final preview = await prepareImport(zip.path, store.location);
      expect(preview.itemCount, 8);
      expect(preview.memoryCount, 6);
      expect(preview.photoCount, 10);
      expect(preview.missingPhotoCount, 0);
      await store.importBackup(preview);

      expect(await fingerprint(store), before);
      store = await device.restart();
      expect(await fingerprint(store), before);
    },
  );

  test('import replaces existing data only after success', () async {
    await buildRichArchive();
    final backup = await fingerprint(store);
    final zip = await export();

    // Change the current data, then import the older backup over it.
    await store.addItem('Added after export', '');
    await store.deleteItem(store.items.first.id);
    final preview = await prepareImport(zip.path, store.location);
    await store.importBackup(preview);
    expect(await fingerprint(store), backup);
    expect(device.root.listSync().map((e) => p.basename(e.path)).toSet(), {
      'archive',
    }, reason: 'no temporary folders left behind');
  });

  test('cancelling after preview changes nothing', () async {
    await buildRichArchive();
    final zip = await export();
    await store.addItem('Still here', '');
    final before = await fingerprint(store);
    await prepareImport(zip.path, store.location);
    await cancelImport(store.location);
    expect(await fingerprint(store), before);
    expect(store.location.incoming.existsSync(), isFalse);
  });

  group('Phase 8: bad backups never touch the current list', () {
    late String current;
    late File good;

    setUp(() async {
      await buildRichArchive();
      good = await export();
      await store.addItem('Current-only item', '');
      current = await fingerprint(store);
    });

    Future<void> expectRejected(File zip, ImportProblem problem) async {
      await expectLater(
        prepareImport(zip.path, store.location),
        throwsA(
          isA<ImportException>().having((e) => e.problem, 'problem', problem),
        ),
      );
      expect(store.location.incoming.existsSync(), isFalse);
      store = await device.restart();
      expect(await fingerprint(store), current);
    }

    /// Rewrites the good backup with [edit] applied to its entries.
    Future<File> tampered(
      void Function(Map<String, List<int>> files) edit,
    ) async {
      final archive = ZipDecoder().decodeBytes(good.readAsBytesSync());
      final files = {
        for (final f in archive)
          if (f.isFile) f.name: f.readBytes()!.toList(),
      };
      edit(files);
      final out = Archive();
      files.forEach((k, v) => out.addFile(ArchiveFile.bytes(k, v)));
      final f = File(p.join(exports.path, 'tampered.zip'));
      f.writeAsBytesSync(ZipEncoder().encodeBytes(out));
      return f;
    }

    Map<String, Object?> json(List<int> b) =>
        (jsonDecode(utf8.decode(b)) as Map).cast<String, Object?>();
    List<int> bytes(Object o) => utf8.encode(jsonEncode(o));
    Object? itemsOf(Map d) => ((d['journeys'] as List).first as Map)['items'];

    /// Edits data.json and keeps the manifest checksum consistent, so the
    /// content validation itself is tested.
    Future<File> withData(void Function(Map<String, Object?> data) edit) =>
        tampered((files) {
          final data = json(files[dataName]!);
          edit(data);
          files[dataName] = bytes(data);
          final manifest = json(files[manifestName]!);
          (manifest['data'] as Map)['sha256'] = sha256
              .convert(files[dataName]!)
              .toString();
          files[manifestName] = bytes(manifest);
        });

    test('random bytes / not a zip', () async {
      final f = File(p.join(exports.path, 'junk.zip'))
        ..writeAsBytesSync(List.generate(5000, (i) => (i * 7919) % 256));
      await expectRejected(f, ImportProblem.notABackup);
    });

    test('truncated download', () async {
      final b = good.readAsBytesSync();
      final f = File(p.join(exports.path, 'cut.zip'))
        ..writeAsBytesSync(b.sublist(0, b.length ~/ 2));
      await expectRejected(f, ImportProblem.notABackup);
    });

    test('a zip that is not a Project: 1000 backup', () async {
      await expectRejected(
        await tampered((f) => f.remove(manifestName)),
        ImportProblem.notABackup,
      );
    });

    test('invalid JSON in data.json', () async {
      await expectRejected(
        await tampered((f) => f[dataName] = utf8.encode('{"items": [')),
        ImportProblem.corrupted,
      );
    });

    test('data.json altered (checksum mismatch)', () async {
      await expectRejected(
        await tampered((f) {
          final d = json(f[dataName]!);
          ((itemsOf(d) as List).first as Map)['title'] = 'Changed';
          f[dataName] = bytes(d);
        }),
        ImportProblem.corrupted,
      );
    });

    test('backup from a newer, unsupported version', () async {
      await expectRejected(
        await tampered((f) {
          final m = json(f[manifestName]!);
          m['dataFormatVersion'] = 99;
          f[manifestName] = bytes(m);
        }),
        ImportProblem.newerVersion,
      );
    });

    test('duplicate item numbers', () async {
      await expectRejected(
        await withData((d) {
          final items = (itemsOf(d) as List).cast<Map>();
          items[1]['number'] = items[0]['number'];
        }),
        ImportProblem.invalidData,
      );
    });

    test('duplicate IDs', () async {
      await expectRejected(
        await withData((d) {
          final items = (itemsOf(d) as List).cast<Map>();
          items[1]['id'] = items[0]['id'];
        }),
        ImportProblem.invalidData,
      );
    });

    test('more than 1000 items', () async {
      await expectRejected(
        await withData((d) {
          final items = (itemsOf(d) as List).cast<Map>();
          ((d['journeys'] as List).first as Map)['items'] = [
            for (var n = 1; n <= 1001; n++)
              {...items[0], 'id': 'id$n', 'number': n, 'memories': []},
          ];
        }),
        ImportProblem.invalidData,
      );
    });

    test('photo path trying to escape the archive folder', () async {
      await expectRejected(
        await withData((d) {
          final m = ((itemsOf(d) as List).first as Map)['memories'] as List;
          ((m.first as Map)['photos'] as List).cast<Map>().first['file'] =
              '../../evil.jpg';
        }),
        ImportProblem.invalidData,
      );
    });

    test('invalid date', () async {
      await expectRejected(
        await withData((d) {
          ((itemsOf(d) as List).first as Map)['completedOn'] = '2031-02-30';
        }),
        ImportProblem.invalidData,
      );
    });
  });

  test('Phase 8: missing or damaged photos are reported, and the rest can '
      'still be imported', () async {
    await buildRichArchive();
    final zip = await export();
    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    final out = Archive();
    var dropped = 0, damaged = 0;
    for (final f in archive) {
      if (f.name.startsWith('photos/') && dropped < 2) {
        dropped++; // full photo removed; thumbnail remains → salvaged
        continue;
      }
      if (f.name.startsWith('thumbs/') && damaged == 0) {
        damaged++;
        out.addFile(ArchiveFile.bytes(f.name, [1, 2, 3])); // checksum fails
        continue;
      }
      out.addFile(ArchiveFile.bytes(f.name, f.readBytes()!));
    }
    final broken = File(p.join(exports.path, 'broken.zip'))
      ..writeAsBytesSync(ZipEncoder().encodeBytes(out));

    final preview = await prepareImport(broken.path, store.location);
    expect(preview.missingPhotoCount, 2);
    await store.importBackup(preview);
    expect(store.items.length, 8);
    // Every remaining photo reference points at a real file.
    for (final i in store.items) {
      for (final m in await store.loadMemories(i.id)) {
        for (final ph in m.photos) {
          expect(File(store.location.resolve(ph.file)).existsSync(), isTrue);
          expect(File(store.location.resolve(ph.thumb)).existsSync(), isTrue);
        }
      }
    }
  });

  test(
    'Phase 8: an import interrupted mid-swap is rolled back on next launch',
    () async {
      await buildRichArchive();
      final before = await fingerprint(store);
      final zip = await export();
      final preview = await prepareImport(zip.path, store.location);
      await buildIncomingArchive(
        preview,
        store.location,
        factory: databaseFactoryFfi,
      );
      await store.close();

      // Simulate the app dying right after the first rename of the swap.
      final loc = store.location;
      await loc.swapMarker.writeAsString('{}');
      await loc.live.rename(loc.previous.path);

      store = await device.open();
      expect(store.recoveredFromInterruptedImport, isTrue);
      expect(await fingerprint(store), before);
      expect(loc.previous.existsSync(), isFalse);
      expect(loc.incoming.existsSync(), isFalse);
      expect(loc.swapMarker.existsSync(), isFalse);
    },
  );

  test('Phase 8: a failing swap reopens the old archive unchanged', () async {
    await buildRichArchive();
    final before = await fingerprint(store);
    await expectLater(
      store.replaceArchive(
        () async => throw const FileSystemException(
          'No space left on device',
          '',
          OSError('ENOSPC', 28),
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await fingerprint(store), before);
  });

  test('export reports photos that are missing on this device', () async {
    await buildRichArchive();
    final m = (await store.loadMemories(store.items[1].id)).first;
    File(store.location.resolve(m.photos.first.file)).deleteSync();
    final result = await store.exportBackup(exports, '1.0.0+1');
    expect(result.missingFiles, [m.photos.first.file]);
    expect(result.items, 8);
  });

  test(
    'export and import report progress, even when the progress '
    'callback references things that cannot leave the main isolate',
    () async {
      await buildRichArchive();
      // A ReceivePort can't be sent to another isolate; the UI's callback
      // similarly references widgets. This used to make export fail.
      final unsendable = ReceivePort();
      final seen = <double>[];
      void onProgress(double v) {
        unsendable.hashCode;
        seen.add(v);
      }

      final result = await store.exportBackup(
        exports,
        '1.0.0+1',
        onProgress: onProgress,
      );
      final preview = await prepareImport(
        result.file.path,
        store.location,
        onProgress: onProgress,
      );
      await cancelImport(store.location);
      unsendable.close();
      expect(preview.itemCount, 8);
      expect(seen, isNotEmpty);
      expect(seen.every((v) => v >= 0 && v <= 1), isTrue);
    },
  );

  test('an empty list exports and imports cleanly', () async {
    final zip = await export();
    final preview = await prepareImport(zip.path, store.location);
    expect(preview.itemCount, 0);
    await store.importBackup(preview);
    expect(store.items, isEmpty);
  });
}
