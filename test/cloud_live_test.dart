// End-to-end tests of the cloud archive against a real Supabase project.
// Skipped unless these are set (throwaway member accounts, never real
// ones; see docs/CLOUD.md, "Live end-to-end tests"):
//   P1000_URL, P1000_KEY, P1000_A_EMAIL, P1000_A_PASSWORD,
//   P1000_B_EMAIL, P1000_B_PASSWORD, P1000_C_EMAIL, P1000_C_PASSWORD
// Account C must start empty; it receives a migrated phone archive.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:project_1000/data/archive_backend.dart';
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/services/cloud/cloud_archive.dart';
import 'package:project_1000/services/cloud/cloud_media.dart';
import 'package:project_1000/services/cloud/cloud_migration.dart';
import 'package:project_1000/services/cloud/supabase_migration_api.dart';
import 'package:project_1000/state/app_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'helpers.dart';
import 'memories_test.dart' show fakePendingPhoto;

final env = Platform.environment;
final configured = [
  'P1000_URL',
  'P1000_KEY',
  'P1000_A_EMAIL',
  'P1000_A_PASSWORD',
  'P1000_B_EMAIL',
  'P1000_B_PASSWORD',
  'P1000_C_EMAIL',
  'P1000_C_PASSWORD',
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

Future<AppStore> cloudStore(SupabaseClient client) async {
  final media = CloudMedia(client);
  final store = AppStore(
    CloudArchive(client, media),
    media,
    account: client.auth.currentUser!.email,
  );
  await store.load();
  return store;
}

/// Removes everything a test account stored (records and files).
Future<void> wipe(SupabaseClient client) async {
  final files = [
    for (final r in (await client.rpc('archive_files') as List).cast<Map>())
      r['path'] as String,
    for (final r in (await client.rpc('orphan_files') as List).cast<Map>())
      r['path'] as String,
  ];
  await CloudMedia(client).remove(files);
  // Deleting the account's rows is done by the cleanup SQL (the API
  // can't delete journeys), see docs/CLOUD.md.
}

XFile pngPhoto(String name, int shade) {
  final image = img.Image(width: 64, height: 48)
    ..clear(img.ColorRgb8(shade, 120, 80));
  return XFile.fromData(
    Uint8List.fromList(img.encodePng(image)),
    name: name,
    mimeType: 'image/png',
  );
}

void main() {
  late SupabaseClient phone, web, other;

  setUpAll(() async {
    if (!configured) return;
    phone = await signIn('A');
    web = await signIn('A'); // the same account on a second device
    other = await signIn('B');
  });
  tearDownAll(() async {
    if (!configured) return;
    await wipe(phone);
    await wipe(other);
  });

  test(
    'what one device saves, another device sees; nobody else does',
    () async {
      final a = await cloudStore(phone);
      expect(a.journey.number, 1);
      expect(a.items, isEmpty, reason: 'test account A must start empty');

      final lights = await a.addItem('Watch the Northern Lights', 'Someday');
      final sail = await a.addItem('Learn to sail', '');
      final run = await a.addItem('Run a marathon', '');
      expect([lights.number, sail.number, run.number], [1, 2, 3]);
      await a.setCompleted(lights.id, true, on: CalendarDate(2030, 9, 18));
      await a.setCompleted(lights.id, true, on: CalendarDate(2030, 9, 18));
      expect(a.progression.exp, 1000);
      await a.saveOrder([run.id, lights.id, sail.id]);

      final photo = await a.media.addPending(pngPhoto('lights.png', 30));
      final memoryId = await a.saveMemory(
        MemoryDraft(
          itemId: lights.id,
          title: 'Finally',
          body: 'Green ribbons.',
          date: CalendarDate(2030, 9, 18),
          location: 'Iceland',
          hashtags: parseHashtags('#travel #夢'),
          photos: [photo],
        ),
      );
      expect(await a.search('夢'), {lights.id});
      expect(await a.search('ICELAND'), {lights.id});

      // The second device sees exactly the same list, order and progress.
      final b = await cloudStore(web);
      expect(b.items.map((i) => i.title), [
        'Run a marathon',
        'Watch the Northern Lights',
        'Learn to sail',
      ]);
      expect(b.items.map((i) => i.number), [3, 1, 2]);
      expect(b.progression.exp, 1000);
      expect(b.memoryCountOf(lights.id), 1);
      final memory = (await b.loadMemories(lights.id)).single;
      expect(memory.id, memoryId);
      expect(memory.hashtags, ['travel', '夢']);
      expect(memory.photos.single.file, 'photos/${photo.id}.png');
      // The photo file is really stored, and readable from the other device.
      final bytes = await web.storage
          .from('photos')
          .download(
            '${web.auth.currentUser!.id}/${memory.photos.single.thumb}',
          );
      expect(bytes, isNotEmpty);

      // Edit on the second device; the first device's stale edit is refused.
      await b.updateItemText(sail.id, 'Learn to sail a boat', '');
      await expectLater(
        a.updateItemText(sail.id, 'Overwrite from old data', ''),
        throwsA(isA<StaleDataException>()),
      );
      await a.load();
      expect(a.itemById(sail.id)!.title, 'Learn to sail a boat');
      await a.updateItemText(sail.id, 'Learn to sail', 'now from fresh data');
      await b.load();
      expect(b.itemById(sail.id)!.description, 'now from fresh data');

      // Profile, picture and theme follow the account.
      await a.saveProfile(const Profile(name: 'Test A', bio: 'e2e'));
      await a.setProfilePhoto(
        Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8))),
      );
      await a.setThemeMode(ThemeMode.dark);
      await b.load();
      expect(b.profile.name, 'Test A');
      expect(b.profile.photo, startsWith('profile/'));
      expect(b.themeMode, ThemeMode.dark);

      // Another account sees none of it and can't change it by id.
      final c = await cloudStore(other);
      expect(c.items, isEmpty);
      expect(await c.loadMemories(lights.id), isEmpty);
      expect(await c.search('Northern'), isEmpty);
      await expectLater(
        c.updateItemText(lights.id, 'pwned', ''),
        throwsA(isA<ItemNotFoundException>()),
      );
      await expectLater(
        other.storage
            .from('photos')
            .download(
              '${phone.auth.currentUser!.id}/${memory.photos.single.file}',
            ),
        throwsA(isA<StorageException>()),
      );

      // Deleting removes the item, its memory and its photo files.
      await b.deleteItem(lights.id);
      await a.load();
      expect(a.itemById(lights.id), isNull);
      final orphans = await phone.rpc('orphan_files') as List;
      expect(orphans, isEmpty);
    },
    skip: configured ? false : 'set P1000_* to run against a real project',
  );

  test('a phone archive migrates into an empty account and verifies', () async {
    final archive = await TestArchive.create();
    final c = await signIn('C');
    try {
      final local = await archive.open();
      final item = await local.addItem('Watch the Northern Lights', '');
      await local.setCompleted(item.id, true, on: CalendarDate(2030, 9, 18));
      await local.saveMemory(
        MemoryDraft(
          itemId: item.id,
          title: 'Finally',
          body: 'Green ribbons.',
          date: CalendarDate(2030, 9, 18),
          location: 'Iceland',
          hashtags: const ['travel'],
          photos: [await fakePendingPhoto(local, 'pixels')],
        ),
      );
      await local.addItem('Learn to sail', 'with a 100% chance of rain');

      final migration = CloudMigration(
        location: local.location,
        snapshot: local.archiveSnapshot,
        api: SupabaseMigrationApi(c),
      );
      final report = await migration.run();
      expect(report.verified, isTrue, reason: '${report.differences}');
      expect(report.uploaded, 2);
      // Running it again changes nothing.
      final again = await migration.run();
      expect(again.verified, isTrue);
      expect(again.uploaded, 0);

      // The account now shows the phone's list.
      final cloud = await cloudStore(c);
      expect(cloud.items.map((i) => i.id), local.items.map((i) => i.id));
      expect(cloud.progression.exp, 1000);
    } finally {
      await wipe(c);
      await archive.dispose();
    }
  }, skip: configured ? false : 'set P1000_* to run against a real project');

  test('ids are fresh UUIDs', () {
    expect(ArchiveRepository.newId(), hasLength(36));
  });
}
