import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:project_1000/core/log.dart';

import '../../data/models.dart';
import '../../services/album/album_pdf.dart';
import '../../state/app_store.dart';
import '../backup_flows.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../journey_facts.dart';
import '../store_scope.dart';

/// Builds the PDF of a journey's Life Album, then lets the user save or
/// share it.
Future<void> exportAlbumPdfFlow(BuildContext context, String journeyId) async {
  final store = StoreScope.read(context);
  final progress = ValueNotifier<double?>(null);
  final close = showProgressDialog(
    context,
    'Making your Life Album PDF…',
    progress,
  );
  List<File> files;
  try {
    final content = await albumPdfContent(store, journeyId);
    final temp = await getTemporaryDirectory();
    files = await exportAlbumPdf(
      content: content,
      assets: await loadAlbumPdfAssets(),
      outDir: Directory(p.join(temp.path, 'albums')),
      workDir: Directory(p.join(temp.path, 'album_work')),
      onProgress: (v) => progress.value = v,
    );
  } catch (e, s) {
    close();
    logError('Album PDF failed', e, s);
    if (context.mounted) {
      await showAlert(
        context,
        'PDF not created',
        isOutOfSpace(e)
            ? 'There isn\'t enough free storage to create the PDF. Free up '
                  'some space and try again.'
            : 'The PDF couldn\'t be created. Nothing was changed; please '
                  'try again.',
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
    builder: (_) => _PdfReadySheet(files: files),
  );
}

Future<AlbumPdfAssets> loadAlbumPdfAssets() async {
  Future<Uint8List> load(String name) async =>
      (await rootBundle.load(name)).buffer.asUint8List();
  return AlbumPdfAssets(
    heading: await load('assets/fonts/pdf/Fredoka-SemiBold.ttf'),
    regular: await load('assets/fonts/pdf/NotoSans-Regular.ttf'),
    bold: await load('assets/fonts/pdf/NotoSans-Bold.ttf'),
    italic: await load('assets/fonts/pdf/NotoSans-Italic.ttf'),
    emblem: await load('assets/branding/emblem.png'),
    fallbacks: [
      await load('assets/fonts/pdf/NotoSansMath-Arrows.ttf'),
      await load('assets/fonts/pdf/NotoSansSymbols2-Subset.ttf'),
    ],
  );
}

/// Gathers the album's text and photo paths for the PDF, in the journey's
/// list order. Only completed things appear, with all their memories.
Future<AlbumPdfContent> albumPdfContent(
  AppStore store,
  String journeyId,
) async {
  final summary = (await store.journeySummaries()).firstWhere(
    (s) => s.journey.id == journeyId,
  );
  final facts = JourneyFacts.of(store, summary);
  final outline = await store.albumOutline(journeyId);
  final memories = {
    for (final m in await store.loadMemoriesByIds([
      for (final e in outline)
        for (final m in e.memories) m.id,
    ]))
      m.id: m,
  };

  final profile = facts.profile;
  // Each photo as a file on this device (downloaded first for a cloud
  // archive); null where a photo isn't available.
  final paths = <String, String?>{};
  for (final rel in [
    ?profile.photo,
    for (final m in memories.values)
      for (final ph in m.photos) ph.file,
  ]) {
    paths[rel] ??= await store.media.localFile(rel);
  }
  PdfPhoto photoAt(String rel) => PdfPhoto(paths[rel]);

  return AlbumPdfContent(
    journeyNumber: facts.number,
    datesLine: facts.datesLine,
    thingsLine:
        '${count(facts.progress.completed)} '
        '${facts.progress.completed == 1 ? 'THING' : 'THINGS'} COMPLETED',
    name: profile.name,
    nickname: profile.nickname,
    profilePhoto: profile.photo == null ? null : photoAt(profile.photo!),
    facts: facts.rows,
    bio: profile.bio,
    closingTitle: facts.closingTitle,
    closingLines: facts.closingLines,
    closingFacts: facts.closingFacts,
    entries: [
      for (final e in outline)
        PdfEntry(
          number: e.item.label,
          title: e.item.title,
          description: e.item.description,
          completed: e.item.completedOn == null
              ? 'Completed'
              : 'Completed ${longDate(e.item.completedOn!)}',
          memories: [
            for (final meta in e.memories)
              if (memories[meta.id] case final Memory m)
                PdfMemory(
                  title: m.title,
                  body: m.body,
                  date: longDate(m.date),
                  location: m.location,
                  hashtags: m.hashtags,
                  photos: [for (final ph in m.photos) photoAt(ph.file)],
                ),
          ],
        ),
    ],
  );
}

class _PdfReadySheet extends StatelessWidget {
  const _PdfReadySheet({required this.files});

  final List<File> files;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  Icons.picture_as_pdf_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Text('Life Album ready', style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            for (final f in files)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${p.basename(f.path)} · ${fileSize(f.lengthSync())}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (files.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'This album is large, so it was split into '
                  '${files.length} PDFs. Keep them together.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 14),
            Text(
              'The PDF opens on any phone or computer, without the app.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            if (Platform.isAndroid) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    var saved = 0;
                    for (final f in files) {
                      if (!context.mounted) return;
                      if (await saveFileToDevice(
                        context,
                        f,
                        'application/pdf',
                      )) {
                        saved++;
                      }
                    }
                    if (saved > 0 && context.mounted) {
                      Navigator.pop(context);
                      showMessage(
                        context,
                        saved == 1 ? 'PDF saved.' : '$saved PDFs saved.',
                      );
                    }
                  },
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
                    onPressed: () => shareFiles(
                      context,
                      files,
                      'application/pdf',
                      'My 1000 Things — Life Album',
                    ),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: Text(
                      Platform.isAndroid
                          ? 'Open or share…'
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
