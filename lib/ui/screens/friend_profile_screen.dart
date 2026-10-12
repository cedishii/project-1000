import 'package:flutter/material.dart';

import '../../data/models.dart' show maxItems;
import '../../services/cloud/friends.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../theme.dart';
import '../widgets/level_widgets.dart';
import 'friend_list_screen.dart';
import 'friends_screen.dart';

/// Someone's profile, as the server lets the user see it: who they are
/// for anyone, plus what they chose to share for friends. Pops with true
/// if the friendship changed.
class FriendProfileScreen extends StatefulWidget {
  const FriendProfileScreen({
    super.key,
    required this.api,
    required this.person,
  });

  final FriendsApi api;
  final Person person;

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  late Future<FriendProfile> _profile = widget.api.profile(
    widget.person.userId,
  );
  var _changed = false;
  var _busy = false;

  void _reload() => setState(() {
    _profile = widget.api.profile(widget.person.userId);
  });

  Future<void> _act(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      _changed = true;
      if (mounted) showMessage(context, done);
    } catch (e, s) {
      if (mounted) showFriendsError(context, e, s);
    }
    if (mounted) {
      setState(() => _busy = false);
      _reload();
    }
  }

  Future<void> _remove(Person p) async {
    final ok = await confirm(
      context,
      title: 'Remove ${p.displayName}?',
      message:
          'You\'ll no longer see what each other shares with friends. '
          'They aren\'t told, and you can send a new request later.',
      confirmLabel: 'Remove friend',
      destructive: true,
    );
    if (ok) {
      await _act(
        () => widget.api.removeFriend(p.userId),
        '${p.displayName} removed from your friends.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: FutureBuilder<FriendProfile>(
        future: _profile,
        builder: (context, snap) {
          final profile = snap.data;
          final p = profile?.person ?? widget.person;
          return Scaffold(
            appBar: AppBar(
              title: Text(p.displayName),
              actions: [
                if (p.relation == Relation.friend)
                  PopupMenuButton<void>(
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        onTap: () => _remove(p),
                        child: const Text('Remove friend'),
                      ),
                    ],
                  ),
              ],
            ),
            body: snap.hasError
                ? ErrorRetry(error: snap.error!, onRetry: _reload)
                : profile == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                    children: [
                      _Header(api: widget.api, profile: profile),
                      const SizedBox(height: 16),
                      Center(child: _relationAction(p)),
                      const SizedBox(height: 16),
                      ..._shared(context, profile),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _relationAction(Person p) {
    if (_busy) return const CircularProgressIndicator();
    return switch (p.relation) {
      Relation.none => FilledButton.icon(
        onPressed: () => _act(
          () => widget.api.sendRequest(p.userId),
          'Friend request sent to ${p.displayName}.',
        ),
        icon: const Icon(Icons.person_add_alt_rounded),
        label: const Text('Add friend'),
      ),
      Relation.sent => OutlinedButton(
        onPressed: () => _act(
          () => widget.api.cancelRequest(p.requestId!),
          'Request cancelled.',
        ),
        child: const Text('Requested · Cancel'),
      ),
      Relation.received => Wrap(
        spacing: 12,
        children: [
          OutlinedButton(
            onPressed: () => _act(
              () => widget.api.respond(p.requestId!, accept: false),
              'Request declined.',
            ),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () => _act(
              () => widget.api.respond(p.requestId!, accept: true),
              'You and ${p.displayName} are now friends.',
            ),
            child: const Text('Accept'),
          ),
        ],
      ),
      Relation.friend => const Chip(
        avatar: Icon(Icons.people_alt_rounded, size: 18),
        label: Text('Friends'),
      ),
      Relation.self => const Chip(label: Text('This is how friends see you')),
    };
  }

  List<Widget> _shared(BuildContext context, FriendProfile f) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final rel = f.person.relation;
    if (rel != Relation.friend && rel != Relation.self) {
      return [
        Text(
          'Only friends see more of ${f.person.displayName}\'s profile.',
          style: muted,
          textAlign: TextAlign.center,
        ),
      ];
    }
    final level = f.level, completed = f.completed;
    return [
      if (f.bio != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Text(
            f.bio!,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
            textAlign: TextAlign.center,
          ),
        ),
      if (f.startedOn != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            'Started ${longDate(f.startedOn!)}',
            style: muted,
            textAlign: TextAlign.center,
          ),
        ),
      if (level != null || completed != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (level != null) ...[
                  LevelNumber(level: level, size: 48),
                  const SizedBox(width: 20),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (f.exp != null)
                        Text('${count(f.exp!)} EXP', style: display(18)),
                      if (completed != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${count(completed)} of ${count(maxItems)} things done'
                          '${f.listed == null ? '' : ' · ${count(f.listed!)} listed'}',
                        ),
                        const SizedBox(height: 8),
                        LevelBar(value: completed / maxItems, height: 8),
                      ],
                      if ((f.journeysFinished ?? 0) > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          '${plural(f.journeysFinished!, 'journey', 'journeys')} '
                          'finished',
                          style: muted,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 8),
      Card(
        child: ListTile(
          leading: Icon(
            f.listShared ? Icons.checklist_rounded : Icons.lock_outline_rounded,
          ),
          title: const Text('Bucket list'),
          subtitle: Text(
            f.listShared
                ? 'Shared with friends · read-only'
                : rel == Relation.self
                ? 'Private: friends can\'t see it'
                : 'Private',
          ),
          trailing: f.listShared
              ? const Icon(Icons.chevron_right_rounded)
              : null,
          onTap: f.listShared
              ? () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        FriendListScreen(api: widget.api, person: f.person),
                  ),
                )
              : null,
        ),
      ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.api, required this.profile});

  final FriendsApi api;
  final FriendProfile profile;

  @override
  Widget build(BuildContext context) {
    final p = profile.person;
    final photo = p.photo;
    return Column(
      children: [
        PersonAvatar(
          name: p.displayName,
          image: photo == null ? null : api.photo(p.userId, photo),
          size: 104,
        ),
        const SizedBox(height: 12),
        Text(p.displayName, style: display(26), textAlign: TextAlign.center),
        Text(
          '@${p.username}',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
