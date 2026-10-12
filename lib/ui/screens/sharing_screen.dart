import 'package:flutter/material.dart';

import '../../services/cloud/account.dart';
import '../../services/cloud/friends.dart';
import '../backup_flows.dart' show showProgressDialog;
import '../feedback.dart';
import '../store_scope.dart';
import 'friend_profile_screen.dart';
import 'friends_screen.dart';

/// The user's username and what friends may see. Everything is off until
/// turned on; memories and their photos are never shared. Changes apply
/// on the server at once, for every friend. Pops with true when saved.
class SharingScreen extends StatefulWidget {
  const SharingScreen({super.key, required this.api, required this.current});

  final FriendsApi api;

  /// Null on first use (choosing a username).
  final SharingSettings? current;

  @override
  State<SharingScreen> createState() => _SharingScreenState();
}

class _SharingScreenState extends State<SharingScreen> {
  late final _username = TextEditingController(text: widget.current?.username);
  late final _name = TextEditingController(text: widget.current?.displayName);
  late var _photo = widget.current?.showPhoto ?? false;
  late var _bio = widget.current?.showBio ?? false;
  late var _started = widget.current?.showStartedOn ?? false;
  late var _stats = widget.current?.showStats ?? false;
  late var _level = widget.current?.showLevel ?? false;
  late var _list = widget.current?.listShared ?? false;
  var _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_name.text.isEmpty) {
      _name.text = StoreScope.read(context).profile.displayName;
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _name.dispose();
    super.dispose();
  }

  SharingSettings get _settings => SharingSettings(
    username: _username.text.trim().replaceFirst('@', '').toLowerCase(),
    displayName: _name.text.trim(),
    showPhoto: _photo,
    showBio: _bio,
    showStartedOn: _started,
    showStats: _stats,
    showLevel: _level,
    listShared: _list,
  );

  Future<void> _save() async {
    final s = _settings;
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(s.username)) {
      setState(
        () => _error =
            'Usernames are 3–20 lowercase letters, numbers or underscores.',
      );
      return;
    }
    if (s.displayName.isEmpty) {
      setState(() => _error = 'Please enter a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.saveSettings(s);
      if (!mounted) return;
      showMessage(
        context,
        widget.current == null
            ? 'You\'re @${s.username}. Friends can find you now.'
            : 'Saved. Friends see the change right away.',
      );
      Navigator.pop(context, true);
    } on FriendsException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e, s) {
      if (mounted) showError(context, e, s);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _leave() async {
    final ok = await confirm(
      context,
      title: 'Stop using Friends?',
      message:
          'Your username, all your friendships and requests are removed, '
          'and nobody can find you. Your own list, memories and progress '
          'stay exactly as they are.',
      confirmLabel: 'Stop using Friends',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.leave();
      if (!mounted) return;
      showMessage(context, 'You no longer use Friends.');
      Navigator.pop(context, true);
    } catch (e, s) {
      if (mounted) {
        showFriendsError(context, e, s);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = StoreScope.of(context).profile;
    final first = widget.current == null;
    Widget toggle(
      String title,
      String subtitle,
      bool value,
      ValueChanged<bool> onChanged,
    ) => SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: _busy ? null : (v) => setState(() => onChanged(v)),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(first ? 'Choose a username' : 'Privacy and sharing'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _username,
              autocorrect: false,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixText: '@',
                helperText: 'How friends find you. Letters, numbers, _',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _name,
              enabled: !_busy,
              maxLength: 60,
              decoration: const InputDecoration(
                labelText: 'Name shown to others',
              ),
            ),
          ),
          const SectionHeader('Bucket list'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.lock_outline_rounded),
                  label: Text('Private'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.people_alt_outlined),
                  label: Text('Friends only'),
                ),
              ],
              selected: {_list},
              onSelectionChanged: _busy
                  ? null
                  : (s) => setState(() => _list = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              _list
                  ? 'Friends can see your current list: titles, notes and '
                        'what you\'ve done. They can\'t change anything.'
                  : 'Only you can see your list.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SectionHeader('Profile'),
          toggle(
            'Profile photo',
            profile.photo == null
                ? 'You have no photo yet'
                : 'Shown in search and to friends',
            _photo,
            (v) => _photo = v,
          ),
          toggle(
            'Bio',
            profile.bio.isEmpty ? 'Your bio is empty' : 'Shown to friends',
            _bio,
            (v) => _bio = v,
          ),
          toggle(
            'Start date',
            profile.startedOn == null
                ? 'You haven\'t set one'
                : 'When you began, shown to friends',
            _started,
            (v) => _started = v,
          ),
          toggle(
            'Progress',
            'Things done and listed, shown to friends',
            _stats,
            (v) => _stats = v,
          ),
          toggle(
            'Level and EXP',
            'Shown to friends',
            _level,
            (v) => _level = v,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              'Your memories, their photos, your age and your journey '
              'history are never shared.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(first ? 'Save and continue' : 'Save'),
            ),
          ),
          if (!first) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => FriendProfileScreen(
                            api: widget.api,
                            person: Person.fromJson({
                              'userId': widget.api.myUserId,
                              'username': widget.current!.username,
                              'displayName': widget.current!.displayName,
                              'relation': 'self',
                            }),
                          ),
                        ),
                      ),
                child: const Text('Preview what friends see (as saved)'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: TextButton(
                onPressed: _busy ? null : _leave,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                child: const Text('Stop using Friends'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Opens [SharingScreen] for the signed-in account (from Settings).
Future<void> openSharingSettings(BuildContext context) async {
  final api = SupabaseFriendsApi(CloudConfig.client);
  final close = showProgressDialog(context, 'Loading…');
  try {
    final current = await api.mySettings();
    close();
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SharingScreen(api: api, current: current),
      ),
    );
  } catch (e, s) {
    close();
    if (context.mounted) showFriendsError(context, e, s);
  }
}
