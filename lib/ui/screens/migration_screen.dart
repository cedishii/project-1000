import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/log.dart';
import '../../services/cloud/account.dart';
import '../../services/cloud/cloud_migration.dart';
import '../../services/cloud/supabase_migration_api.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../theme.dart';

/// Copies this phone's archive into the signed-in account and verifies
/// the copy (see [CloudMigration]). The phone's archive is only read.
class MigrationScreen extends StatefulWidget {
  const MigrationScreen({super.key});

  @override
  State<MigrationScreen> createState() => _MigrationScreenState();
}

class _MigrationScreenState extends State<MigrationScreen> {
  MigrationProgress? _progress;
  MigrationReport? _report;
  String? _error;

  bool get _running => _progress != null && _report == null && _error == null;

  Future<void> _start() async {
    final store = StoreScope.read(context);
    setState(() {
      _progress = const MigrationProgress(MigrationStage.records);
      _report = null;
      _error = null;
    });
    try {
      final report = await CloudMigration(
        location: store.location,
        snapshot: store.archiveSnapshot,
        api: SupabaseMigrationApi(CloudConfig.client),
      ).run(onProgress: (p) => mounted ? setState(() => _progress = p) : null);
      if (mounted) setState(() => _report = report);
    } catch (e, s) {
      logError('Migration failed', e, s);
      if (mounted) setState(() => _error = _message(e));
    }
  }

  static String _message(Object e) {
    if (e is PostgrestException && e.message == 'cloud_has_other_data') {
      return 'Your account already holds a different list (for example one '
          'started on the website). Copying would mix two lists, so nothing '
          'was copied. Your phone\'s list is unchanged.';
    }
    final s = e.toString();
    if (s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('Timeout')) {
      return 'The connection dropped. Nothing is lost: run it again and it '
          'continues where it stopped, without duplicates.';
    }
    return 'Copying stopped because of an error. Nothing on this phone was '
        'changed. Please try again; it continues where it stopped.';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final report = _report;
    return PopScope(
      canPop: !_running,
      child: Scaffold(
        appBar: AppBar(title: const Text('Copy to my account')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (report == null && !_running) ...[
              const Text(
                'This copies every journey, item, memory, hashtag and photo '
                'on this phone, plus your profile, into your account. '
                'Afterwards the account\'s copy is read back and compared '
                'with this phone, record by record.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Nothing on this phone is changed or deleted. If the '
                'connection drops, just run it again: it continues without '
                'making duplicates.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Photos are uploaded at full size, so use Wi-Fi if you have '
                'many.',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(_error == null ? 'Start copying' : 'Try again'),
              ),
            ],
            if (_running) ...[
              const SizedBox(height: 24),
              Text(
                switch (_progress!.stage) {
                  MigrationStage.records => 'Copying your list…',
                  MigrationStage.photos =>
                    'Uploading photos… ${_progress!.done} of ${_progress!.total}',
                  MigrationStage.verifying => 'Checking the copy…',
                  MigrationStage.done => 'Done',
                },
                style: display(20),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value:
                    _progress!.stage == MigrationStage.photos &&
                        _progress!.total > 0
                    ? _progress!.done / _progress!.total
                    : null,
              ),
              const SizedBox(height: 12),
              const Text(
                'Keep the app open until it finishes.',
                textAlign: TextAlign.center,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            if (report != null) ..._result(context, report),
          ],
        ),
      ),
    );
  }

  List<Widget> _result(BuildContext context, MigrationReport r) {
    final scheme = Theme.of(context).colorScheme;
    final c = r.counts;
    return [
      Icon(
        r.verified ? Icons.verified_rounded : Icons.error_outline_rounded,
        size: 56,
        color: r.verified ? scheme.primary : scheme.error,
      ),
      const SizedBox(height: 12),
      Text(
        r.verified ? 'Copied and verified' : 'Not fully copied yet',
        style: display(22),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      Text(
        'Your account holds ${plural(c['journeys'] ?? 0, 'journey')}, '
        '${plural(c['items'] ?? 0, 'thing')}, '
        '${plural(c['memories'] ?? 0, 'memory', 'memories')} and '
        '${plural(c['photos'] ?? 0, 'photo')}.',
        textAlign: TextAlign.center,
      ),
      if (r.missingOnPhone.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(
          '${plural(r.missingOnPhone.length, 'photo file')} were already '
          'missing on this phone, so they couldn\'t be copied.',
          textAlign: TextAlign.center,
        ),
      ],
      if (!r.verified) ...[
        const SizedBox(height: 12),
        Text(
          [
            if (r.missingInCloud.isNotEmpty)
              '${plural(r.missingInCloud.length, 'file')} didn\'t arrive.',
            if (r.differences.isNotEmpty)
              '${plural(r.differences.length, 'record')} differ between '
                  'this phone and your account.',
            'Run it again to finish. Nothing on this phone was changed.',
          ].join(' '),
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.error),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _start, child: const Text('Run again')),
      ] else ...[
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            showMessage(context, 'Your list is in your account.');
          },
          child: const Text('Done'),
        ),
      ],
    ];
  }
}
