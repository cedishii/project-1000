// Backups, merging and phone↔website sync against a real Supabase
// project, with throwaway member accounts A and B (fresh, empty). Skipped
// unless given: P1000_URL, P1000_KEY, P1000_{A,B}_EMAIL, P1000_{A,B}_PASSWORD
// (never real accounts: the test changes their data).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/services/backup/backup_bytes.dart';
import 'package:project_1000/services/backup/import_service.dart';
import 'package:project_1000/services/cloud/cloud_backup.dart';
import 'package:project_1000/services/cloud/cloud_migration.dart'
    show compareArchives;
import 'package:project_1000/services/cloud/live_updates.dart';
import 'package:project_1000/services/cloud/synced_archive.dart';
import 'package:project_1000/state/app_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backup_test.dart' show fingerprint;
import 'helpers.dart';
import 'memories_test.dart' show fakePendingPhoto;

final env = Platform.environment;
final configured = [
  'P1000_URL',
  'P1000_KEY',
  for (final x in ['A', 'B']) ...['P1000_${x}_EMAIL', 'P1000_${x}_PASSWORD'],
].every((k) => (env[k] ?? '').isNotEmpty);

Future<SupabaseClient> signIn(String who) async {
  final client = SupabaseClient(
    env['P1000_URL']!,
    env['P1000_KEY']!,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await client.auth.signInWithPassword(
    email: env['P1000_${who}_EMAIL']!,
    password: env['P1000_${who}_PASSWORD']!,
  );
  return client;
}

/// A phone's own list with memories, hashtags, photos and completions.
Future<void> buildPhone(AppStore store, String prefix) async {
  for (var n = 1; n <= 4; n++) {
    await store.addItem('$prefix $n', n.isEven ? 'About $n' : '');
  }
  final ids = store.items.map((i) => i.id).toList();
  await store.saveOrder([ids[2], ids[0], ids[3], ids[1]]);
  await store.setCompleted(ids[0], true, on: CalendarDate(2031, 3, 4));
  await store.setCompleted(ids[3], true, on: CalendarDate(2032, 5, 6));
  await store.saveMemory(
    MemoryDraft(
      itemId: ids[0],
      title: 'On the summit',
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

Future<Uint8List?> Function(String) phoneFiles(AppStore store) => (path) async {
  final f = File(store.location.resolve(path));
  return await f.exists() ? f.readAsBytes() : null;
};

Future<Map<String, Object?>> exportOf(SupabaseClient c) async =>
    ((await c.rpc('export_archive')) as Map).cast();

Future<int> expOf(SupabaseClient c) async =>
    (await c.from('journey_progress').select().eq('status', 'active'))
            .single['exp']
        as int;

void main() {
  late SupabaseClient a, b;

  setUpAll(() async {
    if (!configured) return;
    sqfliteFfiInit();
    a = await signIn('A');
    b = await signIn('B');
  });

  test(
    'a phone list goes into an empty account exactly, and merging it '
    'again adds nothing',
    () async {
      final phone = await TestArchive.create();
      final store = await phone.open();
      await buildPhone(store, 'Phone thing');
      final local = await store.archiveSnapshot();

      final backup = CloudBackup(a);
      final preview = await backup.preview(local);
      expect(preview.intoEmptyAccount, isTrue);
      expect(
        (preview.itemsAdded, preview.memoriesAdded, preview.photosAdded),
        (4, 1, 2),
      );
      expect(
        [
          for (final j in (await exportOf(a))['journeys'] as List)
            ...(j as Map)['items'] as List,
        ],
        isEmpty,
        reason: 'the preview changed nothing',
      );

      final result = await backup.merge(local, readFile: phoneFiles(store));
      expect(result.verified, isTrue);
      expect(result.uploaded, 2 * 2, reason: 'two photos and two thumbs');
      // The account now holds exactly the phone's list.
      expect(compareArchives(local, await exportOf(a)), isEmpty);
      expect(await expOf(a), 2000);

      // Again (e.g. the same backup imported on the website): nothing.
      final again = await backup.merge(local, readFile: phoneFiles(store));
      expect(again.summary.nothingToAdd, isTrue);
      expect(again.uploaded, 0);
      expect(compareArchives(local, await exportOf(a)), isEmpty);
      expect(await expOf(a), 2000, reason: 'EXP counted once');

      // The account's backup (as the website makes it) restores on a
      // phone identically, photos included.
      final before = await fingerprint(store);
      final (zip, _, missing) = await backup.export(appVersion: 'test');
      expect(missing, isEmpty);
      final contents = readBackupBytes(zip);
      expect(compareArchives(contents.data, local), isEmpty);
      final other = await TestArchive.create();
      var otherStore = await other.open();
      final file = File('${other.root.path}/from_web.zip')
        ..writeAsBytesSync(zip);
      final restore = await prepareImport(file.path, otherStore.location);
      await otherStore.importBackup(restore);
      expect(await fingerprint(otherStore), before);
      otherStore = await other.restart();
      expect(await fingerprint(otherStore), before);
      await other.dispose();
      await phone.dispose();
    },
    skip: configured ? false : 'set P1000_* for throwaway accounts',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'an account with its own list: the phone\'s is added, nothing is '
    'overwritten, repeat is harmless',
    () async {
      // B started on the website.
      await b.rpc(
        'add_item',
        params: {
          'p_id': ArchiveRepository.newId(),
          'p_title': 'Phone thing 1',
          'p_description': 'Typed on the website',
        },
      );
      await b.rpc(
        'add_item',
        params: {
          'p_id': ArchiveRepository.newId(),
          'p_title': 'Website only',
          'p_description': '',
        },
      );
      final phone = await TestArchive.create();
      final store = await phone.open();
      await buildPhone(store, 'Phone thing');
      final local = await store.archiveSnapshot();
      final backup = CloudBackup(b);

      final preview = await backup.preview(local);
      expect(preview.intoEmptyAccount, isFalse);
      expect(
        (preview.itemsAdded, preview.matchedByTitle, preview.textKept),
        (3, 1, 1),
      );
      final result = await backup.merge(local, readFile: phoneFiles(store));
      expect(result.verified, isTrue);
      final items = [
        for (final j in (await exportOf(b))['journeys'] as List)
          ...(j as Map)['items'] as List,
      ].cast<Map>();
      expect(items.map((i) => i['title']), [
        'Phone thing 1',
        'Website only',
        'Phone thing 3',
        'Phone thing 4',
        'Phone thing 2',
      ], reason: 'account first, then the phone\'s in its order; no duplicate');
      final one = items.first;
      expect(one['description'], 'Typed on the website', reason: 'kept');
      expect((one['isCompleted'], one['completedOn']), (true, '2031-03-04'));
      expect(((one['memories'] as List).single as Map)['hashtags'], [
        'travel',
        'dream',
      ]);
      expect(
        {for (final i in items) i['number']}.length,
        5,
        reason: 'numbers unique',
      );
      expect(await expOf(b), 2000);
      final again = await backup.merge(local, readFile: phoneFiles(store));
      expect(again.summary.nothingToAdd, isTrue);
      expect(await expOf(b), 2000);
      await phone.dispose();
    },
    skip: configured ? false : 'set P1000_* for throwaway accounts',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'phone and website: changes on either side reach the other by '
    'themselves',
    () async {
      final root = await Directory.systemTemp.createTemp('p1000_live_');
      final phone = await SyncedArchive.open(
        root: root,
        client: a,
        factory: databaseFactoryFfi,
      );
      final web = await signIn('A');
      final expBefore = await expOf(web).catchError((Object _) => 0);
      final arrived = StreamController<void>.broadcast();
      final live = LiveUpdates.start(a, () async {
        await phone.sync();
        arrived.add(null);
      })!;
      await Future<void>.delayed(const Duration(seconds: 3));

      // Website → phone, without the phone asking.
      var signal = arrived.stream.first.timeout(const Duration(seconds: 20));
      final id = ArchiveRepository.newId();
      await web.rpc(
        'add_item',
        params: {
          'p_id': id,
          'p_title': 'Added on the website',
          'p_description': '',
        },
      );
      await signal;
      expect(
        (await phone.loadItems()).map((i) => i.title),
        contains('Added on the website'),
      );

      // Phone → website: completing it on the phone.
      await phone.setCompleted(id, true, on: CalendarDate(2026, 10, 13));
      await phone.sync();
      final done = [
        for (final j in (await exportOf(web))['journeys'] as List)
          ...(j as Map)['items'] as List,
      ].cast<Map>().firstWhere((i) => i['id'] == id);
      expect((done['isCompleted'], done['completedOn']), (true, '2026-10-13'));
      expect(
        await expOf(web),
        expBefore + 1000,
        reason: 'one more thing, once',
      );

      // Website edits the profile → phone.
      signal = arrived.stream.first.timeout(const Duration(seconds: 20));
      await web.from('profiles').upsert({
        'user_id': web.auth.currentUser!.id,
        'name': 'Edited on the website',
      });
      await signal;
      expect((await phone.loadProfile()).name, 'Edited on the website');
      expect(compareArchives(await exportOf(web), await exportOf(a)), isEmpty);

      await live.stop();
      await phone.close();
      await root.delete(recursive: true);
    },
    skip: configured ? false : 'set P1000_* for throwaway accounts',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
