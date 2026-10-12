import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/archive_backend.dart';
import '../../data/archive_repository.dart';
import '../../data/models.dart';
import '../photo_storage.dart' show PhotoStorage;
import 'cloud_media.dart';

/// The archive of the signed-in cloud account (Supabase). Every change
/// goes through the server functions in supabase/migrations, which hold
/// the same rules as [ArchiveRepository]; reads use the tables directly
/// (row-level security limits them to the account's own rows).
///
/// All writes are safe to repeat: new records get their id here, so a
/// request that is retried after a dropped connection can't create a
/// duplicate. Edits carry the revision last seen, so an edit based on
/// outdated data fails with [StaleDataException] instead of overwriting.
class CloudArchive implements ArchiveBackend {
  CloudArchive(this.client, this.media);

  final SupabaseClient client;
  final CloudMedia media;

  /// Item id → the revision this device last loaded.
  final _revisions = <String, int>{};

  String get _userId => client.auth.currentUser!.id;

  // ---------------------------------------------------------------- calls

  /// Runs [request]; retries once after a connection failure (every call
  /// is idempotent) and translates server errors into the app's
  /// exceptions.
  Future<T> _call<T>(Future<T> Function() request) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await request();
      } on PostgrestException catch (e) {
        throw _translate(e);
      } on StorageException {
        rethrow;
      } on AuthException {
        throw NotAMemberException();
      } catch (e) {
        if (!_isConnectionError(e)) rethrow;
        if (attempt >= 1) throw CloudUnavailableException(e);
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    }
  }

  static bool _isConnectionError(Object e) {
    final s = e.runtimeType.toString();
    return e is TimeoutException ||
        s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('HandshakeException');
  }

  static Object _translate(PostgrestException e) =>
      switch ((e.code, e.message)) {
        ('PT403', _) => NotAMemberException(),
        ('PT404', _) => ItemNotFoundException(),
        ('PT409', 'stale_revision') => StaleDataException(),
        ('PT409', 'list_full') => ListFullException(),
        ('PT409', 'journey_not_complete') => JourneyNotCompleteException(),
        ('42501', _) => NotAMemberException(),
        _ => e,
      };

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) =>
      _call(() => client.rpc(fn, params: params));

  // ---------------------------------------------------------------- reads

  @override
  Future<Journey> activeJourney() async =>
      journeyFromRow((await _rpc('ensure_active_journey')) as Map);

  @override
  Future<Profile> loadProfile() async {
    final row = await _call(
      () => client.from('profiles').select().maybeSingle(),
    );
    return row == null ? const Profile() : profileFromRow(row);
  }

  @override
  Future<List<BucketItem>> loadItems({String? journeyId}) async {
    final id = journeyId ?? (await activeJourney()).id;
    final rows = await _call(
      () => client
          .from('items')
          .select()
          .eq('journey_id', id)
          .order('position', ascending: true)
          .order('created_at', ascending: true)
          .order('id', ascending: true),
    );
    return [
      for (final r in rows)
        (() {
          _revisions[r['id'] as String] = r['revision'] as int;
          return itemFromRow(r);
        })(),
    ];
  }

  @override
  Future<Map<String, int>> memoryCounts({String? journeyId}) async {
    final rows =
        (await _rpc('memory_counts', {'p_journey_id': journeyId})) as List;
    return {
      for (final r in rows.cast<Map>())
        r['item_id'] as String: r['memory_count'] as int,
    };
  }

  @override
  Future<Set<String>> searchItemIds(String query, {String? journeyId}) async {
    if (query.trim().replaceFirst(RegExp(r'^#'), '').isEmpty) return {};
    final rows = (await _rpc('search_item_ids', {
      'p_query': query,
      'p_journey_id': journeyId,
    })) as List;
    return {for (final r in rows) r as String};
  }

  @override
  Future<List<Memory>> loadMemories(String itemId) async {
    final rows = await _call(
      () => client
          .from('memories')
          .select()
          .eq('item_id', itemId)
          .order('position', ascending: true)
          .order('created_at', ascending: true),
    );
    return _withPhotos(rows.cast<Map<String, dynamic>>());
  }

  @override
  Future<List<Memory>> loadMemoriesByIds(List<String> ids) async {
    final byId = <String, Memory>{};
    for (var i = 0; i < ids.length; i += 100) {
      final chunk = ids.sublist(i, (i + 100).clamp(0, ids.length));
      final rows = await _call(
        () => client.from('memories').select().inFilter('id', chunk),
      );
      for (final m in await _withPhotos(rows.cast<Map<String, dynamic>>())) {
        byId[m.id] = m;
      }
    }
    return [for (final id in ids) ?byId[id]];
  }

  Future<List<Memory>> _withPhotos(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return [];
    final photos = <String, List<PhotoRef>>{};
    final ids = [for (final r in rows) r['id'] as String];
    for (var i = 0; i < ids.length; i += 100) {
      final chunk = ids.sublist(i, (i + 100).clamp(0, ids.length));
      final photoRows = await _call(
        () => client
            .from('photos')
            .select()
            .inFilter('memory_id', chunk)
            .order('position', ascending: true),
      );
      for (final ph in photoRows) {
        photos
            .putIfAbsent(ph['memory_id'] as String, () => [])
            .add(photoFromRow(ph));
      }
    }
    return [
      for (final r in rows) memoryFromRow(r, photos[r['id']] ?? const []),
    ];
  }

  @override
  Future<List<JourneySummary>> journeySummaries() async {
    final journeys = await _call(
      () => client.from('journeys').select().order('number', ascending: true),
    );
    final progress = await _call(
      () => client.from('journey_progress').select(),
    );
    final byId = {for (final p in progress) p['journey_id']: p};
    return [
      for (final j in journeys)
        JourneySummary(
          journey: journeyFromRow(j),
          itemCount: byId[j['id']]?['item_count'] as int? ?? 0,
          completedCount: byId[j['id']]?['completed_count'] as int? ?? 0,
          memoryCount: byId[j['id']]?['memory_count'] as int? ?? 0,
          photoCount: byId[j['id']]?['photo_count'] as int? ?? 0,
        ),
    ];
  }

  @override
  Future<List<AlbumEntry>> albumOutline(String journeyId) async {
    final rows =
        (await _rpc('album_outline', {'p_journey_id': journeyId})) as List;
    return [
      for (final e in rows.cast<Map>())
        AlbumEntry(
          item: itemFromRow(e['item'] as Map),
          memories: [
            for (final m in (e['memories'] as List).cast<Map>())
              AlbumMemoryMeta(
                id: m['id'] as String,
                textLength: m['textLength'] as int,
                photoCount: m['photoCount'] as int,
              ),
          ],
        ),
    ];
  }

  @override
  Future<String?> getSetting(String key) async {
    final row = await _call(
      () =>
          client.from('settings').select('value').eq('key', key).maybeSingle(),
    );
    return row?['value'] as String?;
  }

  // --------------------------------------------------------------- writes

  @override
  Future<BucketItem> addItem(String title, String description) async {
    final row = await _rpc('add_item', {
      'p_id': ArchiveRepository.newId(),
      'p_title': title,
      'p_description': description,
    });
    return itemFromRow(row as Map);
  }

  @override
  Future<void> updateItemText(
    String id,
    String title,
    String description,
  ) async {
    final row = await _rpc('update_item', {
      'p_id': id,
      'p_title': title,
      'p_description': description,
      'p_expected_revision': _revisions[id],
    });
    _revisions[id] = (row as Map)['revision'] as int;
  }

  @override
  Future<void> setCompleted(String id, bool completed, {CalendarDate? on}) =>
      _rpc('set_item_completed', {
        'p_id': id,
        'p_completed': completed,
        // The user's own calendar day, not the server's.
        'p_on': (on ?? CalendarDate.today()).toIso(),
      });

  @override
  Future<void> deleteItem(String id) async {
    final result = await _rpc('delete_item', {'p_id': id}) as Map;
    await media.remove((result['files'] as List).cast<String>());
  }

  @override
  Future<void> saveOrder(List<String> orderedIds) =>
      _rpc('save_order', {'p_ids': orderedIds});

  /// New photos are uploaded first (to paths unique to each photo), then
  /// the memory is saved in one server transaction. If that fails, the
  /// uploads are removed again, so nothing is half-saved.
  @override
  Future<String> saveMemory(MemoryDraft draft) async {
    final id = draft.id ?? ArchiveRepository.newId();
    final uploaded = <String>[];
    final photos = <PhotoRef>[];
    try {
      for (final ph in draft.photos) {
        if (!PhotoStorage.isPending(ph)) {
          photos.add(ph);
          continue;
        }
        final ext = ph.file.substring(ph.file.lastIndexOf('.'));
        final file = 'photos/${ph.id}$ext', thumb = 'thumbs/${ph.id}.jpg';
        for (final (from, to) in [(ph.file, file), (ph.thumb, thumb)]) {
          final bytes = media.pendingBytes(from);
          if (bytes == null) throw StateError('Pending photo $from is gone');
          await _call(() => media.upload(to, bytes));
          uploaded.add(to);
        }
        photos.add(
          PhotoRef(
            id: ph.id,
            memoryId: id,
            position: ph.position,
            file: file,
            thumb: thumb,
            width: ph.width,
            height: ph.height,
            createdAt: ph.createdAt,
          ),
        );
      }
      final result = await _rpc('save_memory', {
        'p_memory': {
          'id': id,
          'itemId': draft.itemId,
          'title': draft.title,
          'text': draft.body,
          'date': draft.date.toIso(),
          'location': draft.location,
          'hashtags': draft.hashtags,
          'photos': [
            for (final ph in photos)
              {
                'id': ph.id,
                'file': ph.file,
                'thumb': ph.thumb,
                'width': ph.width,
                'height': ph.height,
                'createdAt': ph.createdAt.toUtc().toIso8601String(),
              },
          ],
        },
      }) as Map;
      await media.remove((result['removedFiles'] as List).cast<String>());
    } catch (_) {
      await media.remove(uploaded);
      rethrow;
    }
    await media.discard(draft.photos);
    return id;
  }

  @override
  Future<void> deleteMemory(String id) async {
    final result = await _rpc('delete_memory', {'p_id': id}) as Map;
    await media.remove((result['files'] as List).cast<String>());
  }

  @override
  Future<void> setJourneyStart(CalendarDate? date) =>
      _rpc('set_journey_start', {'p_date': date?.toIso()});

  /// The server works out the archived journey's dates the same way the
  /// phone does; the profile picture is copied in storage first.
  @override
  Future<Journey> startNewJourney({
    required CalendarDate? startedOn,
    required CalendarDate completedOn,
    required Profile profile,
    required CalendarDate newStartedOn,
    required bool reuseList,
  }) async {
    final finishing = await activeJourney();
    String? photoCopy;
    if (profile.photo != null && !profile.isEmpty) {
      final copy = 'profile/${ArchiveRepository.newId()}.jpg';
      try {
        await _call(() => media.copy(profile.photo!, copy));
        photoCopy = copy;
      } on StorageException {
        photoCopy = null; // the picture is missing; keep going without it
      }
    }
    try {
      final row = await _rpc('start_new_journey', {
        'p_new_started_on': newStartedOn.toIso(),
        'p_reuse_list': reuseList,
        'p_snapshot_photo': photoCopy,
        'p_finishing_journey': finishing.id,
      });
      return journeyFromRow(row as Map);
    } catch (_) {
      if (photoCopy != null) await media.remove([photoCopy]);
      rethrow;
    }
  }

  @override
  Future<void> saveProfile(Profile profile) => _call(
    () => client.from('profiles').upsert({
      'user_id': _userId,
      'name': profile.name.trim(),
      'nickname': profile.nickname.trim(),
      'age': profile.age,
      'started_on': profile.startedOn?.toIso(),
      'bio': profile.bio.trim(),
      'photo': profile.photo,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }),
  );

  @override
  Future<void> setProfilePhoto(Profile current, Uint8List jpeg) async {
    final rel = 'profile/${ArchiveRepository.newId()}.jpg';
    await _call(() => media.upload(rel, jpeg));
    try {
      await saveProfile(current.copyWith(photo: rel));
    } catch (_) {
      await media.remove([rel]);
      rethrow;
    }
    if (current.photo != null) await media.remove([current.photo!]);
  }

  @override
  Future<void> removeProfilePhoto(Profile current) async {
    await saveProfile(current.copyWith(clearPhoto: true));
    if (current.photo != null) await media.remove([current.photo!]);
  }

  @override
  Future<void> setSetting(String key, String value) => _call(
    () => client.from('settings').upsert({
      'user_id': _userId,
      'key': key,
      'value': value,
    }),
  );
}

// ------------------------------------------------------------------ mapping

CalendarDate? _date(Object? v) => v == null ? null : CalendarDate.parse('$v');
DateTime _time(Object? v) => DateTime.parse('$v');

Journey journeyFromRow(Map r) => Journey(
  id: r['id'] as String,
  number: r['number'] as int,
  status: r['status'] == 'archived'
      ? JourneyStatus.archived
      : JourneyStatus.active,
  startedOn: _date(r['started_on']),
  completedOn: _date(r['completed_on']),
  snapshot: r['snapshot'] == null
      ? null
      : Profile.fromJson(r['snapshot'] as Map),
  createdAt: _time(r['created_at']),
  archivedAt: r['archived_at'] == null ? null : _time(r['archived_at']),
);

BucketItem itemFromRow(Map r) => BucketItem(
  id: r['id'] as String,
  journeyId: r['journey_id'] as String,
  number: r['number'] as int,
  position: r['position'] as int,
  title: r['title'] as String,
  description: r['description'] as String,
  isCompleted: r['is_completed'] as bool,
  completedOn: _date(r['completed_on']),
  createdAt: _time(r['created_at']),
  updatedAt: _time(r['updated_at']),
);

Memory memoryFromRow(Map r, List<PhotoRef> photos) => Memory(
  id: r['id'] as String,
  itemId: r['item_id'] as String,
  position: r['position'] as int,
  title: r['title'] as String,
  body: r['body'] as String,
  date: CalendarDate.parse(r['date'] as String),
  location: r['location'] as String,
  hashtags: (r['hashtags'] as List).cast<String>(),
  photos: photos,
  createdAt: _time(r['created_at']),
  updatedAt: _time(r['updated_at']),
);

PhotoRef photoFromRow(Map r) => PhotoRef(
  id: r['id'] as String,
  memoryId: r['memory_id'] as String,
  position: r['position'] as int,
  file: r['file'] as String,
  thumb: r['thumb'] as String,
  width: r['width'] as int?,
  height: r['height'] as int?,
  createdAt: _time(r['created_at']),
);

Profile profileFromRow(Map r) => Profile(
  name: r['name'] as String,
  nickname: r['nickname'] as String,
  age: r['age'] as int?,
  startedOn: _date(r['started_on']),
  bio: r['bio'] as String,
  photo: r['photo'] as String?,
);
