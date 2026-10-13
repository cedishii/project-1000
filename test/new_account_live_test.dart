// A brand-new account on a phone, against a real Supabase project: an
// approved member who never copied anything into the account has no
// journey at all, and the phone's copy must still open. Skipped unless
// two throwaway member accounts with nothing in them are given:
//   P1000_URL, P1000_KEY, P1000_A_EMAIL, P1000_A_PASSWORD,
//   P1000_B_EMAIL, P1000_B_PASSWORD
// (never a real account).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:project_1000/data/local_archive.dart';
import 'package:project_1000/services/cloud/synced_archive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final env = Platform.environment;
final configured = [
  'P1000_URL',
  'P1000_KEY',
  'P1000_A_EMAIL',
  'P1000_A_PASSWORD',
  'P1000_B_EMAIL',
  'P1000_B_PASSWORD',
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

Future<int> journeysIn(SupabaseClient c) async =>
    ((await c.from('journeys').select('id')) as List).length;

void main() {
  late Directory root;

  setUpAll(() async {
    if (!configured) return;
    sqfliteFfiInit();
  });
  setUp(() async {
    if (!configured) return;
    root = await Directory.systemTemp.createTemp('p1000_new_');
  });
  tearDown(() async {
    if (!configured) return;
    await root.delete(recursive: true);
  });

  test('a new, empty account opens on a phone with Journey 1', () async {
    final client = await signIn('A');
    expect(await journeysIn(client), 0, reason: 'use an empty account');

    final archive = await SyncedArchive.open(
      root: root,
      client: client,
      factory: databaseFactoryFfi,
    );
    final journey = await archive.activeJourney();
    expect(journey.number, 1);
    // Everything the app reads when it opens.
    await archive.loadProfile();
    expect(await archive.loadItems(), isEmpty);
    await archive.memoryCounts();
    await archive.getSetting('theme_mode');
    expect(await journeysIn(client), 1);

    // The first thing added reaches the account.
    await archive.addItem('First thing', '');
    await archive.sync();
    expect(archive.pending, 0);
    expect(((await client.from('items').select('title')) as List).single, {
      'title': 'First thing',
    });

    // Opening again (the app restarting) starts no second journey.
    await archive.close();
    final again = await SyncedArchive.open(
      root: root,
      client: client,
      factory: databaseFactoryFfi,
    );
    expect((await again.activeJourney()).id, journey.id);
    expect(await journeysIn(client), 1);
    await again.close();
  }, skip: configured ? false : 'needs throwaway accounts');

  test('a copy left without a journey (v1.4.0) is repaired', () async {
    final client = await signIn('B');
    expect(await journeysIn(client), 0, reason: 'use an empty account');

    // What v1.4.0 left on the phone: a synced copy with no journey.
    final dir = SyncedArchive.cacheDir(root, client.auth.currentUser!.id);
    await dir.create(recursive: true);
    final local = await LocalArchive.open(dir, factory: databaseFactoryFfi);
    await local.db.delete('journeys');
    await local.close();
    final head = await client.rpc('pull_changes', params: {'p_since': 0});
    await File(p.join(dir.path, 'sync.json'))
        .writeAsString(jsonEncode({'revision': (head as Map)['revision']}));

    final archive = await SyncedArchive.open(
      root: root,
      client: client,
      factory: databaseFactoryFfi,
    );
    expect((await archive.activeJourney()).number, 1);
    expect(await journeysIn(client), 1);
    await archive.close();
  }, skip: configured ? false : 'needs throwaway accounts');
}
