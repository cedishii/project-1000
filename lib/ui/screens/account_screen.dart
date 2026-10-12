import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/log.dart';
import '../../services/cloud/account.dart';
import '../../services/cloud/cloud_migration.dart';
import '../../services/cloud/synced_archive.dart';
import '../app.dart';
import '../feedback.dart';
import '../store_scope.dart';
import 'admin_screen.dart';
import 'connect_screen.dart';
import 'sign_in_screen.dart';

/// The cloud account: who is signed in, which archive this device uses,
/// copying the phone's archive, password, sign-out and (for the owner)
/// managing members.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _account = Account(CloudConfig.client);
  Future<Membership>? _membership;
  Map<String, Object?>? _migration;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _membership = _account.isSignedIn ? _account.membership() : null;
    });
    final store = StoreScope.read(context);
    if (store.isLocal) {
      CloudMigration.lastState(store.location).then((s) {
        if (mounted) setState(() => _migration = s);
      });
    }
  }

  Future<void> _signIn() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            SignInScreen(onDone: () async => Navigator.pop(context)),
      ),
    );
    if (!mounted) return;
    _refresh();
    // Signed in on a phone with its own list: offer to connect the two
    // right away (nothing is sent without the user's choice).
    if (!kIsWeb && _account.isSignedIn && StoreScope.read(context).isLocal) {
      final m = await _membership;
      if (m is ActiveMember && mounted) await _connect();
    }
  }

  Future<void> _connect() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ConnectScreen()),
    );
    if (mounted) _refresh();
  }

  Future<void> _useCloud(bool cloud) async {
    if (cloud) {
      final copied =
          _migration?['status'] == 'verified' &&
          _migration?['userId'] == _account.user?.id;
      final ok = await confirm(
        context,
        title: 'Use your account on this phone?',
        message: copied
            ? 'This phone will show the list in your account, the same as '
                  'on the website. This phone\'s own archive stays here, '
                  'untouched, and you can switch back any time.'
            : 'Your account doesn\'t have a verified copy of this phone\'s '
                  'list yet. You\'ll see whatever is in your account (perhaps '
                  'nothing). This phone\'s own archive stays here, untouched, '
                  'and you can switch back any time.',
        confirmLabel: 'Use my account',
      );
      if (!ok || !mounted) return;
    }
    await DeviceMode(await getApplicationDocumentsDirectory())
        .setUsesCloud(cloud);
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await AppRestart.of(context);
  }

  Future<void> _signOut() async {
    final store = StoreScope.read(context);
    final pending = store.syncStatus?.value.pending ?? 0;
    final it = pending == 1 ? 'it' : 'them';
    final ok = await confirm(
      context,
      title: 'Sign out?',
      message: kIsWeb
          ? 'You can sign in again any time. Your list stays in your account.'
          : pending > 0
          ? "${pending == 1 ? '1 change' : '$pending changes'} made on this "
                "phone haven't reached your account yet (no connection). "
                'Signing out now loses $it. Connect to the internet first '
                'to keep $it.'
          : "This phone will go back to its own archive. Your account's list "
                'stays in your account.',
      confirmLabel: pending > 0 ? 'Sign out anyway' : 'Sign out',
      destructive: pending > 0,
    );
    if (!ok || !mounted) return;
    try {
      await _account.signOut();
    } catch (e, s) {
      logError('Sign-out failed', e, s);
    }
    if (!mounted) return;
    if (kIsWeb) {
      await AppRestart.of(context);
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    await DeviceMode(dir).setUsesCloud(false);
    if (!store.isLocal && mounted) {
      // Back to the phone's own archive (this also closes the copy).
      await AppRestart.of(context);
    }
    // The account's copy doesn't stay on the phone after signing out.
    await SyncedArchive.deleteAll(dir);
    if (mounted && store.isLocal) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: !_account.isSignedIn
          ? _signedOut(context)
          : FutureBuilder<Membership>(
              future: _membership,
              builder: (context, snap) {
                if (snap.hasError) {
                  return _Message(
                    'Your account couldn\'t be reached. Check your connection.',
                    action: TextButton(
                      onPressed: _refresh,
                      child: const Text('Try again'),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final m = snap.data!;
                return ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    ListTile(
                      leading: const Icon(Icons.account_circle_outlined),
                      title: Text(_account.email ?? ''),
                      subtitle: Text(switch (m) {
                        ActiveMember(isOwner: true) => 'Owner',
                        ActiveMember() => 'Member',
                        Disabled() => 'Disabled by the owner',
                        NotApproved() => 'Not approved yet — ask the owner',
                      }),
                    ),
                    if (!kIsWeb && m is ActiveMember) ...[
                      const _Header('This phone'),
                      if (store.isLocal) ...[
                        ListTile(
                          leading: const Icon(Icons.cloud_sync_outlined),
                          title: const Text('Connect this phone to my account'),
                          subtitle: Text(
                            _migration?['status'] == 'verified'
                                ? 'Copied and checked · use the same list '
                                      'as the website'
                                : 'Bring this phone\'s list into your account '
                                      'and use the same list as the website. '
                                      'Shows what will happen first.',
                          ),
                          onTap: _connect,
                        ),
                      ] else
                        ListTile(
                          leading: const Icon(Icons.phone_android_outlined),
                          title: const Text('Use this phone\'s own archive'),
                          subtitle: const Text(
                            'Switch back to the list stored on this phone',
                          ),
                          onTap: () => _useCloud(false),
                        ),
                    ],
                    if (m case ActiveMember(isOwner: true)) ...[
                      const _Header('Owner'),
                      ListTile(
                        leading: const Icon(Icons.group_outlined),
                        title: const Text('Members and approvals'),
                        subtitle: const Text(
                          'Approve friends\' emails, disable accounts',
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const AdminScreen(),
                          ),
                        ),
                      ),
                    ],
                    const _Header('Sign-in'),
                    ListTile(
                      leading: const Icon(Icons.password_rounded),
                      title: const Text('Change password'),
                      onTap: () => showChangePassword(context),
                    ),
                    ListTile(
                      leading: const Icon(Icons.logout_rounded),
                      title: const Text('Sign out'),
                      onTap: _signOut,
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _signedOut(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        'With a Project: 1000 account you can use your list on the '
        'website too, from any computer or phone.',
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: 12),
      const Text(
        'This is optional. Without an account, everything stays on this '
        'phone only, exactly as before. Signing in doesn\'t change or upload '
        'anything by itself: you choose if and when to copy your list.',
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _signIn,
        child: const Text('Sign in or create an account'),
      ),
    ],
  );
}

/// Asks for a new password and saves it.
Future<void> showChangePassword(
  BuildContext context, {
  String title = 'Change password',
}) async {
  final controller = TextEditingController();
  String? error;
  var busy = false;
  final changed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(
            labelText: 'New password',
            helperText: 'At least $minPasswordLength characters',
            errorText: error,
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    if (controller.text.length < minPasswordLength) {
                      setState(
                        () => error =
                            'At least $minPasswordLength characters, please',
                      );
                      return;
                    }
                    setState(() => busy = true);
                    try {
                      await Account(CloudConfig.client)
                          .changePassword(controller.text);
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e, s) {
                      logError('Password change failed', e, s);
                      setState(() {
                        busy = false;
                        error = authMessage(e);
                      });
                    }
                  },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  if (changed == true && context.mounted) {
    showMessage(context, 'Your password was changed.');
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          ?action,
        ],
      ),
    ),
  );
}
