// Offline editing on a phone, against a real Supabase project: the
// phone's copy of the account (SyncedArchive) with the network switched
// off and on. Skipped unless a throwaway member account is given:
//   P1000_URL, P1000_KEY, P1000_W_EMAIL, P1000_W_PASSWORD
// (never a real account: the test changes and deletes its data).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/services/backup/export_service.dart';
import 'package:project_1000/services/cloud/cloud_migration.dart'
    show compareArchives;
import 'package:project_1000/services/cloud/synced_archive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final env = Platform.environment;
final configured = [
  'P1000_URL',
  'P1000_KEY',
  'P1000_W_EMAIL',
  'P1000_W_PASSWORD',
].every((k) => (env[k] ?? '').isNotEmpty);

/// A connection that can be cut, like a phone losing signal.
class Network extends http.BaseClient {
  final _inner = http.Client();
  bool offline = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (offline) {
      throw http.ClientException('no connection (test)', request.url);
    }
    return _inner.send(request);
  }
}

Future<SupabaseClient> signIn({http.Client? network}) async {
  final client = SupabaseClient(
    env['P1000_URL']!,
    env['P1000_KEY']!,
    httpClient: network,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  await client.auth.signInWithPassword(
    email: env['P1000_W_EMAIL']!,
    password: env['P1000_W_PASSWORD']!,
  );
  return client;
}

Future<Map<String, Object?>> exportOf(SupabaseClient c) async =>
    ((await c.rpc('export_archive')) as Map).cast();

List<Map> itemsOf(Map<String, Object?> data) => [
  for (final j in (data['journeys'] as List).cast<Map>())
    if (j['status'] == 'active') ...(j['items'] as List).cast<Map>(),
];

void main() {
  late Directory root;
  late Network network;
  late SupabaseClient phone, web;
  late SyncedArchive archive;

  setUpAll(() async {
    if (!configured) return;
    sqfliteFfiInit();
    root = await Directory.systemTemp.createTemp('p1000_sync_');
    network = Network();
    phone = await signIn(network: network);
    web = await signIn(); // another device, always online
  });
  tearDownAll(() async {
    if (!configured) return;
    await archive.close();
    await root.delete(recursive: true);
  });

  Future<SyncedArchive> openPhone() => SyncedArchive.open(
    root: root,
    client: phone,
    factory: databaseFactoryFfi,
  );

  /// The phone's copy, in the account's export format.
  Future<Map<String, Object?>> copyOf(SyncedArchive a) =>
      archiveSnapshot(a.cache.db);

  test(
    'offline changes are kept, survive a restart, and reach the account',
    () async {
      // 1. Online: the copy is the account.
      archive = await openPhone();
      final before = await exportOf(web);
      expect(compareArchives(await copyOf(archive), before), isEmpty);
      final start = itemsOf(before);
      expect(start, isNotEmpty, reason: 'seed the test account first');
      final second = start[1]['id'] as String;
      final third = start[2]['id'] as String;

      // 2. Offline: every change works right away on the phone.
      network.offline = true;
      final added = await archive.addItem('Offline thing', 'no signal');
      await archive.setCompleted(second, true, on: CalendarDate(2026, 10, 5));
      await archive.setCompleted(second, true, on: CalendarDate(2026, 10, 5));
      await archive.updateItemText(third, 'Edited offline', 'on a train');
      final photoId = ArchiveRepository.newId();
      final jpeg = img.encodeJpg(
        img.Image(width: 64, height: 48)..clear(img.ColorRgb8(10, 90, 160)),
      );
      final pending = Directory(archive.location.resolve('pending'));
      await pending.create(recursive: true);
      await File('${pending.path}/$photoId.jpg').writeAsBytes(jpeg);
      await File('${pending.path}/${photoId}_t.jpg').writeAsBytes(jpeg);
      final memoryId = await archive.saveMemory(
        MemoryDraft(
          itemId: second,
          title: 'Written offline',
          body: 'Saved on the phone first.',
          date: CalendarDate(2026, 10, 5),
          location: 'Somewhere without signal',
          hashtags: const ['offline'],
          photos: [
            PhotoRef(
              id: photoId,
              memoryId: '',
              position: 0,
              file: 'pending/$photoId.jpg',
              thumb: 'pending/${photoId}_t.jpg',
              width: 64,
              height: 48,
              createdAt: DateTime.utc(2026, 10, 5),
            ),
          ],
        ),
      );
      await archive.setSetting('theme_mode', 'dark');
      await archive.sync();
      expect(archive.status.value.offline, isTrue);
      expect(archive.pending, 6);
      expect(
        (await archive.loadItems()).map((i) => i.title),
        contains('Offline thing'),
      );
      // The account doesn't have any of it yet.
      expect(compareArchives(await exportOf(web), before), isEmpty);

      // 3. Restart the app, still offline: nothing is lost.
      await archive.close();
      archive = await openPhone();
      expect(archive.pending, 6);
      final items = await archive.loadItems();
      expect(items.map((i) => i.title), contains('Edited offline'));
      expect(
        (await archive.loadMemories(second)).map((m) => m.id),
        contains(memoryId),
      );

      // 4. Meanwhile, the website adds a thing (it takes the number the
      // offline thing has on the phone).
      final webItem = ((await web.rpc(
        'add_item',
        params: {
          'p_id': ArchiveRepository.newId(),
          'p_title': 'Added on the website',
          'p_description': '',
        },
      )) as Map);
      expect(webItem['number'], added.number);

      // 5. Back online: everything arrives once, and both sides match.
      network.offline = false;
      await archive.sync();
      expect(archive.status.value.offline, isFalse);
      expect(archive.pending, 0);
      final after = await exportOf(web);
      final remoteItems = itemsOf(after);
      expect(remoteItems.length, start.length + 2, reason: 'no duplicates');
      final titles = remoteItems.map((i) => i['title']).toList();
      expect(
        titles,
        containsAll([
          'Offline thing',
          'Added on the website',
          'Edited offline',
        ]),
      );
      final numbers = remoteItems.map((i) => i['number']).toSet();
      expect(numbers.length, remoteItems.length, reason: 'numbers unique');
      final done = remoteItems.firstWhere((i) => i['id'] == second);
      expect((done['isCompleted'], done['completedOn']), (true, '2026-10-05'));
      final memory = (done['memories'] as List).cast<Map>().firstWhere(
        (m) => m['id'] == memoryId,
      );
      expect(memory['hashtags'], ['offline']);
      expect((after['settings'] as Map)['theme_mode'], 'dark');
      final files = {
        for (final r in (await web.rpc('archive_files') as List).cast<Map>())
          r['path']: r['present'],
      };
      expect(files['photos/$photoId.jpg'], isTrue, reason: 'photo uploaded');
      expect(files['thumbs/$photoId.jpg'], isTrue, reason: 'thumb uploaded');
      final progress =
          (await web.from('journey_progress').select().eq('status', 'active'))
              .single;
      expect(progress['exp'], progress['completed_count'] * 1000);
      expect(compareArchives(await copyOf(archive), after), isEmpty);

      // 6. A change to something deleted elsewhere is skipped safely.
      network.offline = true;
      await archive.updateItemText(third, 'Too late', '');
      await web.rpc('delete_item', params: {'p_id': third});
      network.offline = false;
      await archive.sync();
      expect(archive.pending, 0);
      final last = await exportOf(web);
      expect(itemsOf(last).any((i) => i['id'] == third), isFalse);
      expect(compareArchives(await copyOf(archive), last), isEmpty);
    },
    skip: configured ? false : 'set P1000_* to run against a real project',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('nothing to test without credentials', () {
    expect(Uint8List(0), isEmpty);
  });
}
