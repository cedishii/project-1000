// Friends, privacy and live updates against a real Supabase project, with
// three throwaway member accounts A, B and C. Skipped unless given:
//   P1000_URL, P1000_KEY, P1000_{A,B,C}_EMAIL, P1000_{A,B,C}_PASSWORD
// (never real accounts: the test changes their data).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/services/cloud/friends.dart';
import 'package:project_1000/services/cloud/live_updates.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final env = Platform.environment;
final configured = [
  'P1000_URL',
  'P1000_KEY',
  for (final x in ['A', 'B', 'C']) ...[
    'P1000_${x}_EMAIL',
    'P1000_${x}_PASSWORD',
  ],
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

Matcher refused(String code) =>
    throwsA(isA<FriendsException>().having((e) => e.code, 'code', code));

void main() {
  late SupabaseClient a, b, c;
  late SupabaseFriendsApi fa, fb, fc;
  late String idA, idB;

  setUpAll(() async {
    if (!configured) return;
    a = await signIn('A');
    b = await signIn('B');
    c = await signIn('C');
    fa = SupabaseFriendsApi(a);
    fb = SupabaseFriendsApi(b);
    fc = SupabaseFriendsApi(c);
    idA = a.auth.currentUser!.id;
    idB = b.auth.currentUser!.id;
  });

  test(
    'friend requests, privacy, revocation and read-only access',
    () async {
      final tag = DateTime.now().millisecondsSinceEpoch % 100000;
      // B's list and profile.
      for (final t in ['Sail across a lake', 'See the aurora']) {
        await b.rpc(
          'add_item',
          params: {
            'p_id': ArchiveRepository.newId(),
            'p_title': t,
            'p_description': '',
          },
        );
      }
      final jpeg = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 8, height: 8)),
      );
      await b.storage
          .from('photos')
          .uploadBinary(
            '$idB/profile/me.jpg',
            jpeg,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'image/jpeg',
            ),
          );
      await b.from('profiles').upsert({
        'user_id': idB,
        'name': 'Bee Private Name',
        'bio': 'Loves lakes',
        'photo': 'profile/me.jpg',
      });

      // Before choosing a username nobody can find or use Friends.
      expect(await fa.mySettings(), isNull);
      await expectLater(fa.search('e2e'), refused('username_required'));

      await fa.saveSettings(
        SharingSettings(username: 'e2e_a$tag', displayName: 'Ay E2E'),
      );
      await fb.saveSettings(
        SharingSettings(username: 'e2e_b$tag', displayName: 'Bee E2E'),
      );
      await fc.saveSettings(
        SharingSettings(username: 'e2e_c$tag', displayName: 'Cee E2E'),
      );

      // 1. A finds B and sends a request; only identity is shown.
      final found = await fa.search('e2e_b$tag');
      expect(found.map((p) => (p.username, p.displayName, p.relation)), [
        ('e2e_b$tag', 'Bee E2E', Relation.none),
      ]);
      expect(found.single.photo, isNull, reason: 'photo not shared yet');
      expect(await fa.search('Bee Private'), isEmpty, reason: 'private name');
      await fa.sendRequest(idB);
      await fa.sendRequest(idB); // repeating is harmless
      await expectLater(fb.sendRequest(idA), refused('they_already_asked_you'));
      await expectLater(fa.sendRequest(idA), refused('cannot_add_yourself'));

      // 2. B receives and accepts.
      final inbox = await fb.requests();
      expect(inbox.received.map((p) => p.userId), [idA]);
      expect((await fa.requests()).sent.map((p) => p.userId), [idB]);
      await expectLater(
        fc.respond(inbox.received.single.requestId!, accept: true),
        refused('request_not_found'),
        reason: 'only the recipient can answer',
      );
      await fb.respond(inbox.received.single.requestId!, accept: true);
      await expectLater(
        fb.respond(inbox.received.single.requestId!, accept: false),
        refused('request_not_pending'),
      );

      // 3. Both appear in each other's friends.
      expect((await fa.friends()).map((p) => p.userId), [idB]);
      expect((await fb.friends()).map((p) => p.userId), [idA]);
      await expectLater(fa.sendRequest(idB), refused('already_friends'));

      // 4. Profiles show only what B shares.
      var profile = await fa.profile(idB);
      expect(
        (profile.bio, profile.level, profile.listShared),
        (null, null, false),
      );
      await fb.saveSettings(
        SharingSettings(
          username: 'e2e_b$tag',
          displayName: 'Bee E2E',
          showPhoto: true,
          showBio: true,
          showLevel: true,
          showStats: true,
        ),
      );
      profile = await fa.profile(idB);
      expect(profile.bio, 'Loves lakes');
      expect((profile.level, profile.exp, profile.listed), (0, 0, 2));
      expect(profile.person.photo, 'profile/me.jpg');
      final photo = await a.storage
          .from('photos')
          .download('$idB/profile/me.jpg');
      expect(photo, jpeg, reason: 'shared profile photo readable');
      final cView = await fc.profile(idB);
      expect(
        (cView.bio, cView.level),
        (null, null),
        reason: 'C is not a friend',
      );

      // 6. Private list (default): even a friend is refused.
      await expectLater(fa.sharedList(idB), refused('list_not_shared'));
      // 5. Friends only: A sees it, read-only, in B's order.
      await fb.saveSettings(
        SharingSettings(
          username: 'e2e_b$tag',
          displayName: 'Bee E2E',
          listShared: true,
          showPhoto: true,
        ),
      );
      expect((await fa.sharedList(idB)).map((i) => i.title), [
        'Sail across a lake',
        'See the aurora',
      ]);
      // 7. A non-friend can't, through the app or the API.
      await expectLater(fc.sharedList(idB), refused('list_not_shared'));
      // 8. Direct API requests can't get around it.
      expect(await c.from('items').select().eq('user_id', idB), isEmpty);
      expect(await a.from('items').select().eq('user_id', idB), isEmpty);
      expect(await a.from('memories').select().eq('user_id', idB), isEmpty);
      expect(await a.from('profiles').select().eq('user_id', idB), isEmpty);
      expect(
        await a.from('social_profiles').select().eq('user_id', idB),
        isEmpty,
      );
      // The photo B shows in search is readable by C, but nothing else of
      // B's folder is.
      expect(
        await c.storage.from('photos').download('$idB/profile/me.jpg'),
        jpeg,
      );
      final listing = await c.storage.from('photos').list(path: '$idB/photos');
      expect(listing, isEmpty);
      // 9. A can't change B's entries.
      final bItems = await b
          .from('items')
          .select()
          .order('position', ascending: true);
      final bItem = bItems.first['id'] as String;
      for (final call in [
        () => a.rpc(
          'update_item',
          params: {'p_id': bItem, 'p_title': 'hacked', 'p_description': ''},
        ),
        () => a.rpc(
          'set_item_completed',
          params: {'p_id': bItem, 'p_completed': true, 'p_on': '2026-10-13'},
        ),
      ]) {
        await expectLater(call(), throwsA(isA<PostgrestException>()));
      }
      expect(
        ((await a.rpc('delete_item', params: {'p_id': bItem}))
            as Map)['deleted'],
        false,
      );
      final after = await b
          .from('items')
          .select()
          .order('position', ascending: true);
      expect(after.map((i) => (i['title'], i['is_completed'])), [
        ('Sail across a lake', false),
        ('See the aurora', false),
      ]);

      // 11. Private again: A loses access at once, same session.
      await fb.saveSettings(
        SharingSettings(
          username: 'e2e_b$tag',
          displayName: 'Bee E2E',
          showPhoto: true,
        ),
      );
      await expectLater(fa.sharedList(idB), refused('list_not_shared'));
      await fb.saveSettings(
        SharingSettings(
          username: 'e2e_b$tag',
          displayName: 'Bee E2E',
          listShared: true,
          showPhoto: true,
        ),
      );
      expect(await fa.sharedList(idB), hasLength(2));
      // 10. Removing the friend ends it.
      await fa.removeFriend(idB);
      await expectLater(fa.sharedList(idB), refused('list_not_shared'));
      expect(await fb.friends(), isEmpty);

      // Photo: hidden again when B stops showing it: the server stops
      // listing it, and storage refuses it. (Supabase's CDN may still
      // re-serve the exact response a viewer already downloaded with the
      // same session for a while; a fresh request is checked.)
      await fb.saveSettings(
        SharingSettings(username: 'e2e_b$tag', displayName: 'Bee E2E'),
      );
      expect((await fa.search('e2e_b$tag')).single.photo, isNull);
      final fresh = await http.get(
        Uri.parse(
          '${env['P1000_URL']}/storage/v1/object/authenticated/photos/'
          '$idB/profile/me.jpg?check=${DateTime.now().microsecondsSinceEpoch}',
        ),
        headers: {
          'apikey': env['P1000_KEY']!,
          'Authorization': 'Bearer ${a.auth.currentSession!.accessToken}',
        },
      );
      expect(fresh.statusCode, isNot(200));

      // Leaving Friends removes the username and relations only.
      await fb.leave();
      expect(await fa.search('e2e_b$tag'), isEmpty);
      expect(await b.from('items').select(), hasLength(2), reason: 'list kept');
    },
    skip: configured ? false : 'set P1000_* for three throwaway accounts',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'shared memories and their photos, only while shared',
    () async {
      final tag = DateTime.now().millisecondsSinceEpoch % 100000;
      // B: an entry with a memory and a photo (full size and thumbnail).
      final item = ArchiveRepository.newId();
      await b.rpc(
        'add_item',
        params: {
          'p_id': item,
          'p_title': 'Climb a volcano',
          'p_description': '',
        },
      );
      final photoId = ArchiveRepository.newId();
      final full = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 16, height: 12)),
      );
      final thumb = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 4, height: 3)),
      );
      final file = 'photos/$photoId.jpg', small = 'thumbs/$photoId.jpg';
      for (final (path, bytes) in [(file, full), (small, thumb)]) {
        await b.storage
            .from('photos')
            .uploadBinary(
              '$idB/$path',
              bytes,
              fileOptions: const FileOptions(contentType: 'image/jpeg'),
            );
      }
      await b.rpc(
        'save_memory',
        params: {
          'p_memory': {
            'id': ArchiveRepository.newId(),
            'itemId': item,
            'title': 'At the top',
            'text': 'Lava everywhere',
            'date': '2026-10-02',
            'location': 'Mayon',
            'hashtags': ['hike'],
            'photos': [
              {
                'id': photoId,
                'file': file,
                'thumb': small,
                'width': 16,
                'height': 12,
                'createdAt': DateTime.now().toUtc().toIso8601String(),
              },
            ],
          },
        },
      );
      final number =
          (await b.from('items').select('number').eq('id', item))
                  .single['number']
              as int;

      SharingSettings bee({bool memories = false, bool location = false}) =>
          SharingSettings(
            username: 'e2e_b$tag',
            displayName: 'Bee E2E',
            listShared: true,
            memoriesShared: memories,
            showMemoryLocation: location,
          );
      await fa.saveSettings(
        SharingSettings(username: 'e2e_a$tag', displayName: 'Ay E2E'),
      );
      await fb.saveSettings(bee());
      await fc.saveSettings(
        SharingSettings(username: 'e2e_c$tag', displayName: 'Cee E2E'),
      );
      await fa.sendRequest(idB);
      await fb.respond(
        (await fb.requests()).received.single.requestId!,
        accept: true,
      );

      Future<int> status(SupabaseClient who, String path) async =>
          (await http.get(
            Uri.parse(
              '${env['P1000_URL']}/storage/v1/object/authenticated/photos/'
              '$idB/$path?check=${DateTime.now().microsecondsSinceEpoch}',
            ),
            headers: {
              'apikey': env['P1000_KEY']!,
              'Authorization': 'Bearer ${who.auth.currentSession!.accessToken}',
            },
          )).statusCode;
      int countOf(List<SharedItem> items) =>
          items.singleWhere((i) => i.number == number).memoryCount;

      // List shared, memories private (the default): nothing of them.
      expect(countOf(await fa.sharedList(idB)), 0);
      await expectLater(
        fa.sharedMemories(idB, number),
        refused('memories_not_shared'),
      );
      expect(await status(a, file), isNot(200));

      // Memories shared: A reads them and downloads the photo; no location.
      await fb.saveSettings(bee(memories: true));
      expect((await fb.mySettings())!.memoriesShared, isTrue);
      expect(countOf(await fa.sharedList(idB)), 1);
      final got = (await fa.sharedMemories(idB, number)).single;
      expect(
        (got.title, got.body, got.location),
        ('At the top', 'Lava everywhere', ''),
      );
      expect(got.hashtags, ['hike']);
      expect(got.photos.single.file, file);
      expect(await a.storage.from('photos').download('$idB/$file'), full);
      expect(await a.storage.from('photos').download('$idB/$small'), thumb);
      // C (not a friend) gets nothing, through the app or storage.
      await expectLater(
        fc.sharedMemories(idB, number),
        refused('memories_not_shared'),
      );
      expect(await status(c, file), isNot(200));
      expect(await status(c, small), isNot(200));
      expect(await a.from('memories').select().eq('user_id', idB), isEmpty);
      expect(await a.from('photos').select().eq('user_id', idB), isEmpty);
      // Read-only.
      expect(
        await a.storage.from('photos').remove(['$idB/$file']),
        isEmpty,
        reason: 'nothing removed',
      );
      expect(await b.storage.from('photos').download('$idB/$file'), full);

      // Locations only when chosen.
      await fb.saveSettings(bee(memories: true, location: true));
      expect((await fa.sharedMemories(idB, number)).single.location, 'Mayon');

      // Memories private again: refused at once, photo too.
      await fb.saveSettings(bee());
      await expectLater(
        fa.sharedMemories(idB, number),
        refused('memories_not_shared'),
      );
      expect(await status(a, file), isNot(200));

      // Shared again, then the friendship ends: refused at once.
      await fb.saveSettings(bee(memories: true));
      expect(await status(a, file), 200);
      await fa.removeFriend(idB);
      await expectLater(
        fa.sharedMemories(idB, number),
        refused('memories_not_shared'),
      );
      expect(await status(a, file), isNot(200));

      for (final f in [fa, fb, fc]) {
        await f.leave();
      }
    },
    skip: configured ? false : 'set P1000_* for three throwaway accounts',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a change on another device arrives as a live signal',
    () async {
      final a2 = await signIn('A'); // the same account on another device
      final signals = StreamController<void>.broadcast();
      final live = LiveUpdates.start(a, () async => signals.add(null))!;
      final other = LiveUpdates.start(
        b,
        () async => fail('B got A\'s signal'),
      )!;
      // Give the subscriptions a moment to join.
      await Future<void>.delayed(const Duration(seconds: 3));
      final got = signals.stream.first.timeout(const Duration(seconds: 20));
      await a2.rpc(
        'add_item',
        params: {
          'p_id': ArchiveRepository.newId(),
          'p_title': 'From the website',
          'p_description': '',
        },
      );
      await got;
      await Future<void>.delayed(const Duration(seconds: 2));
      await live.stop();
      await other.stop();
    },
    skip: configured ? false : 'set P1000_* for three throwaway accounts',
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
