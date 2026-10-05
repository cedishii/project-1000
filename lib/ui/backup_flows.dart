import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:project_1000/core/log.dart';

import '../services/backup/backup_format.dart';
import '../services/backup/export_service.dart';
import '../services/backup/import_service.dart';
import 'feedback.dart';
import 'formatting.dart';
import 'store_scope.dart';

const _channel = MethodChannel('project_1000/backup_file');

// ------------------------------------------------------------------ export

/// Creates a backup and lets the user save or share it.
Future<void> exportFlow(BuildContext context) async {
  final store = StoreScope.read(context);
  final progress = ValueNotifier<double?>(null);
  final close = _showProgress(context, 'Preparing your backup…', progress);
  ExportResult result;
  try {
    final info = await PackageInfo.fromPlatform();
    final out = Directory(
      p.join((await getTemporaryDirectory()).path, 'exports'),
    );
    result = await store.exportBackup(
      out,
      '${info.version}+${info.buildNumber}',
      onProgress: (v) => progress.value = v,
    );
  } catch (e, s) {
    close();
    logError('Export failed', e, s);
    if (context.mounted) {
      await _alert(
        context,
        'Backup failed',
        isOutOfSpace(e)
            ? 'There isn\'t enough free storage to create the backup. Free '
                  'up some space and try again.'
            : 'The backup couldn\'t be created. Your list is unchanged; '
                  'please try again.',
      );
    }
    return;
  }
  close();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ExportReadySheet(result: result),
  );
}

class _ExportReadySheet extends StatelessWidget {
  const _ExportReadySheet({required this.result});

  final ExportResult result;

  Future<void> _saveAndroid(BuildContext context) async {
    try {
      final saved = await _channel.invokeMethod<bool>('saveAs', {
        'source': result.file.path,
        'name': p.basename(result.file.path),
      });
      if (saved == true && context.mounted) {
        Navigator.pop(context);
        showMessage(context, 'Backup saved.');
      }
    } on PlatformException catch (e, s) {
      logError('Save failed', e, s);
      if (context.mounted) {
        showMessage(
          context,
          'The backup couldn\'t be saved there. Try another location.',
        );
      }
    }
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(result.file.path, mimeType: 'application/zip')],
          subject: 'Project: 1000 backup',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e, s) {
      logError('Share failed', e, s);
      if (context.mounted) showMessage(context, 'Sharing isn\'t available.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = result.file.lengthSync();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Text('Backup ready', style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              p.basename(result.file.path),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${plural(result.items, 'thing')} · '
              '${plural(result.memories, 'memory', 'memories')} · '
              '${plural(result.photos, 'photo')} · ${_fileSize(size)}',
              style: theme.textTheme.bodySmall,
            ),
            if (result.missingFiles.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '${plural(result.missingFiles.length, 'photo file')} could not '
                'be found on this device and isn\'t included.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'Keep this file somewhere safe — your computer, Google Drive, '
              'iCloud or Dropbox. To restore, open Settings → Import backup '
              'on any phone with Project: 1000.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            if (Platform.isAndroid) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _saveAndroid(context),
                  icon: const Icon(Icons.save_alt_rounded),
                  label: const Text('Save to device…'),
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child:
                  (Platform.isAndroid
                  ? OutlinedButton.icon
                  : FilledButton.icon)(
                    onPressed: () => _share(context),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: Text(
                      Platform.isAndroid
                          ? 'Share (Drive, email, …)'
                          : 'Save to Files or share…',
                    ),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ import

/// Lets the user pick a backup, checks it completely, shows what it
/// contains, and only replaces the current list after confirmation.
Future<void> importFlow(BuildContext context) async {
  final store = StoreScope.read(context);

  final String path;
  VoidCallback? closeOpening;
  try {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose a Project: 1000 backup',
      // Large backups take a while to copy from Drive/Downloads.
      onFileLoading: (status) {
        if (status == FilePickerStatus.picking && context.mounted) {
          closeOpening ??= _showProgress(context, 'Opening file…');
        }
      },
    );
    closeOpening?.call();
    if (picked.isEmpty || picked.single.path == null) return;
    path = picked.single.path!;
  } catch (e, s) {
    closeOpening?.call();
    logError('Picker failed', e, s);
    if (context.mounted) {
      await _alert(
        context,
        'Couldn\'t open the file',
        'The file couldn\'t be opened. Make sure the app is allowed to '
            'access it, or save it to your phone first.',
      );
    }
    return;
  }
  if (!context.mounted) return;

  final progress = ValueNotifier<double?>(null);
  var close = _showProgress(
    context,
    'Checking every file in the backup…',
    progress,
  );
  ImportPreview preview;
  try {
    preview = await prepareImport(
      path,
      store.location,
      onProgress: (v) => progress.value = v,
    );
  } on ImportException catch (e) {
    close();
    if (context.mounted) {
      await _alert(context, 'Can\'t import this file', e.problem.message);
    }
    await _clearPickerCache();
    return;
  }
  close();
  if (!context.mounted) return;

  while (true) {
    final choice = await _confirmImport(context, preview);
    if (!context.mounted) return;
    if (choice == _ImportChoice.backUpFirst) {
      await exportFlow(context);
      if (!context.mounted) return;
      continue;
    }
    if (choice != _ImportChoice.replace) {
      await cancelImport(store.location);
      await _clearPickerCache();
      return;
    }
    break;
  }

  close = _showProgress(context, 'Restoring your list…');
  try {
    await store.importBackup(preview);
    close();
    if (context.mounted) {
      showMessage(
        context,
        'Restored ${plural(preview.itemCount, 'thing')} and '
        '${plural(preview.memoryCount, 'memory', 'memories')}.',
      );
    }
  } catch (e, s) {
    close();
    logError('Import failed', e, s);
    await cancelImport(store.location);
    if (context.mounted) {
      await _alert(
        context,
        'Import failed',
        isOutOfSpace(e)
            ? ImportProblem.outOfSpace.message
            : 'The backup couldn\'t be restored. Your previous list was '
                  'kept unchanged.',
      );
    }
  } finally {
    await _clearPickerCache();
  }
}

enum _ImportChoice { cancel, backUpFirst, replace }

Future<_ImportChoice> _confirmImport(
  BuildContext context,
  ImportPreview preview,
) async {
  final store = StoreScope.read(context);
  final current = store.items;
  final sameItems =
      current.isNotEmpty &&
      current.length == preview.itemIds.length &&
      current.every((i) => preview.itemIds.contains(i.id));
  final scheme = Theme.of(context).colorScheme;

  final choice = await showDialog<_ImportChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Import this backup?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (preview.exportedAt != null)
              Text('Made ${_dateTime(preview.exportedAt!)}'),
            Text(
              '${plural(preview.itemCount, 'thing')} · '
              '${plural(preview.memoryCount, 'memory', 'memories')} · '
              '${plural(preview.photoCount, 'photo')}',
            ),
            if (preview.missingPhotoCount > 0) ...[
              const SizedBox(height: 12),
              Text(
                '${plural(preview.missingPhotoCount, 'photo')} in this backup '
                'are missing or damaged. Everything else can still be '
                'restored.',
                style: TextStyle(color: scheme.error),
              ),
            ],
            if (sameItems) ...[
              const SizedBox(height: 12),
              const Text(
                'This backup contains the same things as your '
                'current list. Importing will restore them exactly as they '
                'were when the backup was made.',
              ),
            ],
            const SizedBox(height: 12),
            Text(
              current.isEmpty
                  ? 'Your list is currently empty.'
                  : 'Importing will replace your current list '
                        '(${plural(current.length, 'thing')}) and its memories '
                        'and photos.',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _ImportChoice.cancel),
          child: const Text('Cancel'),
        ),
        if (current.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(context, _ImportChoice.backUpFirst),
            child: const Text('Back up current first'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ImportChoice.replace),
          child: Text(current.isEmpty ? 'Import' : 'Replace my list'),
        ),
      ],
    ),
  );
  return choice ?? _ImportChoice.cancel;
}

Future<void> _clearPickerCache() async {
  try {
    await FilePicker.clearTemporaryFiles();
  } catch (_) {}
}

// ----------------------------------------------------------------- helpers

/// Shows a non-dismissible progress dialog; returns a function closing it.
/// If [progress] is given, a bar shows how far along the work is.
VoidCallback _showProgress(
  BuildContext context,
  String message, [
  ValueNotifier<double?>? progress,
]) {
  final navigator = Navigator.of(context, rootNavigator: true);
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: ValueListenableBuilder<double?>(
          valueListenable: progress ?? ValueNotifier(null),
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(),
                  ),
                  const SizedBox(width: 20),
                  Expanded(child: Text(message)),
                ],
              ),
              if (value != null) ...[
                const SizedBox(height: 18),
                LinearProgressIndicator(value: value),
                const SizedBox(height: 6),
                Text(
                  '${(value * 100).floor()}%',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  ).whenComplete(() => open = false);
  return () {
    if (open) navigator.pop();
    open = false;
  };
}

Future<void> _alert(BuildContext context, String title, String message) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );

String _fileSize(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _dateTime(DateTime utc) => longDateTime(utc.toLocal());
