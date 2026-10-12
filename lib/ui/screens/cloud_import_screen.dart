import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:project_1000/core/log.dart';

import '../../services/backup/backup_bytes.dart';
import '../../services/backup/backup_format.dart';
import '../../services/cloud/account.dart';
import '../../services/cloud/cloud_backup.dart';
import '../backup_flows.dart' show fileSize;
import '../cloud_backup_flows.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../theme.dart';

/// Imports a backup (from a phone or the website) into the signed-in
/// account as a safe merge: the file is checked, a preview says exactly
/// what will be added, and nothing happens until the user confirms.
/// Nothing in the account is removed or overwritten, and importing the
/// same file again adds nothing.
class CloudImportScreen extends StatefulWidget {
  const CloudImportScreen({super.key});

  @override
  State<CloudImportScreen> createState() => _CloudImportScreenState();
}

class _CloudImportScreenState extends State<CloudImportScreen> {
  final _backup = CloudBackup(CloudConfig.client);
  BackupContents? _file;
  String? _fileName;
  int _fileSize = 0;
  MergeSummary? _preview;
  MergeResult? _result;
  String? _error;
  String? _working;
  var _matchTitles = true;

  Future<void> _pick() async {
    setState(() {
      _error = null;
      _result = null;
    });
    try {
      final picked = await FilePicker.pickFiles(
        dialogTitle: 'Choose a Project: 1000 backup',
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      if (picked.isEmpty) return;
      final f = picked.single;
      final size = await f.length() ?? 0;
      if (size > maxInMemoryBackupBytes) {
        setState(
          () => _error =
              'This backup is larger than 1 GB, too large to import here.',
        );
        return;
      }
      setState(() => _working = 'Checking the backup…');
      final contents = readBackupBytes(await f.readAsBytes());
      setState(() {
        _file = contents;
        _fileName = f.name;
        _fileSize = size;
      });
      await _loadPreview();
    } on ImportException catch (e) {
      logError('Cloud import: bad file', e);
      setState(() => _error = e.problem.message);
    } catch (e, s) {
      logError('Cloud import failed', e, s);
      setState(() => _error = mergeProblem(e));
    }
    if (mounted) setState(() => _working = null);
  }

  Future<void> _loadPreview() async {
    final file = _file;
    if (file == null) return;
    setState(() {
      _working = 'Comparing with your account…';
      _preview = null;
      _error = null;
    });
    try {
      final preview = await _backup.preview(
        file.data,
        matchTitles: _matchTitles,
      );
      if (mounted) setState(() => _preview = preview);
    } catch (e, s) {
      logError('Cloud import preview failed', e, s);
      if (mounted) setState(() => _error = mergeProblem(e));
    }
    if (mounted) setState(() => _working = null);
  }

  Future<void> _import() async {
    final file = _file!;
    setState(() {
      _working = 'Importing…';
      _error = null;
    });
    try {
      final result = await _backup.merge(
        file.data,
        readFile: readFrom(file.files),
        matchTitles: _matchTitles,
        onProgress: (stage, done, total) {
          if (!mounted) return;
          setState(
            () => _working = switch (stage) {
              'photos' => 'Uploading photos… $done of $total',
              'verifying' => 'Checking your account…',
              _ => 'Importing…',
            },
          );
        },
      );
      if (!mounted) return;
      setState(() => _result = result);
      StoreScope.read(context).refresh().catchError((Object e, StackTrace s) {
        logError('Refresh after import failed', e, s);
      });
    } catch (e, s) {
      logError('Cloud import failed', e, s);
      if (mounted) setState(() => _error = mergeProblem(e));
    }
    if (mounted) setState(() => _working = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = _file, preview = _preview, result = _result;
    return PopScope(
      canPop: _working == null,
      child: Scaffold(
        appBar: AppBar(title: const Text('Import a backup')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (file == null) ...[
              const Text(
                'Choose a Project: 1000 backup (.zip) made on a phone or on '
                'the website. Its things, memories, photos and progress are '
                'added to your account. Nothing in your account is removed '
                'or overwritten, and importing the same backup again adds '
                'nothing.',
              ),
              const SizedBox(height: 20),
            ] else ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(_fileName ?? 'Backup'),
                  subtitle: Text(
                    [
                      if (file.exportedAt != null)
                        'Made ${longDateTime(file.exportedAt!.toLocal())}',
                      '${plural(file.items.length, 'thing')} · '
                          '${plural(file.memories.length, 'memory', 'memories')} · '
                          '${plural(file.photos.length, 'photo')} · '
                          '${fileSize(_fileSize)}',
                      if (file.missingPhotos > 0)
                        '${plural(file.missingPhotos, 'photo')} missing in the file',
                    ].join('\n'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_working != null) ...[
              const SizedBox(height: 12),
              Text(_working!, style: display(18), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text(
                'Keep this page open until it finishes.',
                textAlign: TextAlign.center,
              ),
            ],
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 16),
            ],
            if (result != null)
              ..._resultView(context, result)
            else if (preview != null && _working == null) ...[
              Text('What will happen', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              MergeSummaryView(summary: preview, sourceName: 'this backup'),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Same title = same thing'),
                subtitle: const Text(
                  'Avoids duplicates when a thing was added on two devices',
                ),
                value: _matchTitles,
                onChanged: (v) {
                  setState(() => _matchTitles = v);
                  _loadPreview();
                },
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: preview.nothingToAdd ? null : _import,
                icon: const Icon(Icons.merge_rounded),
                label: const Text('Add to my account'),
              ),
            ],
            if (_working == null && result == null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(
                  file == null ? 'Choose a backup' : 'Choose another',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _resultView(BuildContext context, MergeResult r) {
    final scheme = Theme.of(context).colorScheme;
    return [
      Icon(
        r.verified ? Icons.verified_rounded : Icons.error_outline_rounded,
        size: 56,
        color: r.verified ? scheme.primary : scheme.error,
      ),
      const SizedBox(height: 8),
      Text(
        r.verified ? 'Imported and checked' : 'Not fully imported yet',
        style: display(22),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      MergeSummaryView(summary: r.summary, sourceName: 'this backup'),
      if (r.missingInFile.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${plural(r.missingInFile.length, 'photo file')} weren\'t in the '
            'backup, so they couldn\'t be added.',
          ),
        ),
      if (!r.verified) ...[
        const SizedBox(height: 12),
        Text(
          '${plural(r.missingInCloud.length, 'file')} didn\'t arrive. Run it '
          'again to finish: nothing is added twice.',
          style: TextStyle(color: scheme.error),
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _import, child: const Text('Run again')),
      ] else ...[
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            showMessage(context, 'Backup imported into your account.');
          },
          child: const Text('Done'),
        ),
      ],
    ];
  }
}
