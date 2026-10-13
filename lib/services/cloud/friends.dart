import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models.dart';
import '../media_store.dart';
import 'cloud_backup.dart' show isConnectionError;
import 'cloud_media.dart';

/// Where someone stands with the signed-in user.
enum Relation { self, friend, sent, received, none }

/// Someone as others see them: only what identifies them.
class Person {
  Person.fromJson(Map json)
    : userId = json['userId'] as String,
      username = json['username'] as String,
      displayName = json['displayName'] as String,
      photo = json['photo'] as String?,
      relation = Relation.values.byName('${json['relation'] ?? 'none'}'),
      requestId = json['requestId'] as String?,
      since = DateTime.tryParse('${json['since'] ?? json['sentAt']}');

  final String userId;
  final String username;
  final String displayName;

  /// `profile/<file>`, only when its owner shows it.
  final String? photo;
  final Relation relation;

  /// The waiting request between the two (sent or received).
  final String? requestId;

  /// Friends since, or when the request was sent.
  final DateTime? since;
}

/// A friend's profile: who they are and what they chose to share. Fields
/// they don't share are null.
class FriendProfile {
  FriendProfile.fromJson(Map json)
    : person = Person.fromJson(json),
      listShared = json['listShared'] == true,
      bio = json['bio'] as String?,
      startedOn = json['startedOn'] == null
          ? null
          : CalendarDate.parse('${json['startedOn']}'),
      completed = (json['stats'] as Map?)?['completed'] as int?,
      listed = (json['stats'] as Map?)?['listed'] as int?,
      journeysFinished = (json['stats'] as Map?)?['journeysFinished'] as int?,
      level = (json['progress'] as Map?)?['level'] as int?,
      exp = (json['progress'] as Map?)?['exp'] as int?;

  final Person person;
  final bool listShared;
  final String? bio;
  final CalendarDate? startedOn;
  final int? completed;
  final int? listed;
  final int? journeysFinished;
  final int? level;
  final int? exp;
}

/// One entry of a friend's shared list (read-only).
class SharedItem {
  SharedItem.fromJson(Map json)
    : number = json['number'] as int,
      title = json['title'] as String,
      description = '${json['description'] ?? ''}',
      isCompleted = json['isCompleted'] == true,
      completedOn = json['completedOn'] == null
          ? null
          : CalendarDate.parse('${json['completedOn']}'),
      memoryCount = (json['memories'] as int?) ?? 0;

  final int number;
  final String title;
  final String description;
  final bool isCompleted;
  final CalendarDate? completedOn;

  /// How many memories it has, when its owner shares memories (else 0).
  final int memoryCount;
}

/// A memory of a friend's entry, when they share memories (read-only).
/// [location] is empty unless they also share locations.
class SharedMemory {
  SharedMemory.fromJson(Map json)
    : title = '${json['title'] ?? ''}',
      body = '${json['body'] ?? ''}',
      date = CalendarDate.parse('${json['date']}'),
      location = '${json['location'] ?? ''}',
      hashtags = [for (final h in (json['hashtags'] as List? ?? [])) '$h'],
      photos = [
        for (final p in (json['photos'] as List? ?? []))
          SharedPhoto.fromJson(p as Map),
      ];

  final String title;
  final String body;
  final CalendarDate date;
  final String location;
  final List<String> hashtags;
  final List<SharedPhoto> photos;
}

/// A photo of a shared memory: its paths in the owner's storage.
class SharedPhoto {
  SharedPhoto.fromJson(Map json)
    : file = json['file'] as String,
      thumb = json['thumb'] as String,
      width = json['width'] as int?,
      height = json['height'] as int?;

  final String file;
  final String thumb;
  final int? width;
  final int? height;
}

/// The signed-in user's username and sharing choices
/// (`public.social_profiles`). Everything is off by default.
class SharingSettings {
  const SharingSettings({
    required this.username,
    required this.displayName,
    this.showPhoto = false,
    this.showBio = false,
    this.showStartedOn = false,
    this.showStats = false,
    this.showLevel = false,
    this.listShared = false,
    this.memoriesShared = false,
    this.showMemoryLocation = false,
  });

  SharingSettings.fromRow(Map row)
    : username = row['username'] as String,
      displayName = row['display_name'] as String,
      showPhoto = row['show_photo'] == true,
      showBio = row['show_bio'] == true,
      showStartedOn = row['show_started_on'] == true,
      showStats = row['show_stats'] == true,
      showLevel = row['show_level'] == true,
      listShared = row['list_visibility'] == 'friends',
      memoriesShared = row['memory_visibility'] == 'friends',
      showMemoryLocation = row['show_memory_location'] == true;

  final String username;
  final String displayName;
  final bool showPhoto;
  final bool showBio;
  final bool showStartedOn;
  final bool showStats;
  final bool showLevel;

  /// The list's visibility: friends only (true) or private (false).
  final bool listShared;

  /// Memories (text, photos, hashtags) shown to friends who can see the
  /// list; [showMemoryLocation] adds where they happened.
  final bool memoriesShared;
  final bool showMemoryLocation;
}

/// A friends action the server refused or couldn't do, in plain words.
class FriendsException implements Exception {
  FriendsException(this.message, [this.code]);

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// What the Friends screens need (the Supabase functions in
/// supabase/migrations/20261013000100_friends.sql). Every rule — who can
/// be found, who sees what, who may answer a request — is enforced
/// there; this only calls them. Tests use a fake.
abstract interface class FriendsApi {
  /// The signed-in user's id.
  String get myUserId;

  /// The user's own settings, or null before they chose a username.
  Future<SharingSettings?> mySettings();
  Future<SharingSettings> saveSettings(SharingSettings settings);

  /// Removes the username, every friendship and request. The list itself
  /// is not touched.
  Future<void> leave();

  Future<List<Person>> search(String query);
  Future<void> sendRequest(String userId);
  Future<void> respond(String requestId, {required bool accept});
  Future<void> cancelRequest(String requestId);
  Future<void> removeFriend(String userId);
  Future<List<Person>> friends();
  Future<({List<Person> received, List<Person> sent})> requests();
  Future<FriendProfile> profile(String userId);
  Future<List<SharedItem>> sharedList(String userId);

  /// The memories of entry [number] of someone's shared list.
  Future<List<SharedMemory>> sharedMemories(String userId, int number);

  /// Someone's shared profile photo ([Person.photo]) or a photo of a
  /// shared memory ([SharedPhoto.file] or [SharedPhoto.thumb]).
  ImageProvider photo(String userId, String path);
}

class SupabaseFriendsApi implements FriendsApi {
  SupabaseFriendsApi(this.client);

  final SupabaseClient client;

  String get _me => client.auth.currentUser!.id;

  @override
  String get myUserId => _me;

  Future<T> _call<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on PostgrestException catch (e) {
      throw FriendsException(_message(e.message), e.message);
    } on AuthException {
      throw FriendsException('Please sign in again.');
    } catch (e) {
      if (isConnectionError(e)) {
        throw FriendsException(
          'Friends needs an internet connection. Check it and try again.',
          'offline',
        );
      }
      rethrow;
    }
  }

  static String _message(String code) => switch (code) {
    'username_required' => 'Choose a username first.',
    'invalid_username' =>
      'Usernames are 3–20 lowercase letters, numbers or underscores.',
    'username_taken' => 'That username is already taken.',
    'invalid_display_name' => 'Please enter a name (up to 60 characters).',
    'cannot_add_yourself' => 'That\'s you.',
    'person_not_found' => 'That person can\'t be found any more.',
    'already_friends' => 'You\'re already friends.',
    'they_already_asked_you' =>
      'They already sent you a request. Accept it under Requests.',
    'recently_declined' => 'You can\'t send them another request yet.',
    'too_many_requests' =>
      'You\'ve sent a lot of requests today. Try again tomorrow.',
    'request_not_found' ||
    'request_not_pending' => 'That request is no longer waiting.',
    'list_not_shared' => 'This list is private.',
    'memories_not_shared' => 'These memories are private.',
    'item_not_found' => 'That entry no longer exists.',
    'not_a_member' => 'Your account isn\'t active.',
    _ => 'Something went wrong. Please try again.',
  };

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) =>
      _call(() => client.rpc(fn, params: params));

  @override
  Future<SharingSettings?> mySettings() async {
    final rows = await _call(
      () => client.from('social_profiles').select().eq('user_id', _me),
    );
    return rows.isEmpty ? null : SharingSettings.fromRow(rows.first);
  }

  @override
  Future<SharingSettings> saveSettings(SharingSettings s) async =>
      SharingSettings.fromRow(
        await _rpc('save_social_profile', {
          'p_username': s.username,
          'p_display_name': s.displayName,
          'p_show_photo': s.showPhoto,
          'p_show_bio': s.showBio,
          'p_show_started_on': s.showStartedOn,
          'p_show_stats': s.showStats,
          'p_show_level': s.showLevel,
          'p_list_visibility': s.listShared ? 'friends' : 'private',
          'p_memory_visibility': s.memoriesShared ? 'friends' : 'private',
          'p_show_memory_location': s.showMemoryLocation,
        }) as Map,
      );

  @override
  Future<void> leave() => _rpc('delete_social_profile');

  @override
  Future<List<Person>> search(String query) async => [
    for (final p in (await _rpc('search_people', {'p_query': query}) as List))
      Person.fromJson(p as Map),
  ];

  @override
  Future<void> sendRequest(String userId) =>
      _rpc('send_friend_request', {'p_user': userId});

  @override
  Future<void> respond(String requestId, {required bool accept}) => _rpc(
    'respond_friend_request',
    {'p_request': requestId, 'p_accept': accept},
  );

  @override
  Future<void> cancelRequest(String requestId) =>
      _rpc('cancel_friend_request', {'p_request': requestId});

  @override
  Future<void> removeFriend(String userId) =>
      _rpc('remove_friend', {'p_user': userId});

  @override
  Future<List<Person>> friends() async => [
    for (final p in (await _rpc('list_friends') as List))
      Person.fromJson(p as Map),
  ];

  @override
  Future<({List<Person> received, List<Person> sent})> requests() async {
    final r = await _rpc('list_friend_requests') as Map;
    return (
      received: [
        for (final p in r['received'] as List) Person.fromJson(p as Map),
      ],
      sent: [for (final p in r['sent'] as List) Person.fromJson(p as Map)],
    );
  }

  @override
  Future<FriendProfile> profile(String userId) async => FriendProfile.fromJson(
    await _rpc('friend_profile', {'p_user': userId}) as Map,
  );

  @override
  Future<List<SharedItem>> sharedList(String userId) async => [
    for (final i
        in ((await _rpc('friend_list', {'p_user': userId}) as Map)['items']
            as List))
      SharedItem.fromJson(i as Map),
  ];

  @override
  Future<List<SharedMemory>> sharedMemories(String userId, int number) async =>
      [
        for (final m
            in ((await _rpc('friend_memories', {
                  'p_user': userId,
                  'p_number': number,
                }) as Map)['memories']
                as List))
          SharedMemory.fromJson(m as Map),
      ];

  @override
  ImageProvider photo(String userId, String path) {
    final key = '$userId/$path';
    return BytesImage(
      'friend:$key',
      () => client.storage.from(CloudMedia.bucket).download(key),
    );
  }
}

/// The number of friend requests waiting for the user, kept fresh while
/// the app is open (checked every minute, when the app returns to the
/// foreground, and after every friends action) so the Friends tab can
/// show a badge.
class FriendRequestCount extends ValueNotifier<int> {
  FriendRequestCount(this.api, {Duration? every = const Duration(minutes: 1)})
    : super(0) {
    refresh();
    if (every != null) _timer = Timer.periodic(every, (_) => refresh());
  }

  final FriendsApi api;
  Timer? _timer;

  Future<void> refresh() async {
    try {
      if (await api.mySettings() == null) {
        value = 0;
        return;
      }
      value = (await api.requests()).received.length;
    } catch (_) {
      // Offline or signed out: keep the last count.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
