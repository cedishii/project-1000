import 'package:flutter/material.dart';

import '../../services/cloud/account.dart';
import '../../services/cloud/friends.dart';
import '../layout.dart';
import 'friends_screen.dart';
import 'home_screen.dart';

/// Signed in to an account: the list and Friends, as two tabs (a bar at
/// the bottom on phones, a rail at the side on wide screens). The
/// phone's own archive has no Friends and shows [HomeScreen] alone.
class MainTabs extends StatefulWidget {
  const MainTabs({super.key, this.api});

  /// For tests; the signed-in account otherwise.
  final FriendsApi? api;

  @override
  State<MainTabs> createState() => _MainTabsState();
}

class _MainTabsState extends State<MainTabs> with WidgetsBindingObserver {
  late final FriendsApi _api =
      widget.api ?? SupabaseFriendsApi(CloudConfig.client);
  late final _waiting = FriendRequestCount(_api);
  var _tab = 0;

  /// Friends is built the first time it is opened (no requests before).
  var _friendsOpened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _waiting.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _waiting.dispose();
    super.dispose();
  }

  void _select(int i) => setState(() {
    _tab = i;
    if (i == 1) {
      _friendsOpened = true;
      _waiting.refresh();
    }
  });

  Widget _friendsIcon(bool selected) => ValueListenableBuilder<int>(
    valueListenable: _waiting,
    builder: (context, n, _) => Badge(
      isLabelVisible: n > 0,
      label: Text('$n'),
      child: Icon(
        selected ? Icons.people_alt_rounded : Icons.people_alt_outlined,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final body = IndexedStack(
      index: _tab,
      children: [
        const HomeScreen(),
        if (_friendsOpened)
          ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: readableWidth),
                child: FriendsScreen(api: _api, waiting: _waiting),
              ),
            ),
          )
        else
          const SizedBox.shrink(),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 700) {
          return Row(
            children: [
              NavigationRail(
                selectedIndex: _tab,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  const NavigationRailDestination(
                    icon: Icon(Icons.checklist_rounded),
                    label: Text('My list'),
                  ),
                  NavigationRailDestination(
                    icon: _friendsIcon(false),
                    selectedIcon: _friendsIcon(true),
                    label: const Text('Friends'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _select,
            height: 64,
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.checklist_rounded),
                label: 'My list',
              ),
              NavigationDestination(
                icon: _friendsIcon(false),
                selectedIcon: _friendsIcon(true),
                label: 'Friends',
              ),
            ],
          ),
        );
      },
    );
  }
}
