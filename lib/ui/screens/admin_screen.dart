import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/log.dart';
import '../../services/cloud/account.dart';
import '../feedback.dart';

/// Owner only: approve friends' emails and manage member accounts.
///
/// This never shows anyone's list, memories or photos — the owner role
/// doesn't give access to them. Every action is checked by the server.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _email = TextEditingController();
  SupabaseClient get _client => CloudConfig.client;
  late Future<(List<Map>, List<Map>)> _data = _load();
  var _busy = false;

  Future<(List<Map>, List<Map>)> _load() async {
    final members = (await _client.rpc('list_members') as List).cast<Map>();
    final invites = (await _client.rpc('list_invitations') as List).cast<Map>();
    return (members, invites);
  }

  void _reload() => setState(() => _data = _load());

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    final email = _email.text.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+$').hasMatch(email)) {
      showMessage(context, 'Please enter an email address.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _client.rpc(
        'create_invitation',
        params: {'p_email': email, 'p_valid_for': '14 days'},
      );
      _email.clear();
      if (mounted) {
        showMessage(
          context,
          'Approved. Ask them to open the website and create an account '
          'with $email within 14 days.',
        );
      }
      _reload();
    } on PostgrestException catch (e) {
      if (mounted) {
        showMessage(
          context,
          e.message == 'already_member'
              ? '$email already has an account here.'
              : 'That email couldn\'t be approved. Please check it.',
        );
      }
    } catch (e, s) {
      if (mounted) showError(context, e, s);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _setStatus(Map member, bool active) async {
    final email = member['email'];
    if (!active &&
        !await confirm(
          context,
          title: 'Disable $email?',
          message:
              'They can no longer open their list (from their next action '
              'on). Nothing is deleted, and you can enable them again.',
          confirmLabel: 'Disable',
          destructive: true,
        )) {
      return;
    }
    try {
      await _client.rpc(
        'set_member_status',
        params: {
          'p_user_id': member['user_id'],
          'p_status': active ? 'active' : 'disabled',
        },
      );
      _reload();
    } catch (e, s) {
      if (mounted) showError(context, e, s);
    }
  }

  Future<void> _revoke(Map invite) async {
    try {
      await _client.rpc(
        'revoke_invitation',
        params: {'p_invitation_id': invite['invitation_id']},
      );
      _reload();
    } catch (e, s) {
      logError('Revoke failed', e, s);
      if (mounted) showError(context, e, s);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Members and approvals')),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<(List<Map>, List<Map>)>(
          future: _data,
          builder: (context, snap) {
            final (members, invites) =
                snap.data ?? (const <Map>[], const <Map>[]);
            return ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'Approve a friend\'s email, then they create their own '
                    'account on the website with it. Their list is private '
                    'to them: you can\'t see it, and they can\'t see yours.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          onSubmitted: (_) => _approve(),
                          decoration: const InputDecoration(
                            labelText: 'Friend\'s email',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _busy ? null : _approve,
                        child: const Text('Approve'),
                      ),
                    ],
                  ),
                ),
                if (snap.hasError)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'The list couldn\'t be loaded. Pull down to try again.',
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                if (!snap.hasData && !snap.hasError)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (snap.hasData) ...[
                  _header(context, 'Members'),
                  for (final m in members)
                    ListTile(
                      leading: Icon(
                        m['role'] == 'owner'
                            ? Icons.star_rounded
                            : Icons.person_outline_rounded,
                      ),
                      title: Text('${m['email']}'),
                      subtitle: Text(
                        m['role'] == 'owner'
                            ? 'Owner'
                            : m['status'] == 'active'
                            ? 'Member since ${_date(m['created_at'])}'
                            : 'Disabled',
                      ),
                      trailing: m['role'] == 'owner'
                          ? null
                          : Switch(
                              value: m['status'] == 'active',
                              onChanged: (v) => _setStatus(m, v),
                            ),
                    ),
                  if (invites.any((i) => i['status'] != 'accepted')) ...[
                    _header(context, 'Approved emails'),
                    for (final i in invites.where(
                      (i) => i['status'] != 'accepted',
                    ))
                      ListTile(
                        leading: const Icon(Icons.mail_outline_rounded),
                        title: Text('${i['email']}'),
                        subtitle: Text(switch (i['status']) {
                          'pending' =>
                            'Waiting for sign-up · until ${_date(i['expires_at'])}',
                          'expired' => 'Expired — approve again',
                          _ => 'Withdrawn',
                        }),
                        trailing: i['status'] == 'pending'
                            ? TextButton(
                                onPressed: () => _revoke(i),
                                child: const Text('Withdraw'),
                              )
                            : null,
                      ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  static String _date(Object? iso) {
    final d = DateTime.tryParse('$iso')?.toLocal();
    return d == null ? '' : DateFormat.yMMMd().format(d);
  }

  Widget _header(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
