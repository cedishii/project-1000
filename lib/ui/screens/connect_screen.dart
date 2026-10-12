import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:project_1000/core/log.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../services/backup/backup_bytes.dart';
import '../../services/backup/export_service.dart' show ExportResult;
import '../../services/cloud/account.dart';
import '../../services/cloud/cloud_backup.dart';
import '../../services/cloud/cloud_migration.dart';
import '../../services/cloud/supabase_migration_api.dart';
import '../app.dart';
import '../backup_flows.dart' show shareFiles;
import '../cloud_backup_flows.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../theme.dart';

/// Connects this phone's own list to the signed-in account, so the phone
/// and the website show the same list.
///
/// It looks at both sides first and offers only what is safe:
/// * the account is empty → copy this phone's list into it exactly;
/// * the account already has everything → just use it;
/// * both have different things → a preview of the merge (nothing in the
///   account is removed or overwritten), or use the account without
///   copying.
///
/// Before anything is sent, a backup of this phone's list is saved on the
/// phone. The phone's own archive is never changed: signing out later
/// brings it back. Every step can be repeated without duplicates.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _backup = CloudBackup(CloudConfig.client);
  Map<String, Object?>? _local;
  MergeSummary? _preview;
  String? _conflict;
  String? _error;
  String? _working;
  var _matchTitles = true;
  File? _safetyCopy;

  /// After copying: true when the account's copy was read back and checked.
  bool? _verified;
  String _details = '';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _working = 'Comparing this phone with your account…';
      _error = null;
      _conflict = null;
      _preview = null;
    });
    try {
      final local = _local ??= await StoreScope.read(context).archiveSnapshot();
      final preview = await _backup.preview(local, matchTitles: _matchTitles);
      if (mounted) setState(() => _preview = preview);
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() {
          if (e.message == 'history_conflict' || e.message == 'list_full') {
            _conflict = mergeProblem(e).replaceAll('this backup', 'this phone');
          } else {
            _error = mergeProblem(e);
          }
        });
      }
    } catch (e, s) {
      logError('Connect: comparing failed', e, s);
      if (mounted) setState(() => _error = mergeProblem(e));
    }
    if (mounted) setState(() => _working = null);
  }

  /// A backup of this phone's list, kept on the phone, before anything is
  /// sent (one: the newest replaces the previous one).
  Future<void> _saveSafetyCopy() async {
    final store = StoreScope.read(context);
    final info = await PackageInfo.fromPlatform();
    final dir = Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'safety_backup'),
    );
    final ExportResult r = await store.exportBackup(
      dir,
      '${info.version}+${info.buildNumber}',
    );
    _safetyCopy = r.file;
  }

  Future<void> _run({required bool exactCopy}) async {
    final store = StoreScope.read(context);
    setState(() {
      _working = 'Saving a backup of this phone first…';
      _error = null;
    });
    try {
      await _saveSafetyCopy();
      if (exactCopy) {
        // The account is empty: copy exactly and compare record by record.
        final report = await CloudMigration(
          location: store.location,
          snapshot: store.archiveSnapshot,
          api: SupabaseMigrationApi(CloudConfig.client),
        ).run(onProgress: (pr) => _progress(pr.stage.name, pr.done, pr.total));
        _verified = report.verified;
        _details = [
          if (report.missingOnPhone.isNotEmpty)
            '${plural(report.missingOnPhone.length, 'photo file')} were '
                'already missing on this phone.',
          if (!report.verified)
            '${plural(report.missingInCloud.length + report.differences.length, 'record')} '
                'didn\'t arrive yet.',
        ].join(' ');
      } else {
        final result = await _backup.merge(
          _local!,
          matchTitles: _matchTitles,
          readFile: (path) async {
            final f = File(store.location.resolve(path));
            return await f.exists() ? f.readAsBytes() : null;
          },
          onProgress: _progress,
        );
        _verified = result.verified;
        _preview = result.summary;
        _details = [
          if (result.missingInFile.isNotEmpty)
            '${plural(result.missingInFile.length, 'photo file')} were '
                'already missing on this phone.',
          if (!result.verified)
            '${plural(result.missingInCloud.length, 'file')} didn\'t arrive yet.',
        ].join(' ');
      }
    } catch (e, s) {
      logError('Connect failed', e, s);
      if (mounted) setState(() => _error = mergeProblem(e));
    }
    if (mounted) setState(() => _working = null);
  }

  void _progress(String stage, int done, int total) {
    if (!mounted) return;
    setState(
      () => _working = switch (stage) {
        'photos' => 'Uploading photos… $done of $total',
        'verifying' => 'Checking your account…',
        'done' => 'Done',
        _ => 'Copying your list…',
      },
    );
  }

  Future<void> _useAccount() async {
    await DeviceMode(await getApplicationDocumentsDirectory())
        .setUsesCloud(true);
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await AppRestart.of(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _working == null,
      child: Scaffold(
        appBar: AppBar(title: const Text('Connect to my account')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: _body(context),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_working != null) {
      return [
        const SizedBox(height: 24),
        Text(_working!, style: display(20), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        const LinearProgressIndicator(),
        const SizedBox(height: 12),
        const Text(
          'Keep the app open until it finishes. If the connection drops, '
          'run it again: it continues without duplicates.',
          textAlign: TextAlign.center,
        ),
      ];
    }
    final error = _error;
    final retry = [
      if (error != null) ...[
        Text(error, style: TextStyle(color: scheme.error)),
        const SizedBox(height: 16),
        FilledButton(onPressed: _check, child: const Text('Try again')),
      ],
    ];
    final verified = _verified;
    if (verified != null) return _done(context, verified);
    final local = _local;
    if (local == null) return retry;

    final phone = BackupContents(
      data: local,
      files: const {},
      exportedAt: null,
      appVersion: '',
    );
    final phoneEmpty = phone.items.isEmpty;
    final preview = _preview;
    final useWithoutCopying = OutlinedButton(
      onPressed: _useAccount,
      child: const Text('Use my account without copying'),
    );
    final keepNote = Text(
      'This phone\'s own list stays on this phone, untouched. Signing out '
      'brings it back.',
      style: theme.textTheme.bodySmall,
    );

    if (_conflict != null) {
      return [
        Text(_conflict!),
        const SizedBox(height: 20),
        useWithoutCopying,
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Keep using this phone\'s list'),
        ),
        const SizedBox(height: 12),
        keepNote,
      ];
    }
    if (preview == null) return retry;

    final account = preview.before;
    final sides = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Side(
              icon: Icons.phone_android_outlined,
              title: 'On this phone',
              text:
                  '${plural(phone.items.length, 'thing')} · '
                  '${plural(phone.memories.length, 'memory', 'memories')} · '
                  '${plural(phone.photos.length, 'photo')}',
            ),
            const Divider(height: 24),
            _Side(
              icon: Icons.cloud_outlined,
              title: 'In your account',
              text: (account['items'] ?? 0) == 0
                  ? 'Empty'
                  : '${plural(account['items'] ?? 0, 'thing')} · '
                        '${plural(account['memories'] ?? 0, 'memory', 'memories')} · '
                        '${plural(account['photos'] ?? 0, 'photo')}',
            ),
          ],
        ),
      ),
    );

    if (phoneEmpty || preview.nothingToAdd) {
      return [
        sides,
        const SizedBox(height: 16),
        Text(
          phoneEmpty
              ? 'There\'s nothing on this phone to copy.'
              : 'Your account already has everything on this phone.',
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _useAccount,
          child: const Text('Use my account on this phone'),
        ),
        const SizedBox(height: 12),
        keepNote,
        ...retry,
      ];
    }

    if (preview.intoEmptyAccount) {
      return [
        sides,
        const SizedBox(height: 16),
        const Text(
          'Your account is empty. Copy this phone\'s list into it, with '
          'every journey, memory, hashtag, photo, date and your profile? '
          'The copy is read back and compared with this phone, record by '
          'record.',
        ),
        const SizedBox(height: 12),
        Text(
          'A backup of this phone is saved first. Photos are uploaded at '
          'full size, so use Wi-Fi if you have many.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => _run(exactCopy: true),
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('Copy to my account'),
        ),
        const SizedBox(height: 12),
        keepNote,
        ...retry,
      ];
    }

    return [
      sides,
      const SizedBox(height: 16),
      const Text(
        'Both have things. You can add this phone\'s list to your account:',
      ),
      const SizedBox(height: 12),
      MergeSummaryView(summary: preview, sourceName: 'this phone'),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Same title = same thing'),
        subtitle: const Text('Avoids duplicates of things on both'),
        value: _matchTitles,
        onChanged: (v) {
          setState(() => _matchTitles = v);
          _check();
        },
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: () => _run(exactCopy: false),
        icon: const Icon(Icons.merge_rounded),
        label: const Text('Add this phone\'s list to my account'),
      ),
      const SizedBox(height: 8),
      useWithoutCopying,
      const SizedBox(height: 12),
      keepNote,
      ...retry,
    ];
  }

  List<Widget> _done(BuildContext context, bool verified) {
    final scheme = Theme.of(context).colorScheme;
    final safety = _safetyCopy;
    return [
      Icon(
        verified ? Icons.verified_rounded : Icons.error_outline_rounded,
        size: 56,
        color: verified ? scheme.primary : scheme.error,
      ),
      const SizedBox(height: 12),
      Text(
        verified ? 'Copied and checked' : 'Not fully copied yet',
        style: display(22),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      if (_details.isNotEmpty) Text(_details, textAlign: TextAlign.center),
      if (_error != null) Text(_error!, style: TextStyle(color: scheme.error)),
      const SizedBox(height: 20),
      if (verified) ...[
        const Text(
          'Your account now has this phone\'s list. Use it on this phone to '
          'see the same list as the website; changes then sync both ways, '
          'also after being offline.',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _useAccount,
          child: const Text('Use my account on this phone'),
        ),
      ] else
        FilledButton(
          onPressed: () => setState(() {
            _verified = null;
            _check();
          }),
          child: const Text('Run again'),
        ),
      if (safety != null) ...[
        const SizedBox(height: 16),
        Text(
          'A backup of this phone\'s list was saved first.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        TextButton(
          onPressed: () => shareFiles(
            context,
            [safety],
            'application/zip',
            'Project: 1000 backup',
          ),
          child: const Text('Save a copy of that backup'),
        ),
      ],
    ];
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            Text(text),
          ],
        ),
      ),
    ],
  );
}
