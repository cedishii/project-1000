import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:project_1000/core/log.dart';

import '../data/progression.dart';
import '../services/backup/backup_format.dart';
import '../services/cloud/account.dart';
import '../services/cloud/cloud_backup.dart';
import 'backup_flows.dart';
import 'download/download.dart';
import 'feedback.dart';
import 'formatting.dart';

/// Exports the signed-in account as a backup in the phone's format
/// (importable on any phone, and on the website): a download in a
/// browser, the share sheet on a phone.
Future<void> cloudExportFlow(BuildContext context) async {
  final progress = ValueNotifier<double?>(null);
  final close = showProgressDialog(context, 'Preparing your backup…', progress);
  try {
    final info = await PackageInfo.fromPlatform();
    final (zip, data, missing) = await CloudBackup(CloudConfig.client).export(
      appVersion: '${info.version}+${info.buildNumber}',
      onProgress: (done, total) =>
          progress.value = total == 0 ? null : done / total,
    );
    close();
    final name = backupFileName(DateTime.now());
    if (kIsWeb) {
      downloadBytes(name, zip, 'application/zip');
    } else {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, 'exports'),
      );
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(zip, flush: true);
      if (context.mounted) {
        await shareFiles(
          context,
          [file],
          'application/zip',
          'Project: 1000 backup',
        );
      }
    }
    if (context.mounted) {
      showMessage(
        context,
        missing.isEmpty
            ? 'Backup ready: ${fileSize(zip.length)}.'
            : 'Backup ready. ${plural(missing.length, 'photo file')} '
                  'couldn\'t be downloaded and isn\'t included.',
      );
    }
  } catch (e, s) {
    close();
    logError('Cloud export failed', e, s);
    if (context.mounted) {
      await showAlert(
        context,
        'Backup failed',
        isConnectionError(e)
            ? 'Your account couldn\'t be reached. Check your connection and '
                  'try again.'
            : 'The backup couldn\'t be created. Nothing was changed; please '
                  'try again.',
      );
    }
  }
}

/// Plain words for what a merge will do (or did), shared by importing a
/// backup into an account and connecting a phone to one.
class MergeSummaryView extends StatelessWidget {
  const MergeSummaryView({
    super.key,
    required this.summary,
    required this.sourceName,
  });

  final MergeSummary summary;

  /// "this backup", "this phone".
  final String sourceName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = summary;
    final lines = <String>[
      if (s.intoEmptyAccount)
        'Your account is empty, so it takes $sourceName\'s journeys as '
            'they are.',
      if (s.itemsAdded > 0) 'Adds ${plural(s.itemsAdded, 'thing')}.',
      if (s.journeysAdded > 0 && !s.intoEmptyAccount)
        'Adds ${plural(s.journeysAdded, 'finished journey')}.',
      if (s.memoriesAdded > 0)
        'Adds ${plural(s.memoriesAdded, 'memory', 'memories')}'
            '${s.photosAdded > 0 ? ' with ${plural(s.photosAdded, 'photo')}' : ''}.',
      if (s.matchedById > 0)
        '${plural(s.matchedById, 'thing')} ${s.matchedById == 1 ? 'is' : 'are'} '
            'already in your account.',
      if (s.matchedByTitle > 0)
        '${plural(s.matchedByTitle, 'thing')} with the same title as one '
            'in your account ${s.matchedByTitle == 1 ? 'is' : 'are'} treated '
            'as the same thing (no duplicate).',
      if (s.completionsAdded > 0)
        '${plural(s.completionsAdded, 'thing')} done in $sourceName '
            '${s.completionsAdded == 1 ? 'becomes' : 'become'} done in your '
            'account too.',
      if (s.textKept > 0)
        '${plural(s.textKept, 'thing')} ${s.textKept == 1 ? 'has' : 'have'} '
            'different text; your account\'s text is kept.',
      if (s.renumbered > 0)
        '${plural(s.renumbered, 'thing')} ${s.renumbered == 1 ? 'gets' : 'get'} '
            'a new number because your account already uses ${s.renumbered == 1 ? 'its' : 'theirs'}.',
      if (s.profile == 'added') 'Your profile is filled in from $sourceName.',
      if (s.profile == 'kept') 'Your account\'s profile is kept as it is.',
      if (s.nothingToAdd) 'Your account already has everything in $sourceName.',
    ];
    final before = s.before['completed'] ?? 0,
        after = s.after['completed'] ?? 0;
    final lb = Progression(before).level, la = Progression(after).level;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: Text(l)),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          after == before
              ? 'Progress stays at ${count(after)} done · Level $la.'
              : 'Progress: ${count(before)} → ${count(after)} done · '
                    'Level $lb → $la (EXP counts each thing once).',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Nothing in your account is removed or overwritten.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Reads [path] from [files] (an imported backup).
Future<Uint8List?> Function(String) readFrom(Map<String, Uint8List> files) =>
    (path) async => files[path];
