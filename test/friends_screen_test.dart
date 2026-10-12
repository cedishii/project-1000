// The Friends screens against an in-memory stand-in for the server (the
// real rules are tested in supabase/tests and test/friends_live_test).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_1000/services/cloud/friends.dart';
import 'package:project_1000/state/app_store.dart';
import 'package:project_1000/ui/screens/friends_screen.dart';
import 'package:project_1000/ui/store_scope.dart';

import 'helpers.dart';

class FakeFriends implements FriendsApi {
  SharingSettings? settings;
  final people = <String, Map<String, Object?>>{
    'bob': {'userId': 'bob', 'username': 'bob', 'displayName': 'Bob B'},
    'carol': {'userId': 'carol', 'username': 'carol', 'displayName': 'Carol C'},
  };
  final relation = <String, String>{'bob': 'none', 'carol': 'received'};
  final shared = <String>{'carol'};
  final calls = <String>[];

  Person _p(String id) => Person.fromJson({
    ...people[id]!,
    'relation': relation[id],
    'requestId': 'r-$id',
  });

  @override
  String get myUserId => 'me';

  @override
  Future<SharingSettings?> mySettings() async => settings;

  @override
  Future<SharingSettings> saveSettings(SharingSettings s) async {
    calls.add('save ${s.username} list=${s.listShared}');
    return settings = s;
  }

  @override
  Future<void> leave() async => settings = null;

  @override
  Future<List<Person>> search(String query) async => [
    for (final id in people.keys)
      if (id.contains(query.toLowerCase())) _p(id),
  ];

  @override
  Future<void> sendRequest(String userId) async {
    calls.add('send $userId');
    relation[userId] = 'sent';
  }

  @override
  Future<void> respond(String requestId, {required bool accept}) async {
    final id = requestId.substring(2);
    calls.add('${accept ? 'accept' : 'decline'} $id');
    relation[id] = accept ? 'friend' : 'none';
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    final id = requestId.substring(2);
    calls.add('cancel $id');
    relation[id] = 'none';
  }

  @override
  Future<void> removeFriend(String userId) async {
    calls.add('remove $userId');
    relation[userId] = 'none';
  }

  @override
  Future<List<Person>> friends() async => [
    for (final id in people.keys)
      if (relation[id] == 'friend') _p(id),
  ];

  @override
  Future<({List<Person> received, List<Person> sent})> requests() async => (
    received: [
      for (final id in people.keys)
        if (relation[id] == 'received') _p(id),
    ],
    sent: [
      for (final id in people.keys)
        if (relation[id] == 'sent') _p(id),
    ],
  );

  @override
  Future<FriendProfile> profile(String userId) async => FriendProfile.fromJson({
    ..._p(userId).toJsonForTest(),
    if (relation[userId] == 'friend') 'listShared': shared.contains(userId),
  });

  @override
  Future<List<SharedItem>> sharedList(String userId) async {
    if (relation[userId] != 'friend' || !shared.contains(userId)) {
      throw FriendsException('This list is private.', 'list_not_shared');
    }
    return [
      SharedItem.fromJson({
        'number': 7,
        'title': 'Climb a volcano',
        'isCompleted': true,
      }),
    ];
  }

  @override
  ImageProvider photo(String userId, String path) => throw UnimplementedError();
}

extension on Person {
  Map<String, Object?> toJsonForTest() => {
    'userId': userId,
    'username': username,
    'displayName': displayName,
    'relation': relation.name,
    'requestId': requestId,
  };
}

void main() {
  late TestArchive device;
  late AppStore store;

  setUp(() async {
    device = await TestArchive.create();
    store = await device.open();
  });
  tearDown(() => device.dispose());

  Future<FakeFriends> pump(WidgetTester tester, {bool setUp = false}) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeFriends();
    if (setUp) {
      api.settings = const SharingSettings(username: 'me', displayName: 'Me');
    }
    final waiting = FriendRequestCount(api, every: null);
    addTearDown(waiting.dispose);
    await tester.pumpWidget(
      StoreScope(
        store: store,
        child: MaterialApp(
          home: FriendsScreen(api: api, waiting: waiting),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('first use: choose a username, everything private', (
    tester,
  ) async {
    final api = await pump(tester);
    expect(find.text('Share the journey with friends'), findsOneWidget);
    await tester.tap(find.text('Choose a username'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Username'),
      'Me_Too',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Name shown to others'),
      'Me Too',
    );
    await tester.tap(find.text('Save and continue'));
    await tester.pumpAndSettle();
    expect(api.calls, ['save me_too list=false']);
    expect(find.text('Requests'), findsOneWidget);
    expect(find.textContaining('No friends yet'), findsOneWidget);
  });

  testWidgets('find, add, accept, view a shared list, remove', (tester) async {
    final api = await pump(tester, setUp: true);

    // Find Bob and send a request.
    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'bo');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Bob B'), findsOneWidget);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('send bob'));
    expect(find.text('Requested'), findsOneWidget);

    // Carol's request: accept it.
    await tester.tap(find.text('Requests'));
    await tester.pumpAndSettle();
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('accept carol'));
    expect(find.text('You and Carol C are now friends.'), findsOneWidget);

    // Cancel the request to Bob (with confirmation).
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel request'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('cancel bob'));

    // Carol is a friend; her list is shared, read-only.
    await tester.tap(find.widgetWithText(Tab, 'Friends'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carol C'));
    await tester.pumpAndSettle();
    expect(find.text('Shared with friends · read-only'), findsOneWidget);
    await tester.tap(find.text('Bucket list'));
    await tester.pumpAndSettle();
    expect(find.text('Climb a volcano'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);

    // She makes it private: the next load says so.
    api.shared.clear();
    tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show();
    await tester.pumpAndSettle();
    expect(find.text('Carol C\'s list is private.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Remove her.
    await tester.tap(find.byType(PopupMenuButton<void>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove friend'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove friend'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('remove carol'));
    expect(
      find.text('Only friends see more of Carol C\'s profile.'),
      findsOneWidget,
    );
  });
}
