import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/cloud/friends.dart';
import '../feedback.dart';
import '../theme.dart';
import '../widgets/level_widgets.dart';
import 'friend_profile_screen.dart';
import 'sharing_screen.dart';

/// Friends: your friends, requests waiting for you or sent by you, and
/// finding people by username or name. Nobody can find you until you
/// choose a username, and friends see only what you share (see
/// [SharingScreen]). Every rule is enforced by the server.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key, required this.api, required this.waiting});

  final FriendsApi api;

  /// Requests waiting for the user (the tab's badge).
  final FriendRequestCount waiting;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  late Future<SharingSettings?> _settings = widget.api.mySettings();

  /// Bumped after every action, so every tab reloads.
  int _version = 0;

  void _reloadSettings() => setState(() {
    _settings = widget.api.mySettings();
  });

  void _changed() {
    setState(() => _version++);
    widget.waiting.refresh();
  }

  Future<void> _openSharing(SharingSettings? current) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SharingScreen(api: widget.api, current: current),
      ),
    );
    if (saved == true && mounted) {
      _reloadSettings();
      _changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharingSettings?>(
      future: _settings,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: AppBar(title: const Text('Friends')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Friends')),
            body: ErrorRetry(error: snap.error!, onRetry: _reloadSettings),
          );
        }
        final settings = snap.data;
        if (settings == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Friends')),
            body: _Welcome(onStart: () => _openSharing(null)),
          );
        }
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Friends'),
              actions: [
                IconButton(
                  tooltip: 'Privacy and sharing',
                  icon: const Icon(Icons.shield_outlined),
                  onPressed: () => _openSharing(settings),
                ),
              ],
              bottom: TabBar(
                tabs: [
                  const Tab(text: 'Friends'),
                  Tab(
                    child: ValueListenableBuilder<int>(
                      valueListenable: widget.waiting,
                      builder: (context, n, _) => Badge(
                        isLabelVisible: n > 0,
                        label: Text('$n'),
                        offset: const Offset(14, -4),
                        child: const Text('Requests'),
                      ),
                    ),
                  ),
                  const Tab(text: 'Find'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                _FriendsTab(
                  key: ValueKey('friends$_version'),
                  api: widget.api,
                  onChanged: _changed,
                ),
                _RequestsTab(
                  key: ValueKey('requests$_version'),
                  api: widget.api,
                  onChanged: _changed,
                ),
                _FindTab(api: widget.api, onChanged: _changed),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------- first run

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
      children: [
        Icon(
          Icons.people_alt_outlined,
          size: 64,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Share the journey with friends',
          style: display(22),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        const Text(
          'Choose a username so friends can find you. You decide what they '
          'see: your list and your memories stay private until you share '
          'them.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Center(
          child: FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.alternate_email_rounded),
            label: const Text('Choose a username'),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- friends

class _FriendsTab extends StatefulWidget {
  const _FriendsTab({super.key, required this.api, required this.onChanged});

  final FriendsApi api;
  final VoidCallback onChanged;

  @override
  State<_FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<_FriendsTab> {
  late Future<List<Person>> _friends = widget.api.friends();

  Future<void> _reload() async {
    final next = widget.api.friends();
    setState(() {
      _friends = next;
    });
    await next.catchError((Object _) => <Person>[]);
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _reload,
      child: FutureBuilder<List<Person>>(
        future: _friends,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorRetry(error: snap.error!, onRetry: _reload);
          }
          final friends = snap.data;
          if (friends == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (friends.isEmpty) {
            return const EmptyHint(
              icon: Icons.people_outline_rounded,
              text:
                  'No friends yet. Find people by their username or name '
                  'under Find.',
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final f in friends)
                PersonTile(
                  api: widget.api,
                  person: f,
                  onTap: () => openPerson(
                    context,
                    widget.api,
                    f,
                    onChanged: widget.onChanged,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// --------------------------------------------------------------- requests

class _RequestsTab extends StatefulWidget {
  const _RequestsTab({super.key, required this.api, required this.onChanged});

  final FriendsApi api;
  final VoidCallback onChanged;

  @override
  State<_RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<_RequestsTab> {
  late Future<({List<Person> received, List<Person> sent})> _requests = widget
      .api
      .requests();
  final _busy = <String>{};

  Future<void> _reload() async {
    final next = widget.api.requests();
    setState(() {
      _requests = next;
    });
    await next.catchError(
      (Object _) => (received: <Person>[], sent: <Person>[]),
    );
  }

  Future<void> _act(
    Person p,
    Future<void> Function() action,
    String done,
  ) async {
    setState(() => _busy.add(p.userId));
    try {
      await action();
      if (mounted) showMessage(context, done);
      widget.onChanged();
    } catch (e, s) {
      if (mounted) showFriendsError(context, e, s);
      _reload();
    }
    if (mounted) setState(() => _busy.remove(p.userId));
  }

  Future<void> _cancel(Person p) async {
    final ok = await confirm(
      context,
      title: 'Cancel request?',
      message: '${p.displayName} won\'t see your request any more.',
      confirmLabel: 'Cancel request',
    );
    if (ok) {
      await _act(
        p,
        () => widget.api.cancelRequest(p.requestId!),
        'Request to ${p.displayName} cancelled.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _reload,
      child: FutureBuilder(
        future: _requests,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorRetry(error: snap.error!, onRetry: _reload);
          }
          final r = snap.data;
          if (r == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (r.received.isEmpty && r.sent.isEmpty) {
            return const EmptyHint(
              icon: Icons.mark_email_read_outlined,
              text: 'No requests waiting.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (r.received.isNotEmpty) ...[
                const SectionHeader('Received'),
                for (final p in r.received)
                  PersonTile(
                    api: widget.api,
                    person: p,
                    onTap: () => openPerson(
                      context,
                      widget.api,
                      p,
                      onChanged: widget.onChanged,
                    ),
                    trailing: _busy.contains(p.userId)
                        ? const _Spinner()
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Decline',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () => _act(
                                  p,
                                  () => widget.api.respond(
                                    p.requestId!,
                                    accept: false,
                                  ),
                                  'Request from ${p.displayName} declined.',
                                ),
                              ),
                              FilledButton(
                                onPressed: () => _act(
                                  p,
                                  () => widget.api.respond(
                                    p.requestId!,
                                    accept: true,
                                  ),
                                  'You and ${p.displayName} are now friends.',
                                ),
                                child: const Text('Accept'),
                              ),
                            ],
                          ),
                  ),
              ],
              if (r.sent.isNotEmpty) ...[
                const SectionHeader('Sent'),
                for (final p in r.sent)
                  PersonTile(
                    api: widget.api,
                    person: p,
                    subtitle: '@${p.username} · waiting',
                    onTap: () => openPerson(
                      context,
                      widget.api,
                      p,
                      onChanged: widget.onChanged,
                    ),
                    trailing: _busy.contains(p.userId)
                        ? const _Spinner()
                        : TextButton(
                            onPressed: () => _cancel(p),
                            child: const Text('Cancel'),
                          ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------------- find

class _FindTab extends StatefulWidget {
  const _FindTab({required this.api, required this.onChanged});

  final FriendsApi api;
  final VoidCallback onChanged;

  @override
  State<_FindTab> createState() => _FindTabState();
}

class _FindTabState extends State<_FindTab> with AutomaticKeepAliveClientMixin {
  final _query = TextEditingController();
  Timer? _debounce;
  Future<List<Person>>? _results;
  final _busy = <String>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  void _search() {
    final q = _query.text.trim();
    setState(() {
      _results = q.replaceFirst('@', '').length < 2
          ? null
          : widget.api.search(q);
    });
  }

  Future<void> _act(
    Person p,
    Future<void> Function() action,
    String done,
  ) async {
    setState(() => _busy.add(p.userId));
    try {
      await action();
      if (mounted) showMessage(context, done);
      widget.onChanged();
    } catch (e, s) {
      if (mounted) showFriendsError(context, e, s);
    }
    if (mounted) {
      setState(() => _busy.remove(p.userId));
      _search();
    }
  }

  Widget _action(Person p) {
    if (_busy.contains(p.userId)) return const _Spinner();
    return switch (p.relation) {
      Relation.friend => const Chip(label: Text('Friends')),
      Relation.sent => TextButton(
        onPressed: () async {
          final ok = await confirm(
            context,
            title: 'Cancel request?',
            message: '${p.displayName} won\'t see your request any more.',
            confirmLabel: 'Cancel request',
          );
          if (ok) {
            await _act(
              p,
              () => widget.api.cancelRequest(p.requestId!),
              'Request cancelled.',
            );
          }
        },
        child: const Text('Requested'),
      ),
      Relation.received => FilledButton(
        onPressed: () => _act(
          p,
          () => widget.api.respond(p.requestId!, accept: true),
          'You and ${p.displayName} are now friends.',
        ),
        child: const Text('Accept'),
      ),
      Relation.none => FilledButton.tonalIcon(
        onPressed: () => _act(
          p,
          () => widget.api.sendRequest(p.userId),
          'Friend request sent to ${p.displayName}.',
        ),
        icon: const Icon(Icons.person_add_alt_rounded, size: 18),
        label: const Text('Add'),
      ),
      Relation.self => const SizedBox.shrink(),
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _query,
            onChanged: _onChanged,
            onSubmitted: (_) => _search(),
            autocorrect: false,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Username or name',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        if (_results == null)
          const EmptyHint(
            icon: Icons.person_search_outlined,
            text:
                'Type at least two letters. Only people who chose a '
                'username can be found.',
          )
        else
          FutureBuilder<List<Person>>(
            future: _results,
            builder: (context, snap) {
              if (snap.hasError) {
                return ErrorRetry(error: snap.error!, onRetry: _search);
              }
              final people = snap.data;
              if (people == null) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (people.isEmpty) {
                return const EmptyHint(
                  icon: Icons.search_off_rounded,
                  text: 'Nobody found.',
                );
              }
              return Column(
                children: [
                  for (final p in people)
                    PersonTile(
                      api: widget.api,
                      person: p,
                      trailing: _action(p),
                      onTap: () => openPerson(
                        context,
                        widget.api,
                        p,
                        onChanged: () {
                          widget.onChanged();
                          _search();
                        },
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- shared

/// Opens [person]'s profile; [onChanged] runs if the friendship changed.
Future<void> openPerson(
  BuildContext context,
  FriendsApi api,
  Person person, {
  required VoidCallback onChanged,
}) async {
  final changed = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (_) => FriendProfileScreen(api: api, person: person),
    ),
  );
  if (changed == true) onChanged();
}

class PersonTile extends StatelessWidget {
  const PersonTile({
    super.key,
    required this.api,
    required this.person,
    required this.onTap,
    this.trailing,
    this.subtitle,
  });

  final FriendsApi api;
  final Person person;
  final VoidCallback onTap;
  final Widget? trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final photo = person.photo;
    return ListTile(
      onTap: onTap,
      leading: PersonAvatar(
        name: person.displayName,
        image: photo == null ? null : api.photo(person.userId, photo),
        size: 44,
      ),
      title: Text(
        person.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle ?? '@${person.username}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing,
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A scrollable, so pull-to-refresh works on an empty tab too.
    return ListView(
      shrinkWrap: true,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
      children: [
        Icon(icon, size: 48, color: scheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
    children: [
      Icon(
        Icons.cloud_off_outlined,
        size: 48,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(height: 12),
      Text(
        error is FriendsException
            ? '$error'
            : 'Something went wrong. Please try again.',
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 16),
      Center(
        child: OutlinedButton(
          onPressed: onRetry,
          child: const Text('Try again'),
        ),
      ),
    ],
  );
}

/// Shows a friends error (already in plain words) as a snackbar.
void showFriendsError(BuildContext context, Object error, [StackTrace? s]) {
  if (error is FriendsException) {
    showMessage(context, error.message);
  } else {
    showError(context, error, s);
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(12),
    child: SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}
