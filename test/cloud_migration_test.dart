import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/data/progression.dart';
import 'package:project_1000/services/cloud/cloud_migration.dart';
import 'package:project_1000/state/app_store.dart';

import 'helpers.dart';
import 'memories_test.dart' show fakePendingPhoto;

/// Behaves like the Supabase functions (import_archive, export_archive,
/// archive_files, storage), as tested in supabase/tests/run_tests.py.
class FakeCloud implements CloudArchiveApi {
  @override
  final String userId = '00000000-0000-4000-8000-00000000abcd';

  Map<String, Object?>? stored;
  final files = <String, List<int>>{};
  int uploadCalls = 0;
  int importCalls = 0;

  /// Throw on the n-th upload (a dropped connection).
  int? failOnUpload;

  /// Accept an upload but store nothing (a broken server).
  bool loseUploads = false;

  /// Change a record on the way in (a server bug).
  bool corruptImport = false;

  @override
  Future<Map<String, Object?>> importArchive(Map<String, Object?> data) async {
    importCalls++;
    // A repeated import keeps what is already stored.
    stored ??= jsonDecode(jsonEncode(data)) as Map<String, Object?>;
    if (corruptImport) {
      final j = (stored!['journeys'] as List).last as Map;
      ((j['items'] as List).first as Map)['title'] = 'changed';
    }
    return {'status': 'imported'};
  }

  @override
  Future<Map<String, Object?>> exportArchive() async {
    // Postgres formats timestamps differently; the meaning is the same.
    Object? pgStyle(Object? v) => switch (v) {
      Map m => {
        for (final e in m.entries)
          e.key: (e.key as String).endsWith('At') && e.value is String
              ? DateTime.parse(e.value as String)
                    .toUtc()
                    .toIso8601String()
                    .replaceFirst('Z', '+00:00')
              : pgStyle(e.value),
      },
      List l => [for (final e in l) pgStyle(e)],
      _ => v,
    };
    return (pgStyle(stored) as Map).cast();
  }

  @override
  Future<List<CloudFile>> archiveFiles() async {
    final paths = <String>{};
    final data = stored!;
    for (final j in (data['journeys'] as List).cast<Map>()) {
      final snap = j['snapshot'] as Map?;
      if (snap?['photo'] != null) paths.add(snap!['photo'] as String);
      for (final i in (j['items'] as List).cast<Map>()) {
        for (final m in (i['memories'] as List).cast<Map>()) {
          for (final ph in (m['photos'] as List).cast<Map>()) {
            paths
              ..add(ph['file'] as String)
              ..add(ph['thumb'] as String);
          }
        }
      }
    }
    final profilePhoto = (data['profile'] as Map?)?['photo'];
    if (profilePhoto != null) paths.add(profilePhoto as String);
    return [
      for (final path in paths.toList()..sort())
        CloudFile(
          path: path,
          present: files.containsKey(path),
          size: files[path]?.length,
        ),
    ];
  }

  @override
  Future<void> uploadFile(
    String path,
    File file, {
    required String contentType,
    required bool replace,
  }) async {
    uploadCalls++;
    if (failOnUpload == uploadCalls) {
      throw const SocketException('connection lost');
    }
    if (files.containsKey(path) && !replace) return;
    if (!loseUploads) files[path] = await file.readAsBytes();
  }
}

void main() {
  late TestArchive archive;
  late AppStore store;
  late FakeCloud cloud;

  CloudMigration migration() => CloudMigration(
    location: store.location,
    snapshot: store.archiveSnapshot,
    api: cloud,
  );

  setUp(() async {
    archive = await TestArchive.create();
    store = await archive.open();
    cloud = FakeCloud();
    final a = await store.addItem('Watch the Northern Lights', 'Someday');
    await store.addItem('Learn to sail', '');
    await store.setCompleted(a.id, true, on: CalendarDate(2030, 9, 18));
    await store.saveMemory(
      MemoryDraft(
        itemId: a.id,
        title: 'Finally',
        body: 'Green ribbons.',
        date: CalendarDate(2030, 9, 18),
        location: 'Iceland',
        hashtags: parseHashtags('#travel #夢'),
        photos: [
          await fakePendingPhoto(store, 'one'),
          await fakePendingPhoto(store, 'two'),
        ],
      ),
    );
    await store.saveProfile(const Profile(name: 'Me', bio: 'hello'));
  });
  tearDown(() => archive.dispose());

  test('copies records and photos and verifies them', () async {
    final before = jsonEncode(await store.archiveSnapshot());
    final report = await migration().run();

    expect(report.verified, isTrue, reason: '${report.differences}');
    expect(report.counts, {
      'journeys': 1,
      'items': 2,
      'memories': 1,
      'photos': 2,
    });
    expect(report.uploaded, 4); // 2 photos + 2 thumbnails
    expect(cloud.files.length, 4);
    expect(report.differences, isEmpty);
    // The phone's archive is untouched and the progress is the same.
    expect(jsonEncode(await store.archiveSnapshot()), before);
    expect(store.progression.exp, expPerThing);

    final state = await CloudMigration.lastState(store.location);
    expect(state!['status'], 'verified');
    expect(state['userId'], cloud.userId);
  });

  test('an interrupted run finishes on retry without duplicates', () async {
    cloud.failOnUpload = 3;
    await expectLater(migration().run(), throwsA(isA<SocketException>()));
    expect(
      (await CloudMigration.lastState(store.location))!['status'],
      'in_progress',
    );
    expect(cloud.files.length, 2);

    cloud.failOnUpload = null;
    final report = await migration().run();
    expect(report.verified, isTrue);
    expect(report.alreadyInCloud, 2);
    expect(report.uploaded, 2);
    expect(cloud.files.length, 4);

    // Running again changes nothing and uploads nothing.
    final calls = cloud.uploadCalls;
    final again = await migration().run();
    expect(again.verified, isTrue);
    expect(cloud.uploadCalls, calls);
  });

  test('is not verified when uploads silently fail', () async {
    cloud.loseUploads = true;
    final report = await migration().run();
    expect(report.verified, isFalse);
    expect(report.missingInCloud, hasLength(4));
    expect(
      (await CloudMigration.lastState(store.location))!['status'],
      'needs_attention',
    );
  });

  test('is not verified when the cloud copy differs', () async {
    cloud.corruptImport = true;
    final report = await migration().run();
    expect(report.verified, isFalse);
    expect(report.differences.single, contains('title differs'));
  });

  test('a damaged file in the cloud is replaced', () async {
    await migration().run();
    final path = cloud.files.keys.first;
    cloud.files[path] = [1]; // a truncated upload
    final report = await migration().run();
    expect(report.uploaded, 1);
    expect(report.verified, isTrue);
  });

  test('photos already missing on the phone are reported, not fatal', () async {
    final memory = (await store.loadMemories(store.items.first.id)).single;
    await File(store.location.resolve(memory.photos.first.file)).delete();
    final report = await migration().run();
    expect(report.missingOnPhone, [memory.photos.first.file]);
    expect(report.verified, isTrue);
  });

  test('timestamps are compared as instants', () {
    final a = {
      'items': [
        {'id': 'x', 'createdAt': '2026-10-05T16:03:54.113790Z', 'title': 't'},
      ],
    };
    final b = {
      'items': [
        {
          'id': 'x',
          'createdAt': '2026-10-05T16:03:54.11379+00:00',
          'title': 't',
        },
      ],
    };
    expect(compareArchives(a, b), isEmpty);
    (b['items']!.first)['title'] = 'u';
    expect(compareArchives(a, b), ['archive.items[x].title differs']);
    expect(compareArchives(a, {'items': []}), [
      'archive.items[x]: missing in the cloud',
    ]);
  });

  test('the phone writes the same data.json shape the server reads '
      '(supabase/tests/fixtures/archive_v2.json)', () async {
    final fixture = jsonDecode(
      await File('supabase/tests/fixtures/archive_v2.json').readAsString(),
    ) as Map<String, Object?>;
    final local = await store.archiveSnapshot();

    Set<String> keys(Object? m) => (m as Map).keys.cast<String>().toSet();
    Map first(Object? list) => (list as List).first as Map;
    final fj = first(fixture['journeys']), lj = first(local['journeys']);
    final fi = first(fj['items']), li = first(lj['items']);
    final fm = first(fi['memories']), lm = first(li['memories']);

    expect(keys(local), keys(fixture));
    expect(keys(local['profile']), keys(fixture['profile']));
    expect(keys(lj), keys(fj));
    expect(keys(li), keys(fi));
    expect(keys(lm), keys(fm));
    expect(keys(first(lm['photos'])), keys(first(fm['photos'])));
    expect(keys(const Profile().toJson()), keys(fj['snapshot']));
    expect(ArchiveRepository.newId(), isNotEmpty);
  });

  test('server progression constants match the app', () async {
    final sql = await File('supabase/migrations/20261012000300_archive_api.sql')
        .readAsString();
    expect(expPerThing, 1000);
    expect(expPerLevel, 10000);
    expect(maxLevel, 100);
    expect(sql, contains('n * 1000 as exp'));
    expect(sql, contains('least(n * 1000 / 10000, 100) as level'));
  });
}
