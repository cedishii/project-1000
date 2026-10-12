/// Turns a Life Album into a real PDF that opens anywhere, without the
/// app.
///
/// Photos are first shrunk to a sensible print size (natively, one at a
/// time); the document is then laid out on a background isolate. Very
/// large albums are split into several PDFs ("Part 1 of 3", …) so a
/// lifetime of photos never has to fit in memory at once.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:project_1000/core/log.dart';

import '../background.dart';
import '../photo_storage.dart';

/// Longest side of photos in the PDF: sharp on screen and in print at
/// album size, without making the file enormous.
const int pdfPhotoMaxSide = 1400;
const int pdfPhotoQuality = 78;

/// Photo bytes per PDF file before the album is split into parts.
const int pdfVolumeImageBudget = 160 * 1024 * 1024;

/// A photo in the album: a file ([path], on a phone) or its contents
/// ([data], in a browser). With neither, the photo is unavailable
/// (missing or unreadable) and the PDF says so instead of hiding it.
class PdfPhoto {
  const PdfPhoto(this.path, {this.aspect = 1.5, this.bytes = 0, this.data});

  final String? path;
  final Uint8List? data;

  bool get isAvailable => path != null || data != null;

  /// The photo's bytes (read from [path] if needed).
  Uint8List read() => data ?? File(path!).readAsBytesSync();

  /// Width / height.
  final double aspect;
  final int bytes;
}

class PdfMemory {
  const PdfMemory({
    required this.title,
    required this.body,
    required this.date,
    required this.location,
    required this.hashtags,
    required this.photos,
  });

  final String title;
  final String body;
  final String date;
  final String location;
  final List<String> hashtags;
  final List<PdfPhoto> photos;
}

/// One completed thing. All text is already formatted for display.
class PdfEntry {
  const PdfEntry({
    required this.number,
    required this.title,
    required this.description,
    required this.completed,
    required this.memories,
  });

  final String number;
  final String title;
  final String description;

  /// e.g. "Completed March 18, 2028".
  final String completed;
  final List<PdfMemory> memories;

  int get imageBytes => [
    for (final m in memories)
      for (final ph in m.photos) ph.bytes,
  ].fold(0, (a, b) => a + b);
}

/// Everything printed in the album. Only the user's own data appears;
/// the app adds labels and numbers, never words on the user's behalf.
class AlbumPdfContent {
  const AlbumPdfContent({
    required this.journeyNumber,
    required this.datesLine,
    required this.thingsLine,
    required this.name,
    required this.nickname,
    required this.profilePhoto,
    required this.facts,
    required this.bio,
    required this.closingTitle,
    required this.closingLines,
    required this.closingFacts,
    required this.entries,
  });

  final int journeyNumber;

  /// "October 6, 2026 → June 14, 2031".
  final String datesLine;

  /// "1,000 THINGS COMPLETED".
  final String thingsLine;
  final String name;
  final String nickname;
  final PdfPhoto? profilePhoto;

  /// Label → value rows for the "My Journey" page.
  final List<(String, String)> facts;
  final String bio;

  /// "THAT WAS JOURNEY 1."
  final String closingTitle;

  /// "1,000 THINGS.", "1,000,000 EXP.", …
  final List<String> closingLines;
  final List<(String, String)> closingFacts;
  final List<PdfEntry> entries;

  AlbumPdfContent withPhotos(PdfPhoto? profile, List<PdfEntry> entries) =>
      AlbumPdfContent(
        journeyNumber: journeyNumber,
        datesLine: datesLine,
        thingsLine: thingsLine,
        name: name,
        nickname: nickname,
        profilePhoto: profile,
        facts: facts,
        bio: bio,
        closingTitle: closingTitle,
        closingLines: closingLines,
        closingFacts: closingFacts,
        entries: entries,
      );
}

/// Fonts and the emblem, loaded from the app's assets.
class AlbumPdfAssets {
  const AlbumPdfAssets({
    required this.heading,
    required this.regular,
    required this.bold,
    required this.italic,
    required this.emblem,
    this.fallbacks = const [],
  });

  final Uint8List heading;
  final Uint8List regular;
  final Uint8List bold;
  final Uint8List italic;
  final Uint8List emblem;

  /// Fonts for symbols the main fonts lack (arrows, ✓, ★, …).
  final List<Uint8List> fallbacks;
}

/// Shrinks one photo for the PDF. Returns null if it can't be read.
typedef PdfPhotoPreparer = Future<ShrunkImage?> Function(String sourcePath);

Future<ShrunkImage?> preparePdfPhoto(String sourcePath) async {
  final bytes = await File(sourcePath).readAsBytes();
  final (_, _, shrunk) = await shrinkImage(
    bytes,
    pdfPhotoMaxSide,
    quality: pdfPhotoQuality,
  );
  return shrunk;
}

/// `My-1000-Things-Journey-1.pdf` (or `…-Part-2-of-3.pdf`).
String albumPdfName(int journey, [int part = 0, int parts = 1]) =>
    'My-1000-Things-Journey-$journey'
    '${parts > 1 ? '-Part-${part + 1}-of-$parts' : ''}.pdf';

/// Writes the album as one or more PDFs into [outDir] and returns them.
/// [content]'s photos hold the original file paths (null = missing).
Future<List<File>> exportAlbumPdf({
  required AlbumPdfContent content,
  required AlbumPdfAssets assets,
  required Directory outDir,
  required Directory workDir,
  PdfPhotoPreparer prepare = preparePdfPhoto,
  void Function(double progress)? onProgress,
}) async {
  if (await workDir.exists()) await workDir.delete(recursive: true);
  await workDir.create(recursive: true);
  await outDir.create(recursive: true);
  // Remove earlier exports of albums so copies don't pile up.
  await for (final f in outDir.list()) {
    if (f is File && p.basename(f.path).startsWith('My-1000-Things-')) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
  try {
    // 1. Shrink every photo (60% of the work).
    final total = [
      for (final e in content.entries)
        for (final m in e.memories) ...m.photos,
    ].length;
    var done = 0, counter = 0;
    Future<PdfPhoto> shrink(PdfPhoto ph) async {
      final src = ph.path;
      if (src == null) return const PdfPhoto(null);
      try {
        final out = await prepare(src);
        if (out == null) return const PdfPhoto(null);
        final file = File(p.join(workDir.path, '${counter++}.jpg'));
        await file.writeAsBytes(out.bytes);
        return PdfPhoto(
          file.path,
          aspect: out.width / out.height,
          bytes: out.bytes.length,
        );
      } on FileSystemException catch (e) {
        if (_outOfSpace(e)) rethrow;
        logError('Album photo unavailable', e);
        return const PdfPhoto(null);
      } catch (e) {
        logError('Album photo unavailable', e);
        return const PdfPhoto(null);
      }
    }

    final profile = content.profilePhoto == null
        ? null
        : await shrink(content.profilePhoto!);
    final entries = <PdfEntry>[];
    for (final e in content.entries) {
      final memories = <PdfMemory>[];
      for (final m in e.memories) {
        final photos = <PdfPhoto>[];
        for (final ph in m.photos) {
          photos.add(await shrink(ph));
          onProgress?.call(++done / (total == 0 ? 1 : total) * 0.6);
        }
        memories.add(
          PdfMemory(
            title: m.title,
            body: m.body,
            date: m.date,
            location: m.location,
            hashtags: m.hashtags,
            photos: photos,
          ),
        );
      }
      entries.add(
        PdfEntry(
          number: e.number,
          title: e.title,
          description: e.description,
          completed: e.completed,
          memories: memories,
        ),
      );
    }

    // 2. Split into parts by photo size, keeping the list order.
    final volumes = _volumes(entries, pdfVolumeImageBudget);

    // 3. Lay out and write the PDFs in the background.
    final job = _PdfJob(
      content: content.withPhotos(profile, const []),
      volumes: volumes,
      assets: assets,
      outDir: outDir.path,
    );
    final paths = await runWithProgress(
      _pdfTask(job),
      onProgress: (v) => onProgress?.call(0.6 + v * 0.4),
    );
    return [for (final path in paths) File(path)];
  } finally {
    try {
      await workDir.delete(recursive: true);
    } catch (_) {}
  }
}

/// Photo bytes per PDF when building in memory (in a browser), which
/// has far less room than a phone's storage.
const int pdfMemoryVolumeImageBudget = 60 * 1024 * 1024;

/// Shrinks one photo's bytes for the PDF. Returns null if unreadable.
typedef PdfBytesPreparer = Future<ShrunkImage?> Function(Uint8List data);

Future<ShrunkImage?> preparePdfPhotoBytes(Uint8List data) async {
  final (_, _, shrunk) = await shrinkImage(
    data,
    pdfPhotoMaxSide,
    quality: pdfPhotoQuality,
  );
  return shrunk;
}

/// Builds the album as one or more PDFs in memory (for the web, where
/// there are no files or background isolates). [content]'s photos hold
/// their bytes in [PdfPhoto.data] (null = missing). Returns the file
/// names and contents, in order.
Future<List<(String, Uint8List)>> buildAlbumPdfInMemory({
  required AlbumPdfContent content,
  required AlbumPdfAssets assets,
  PdfBytesPreparer prepare = preparePdfPhotoBytes,
  void Function(double progress)? onProgress,
}) async {
  final total = [
    for (final e in content.entries)
      for (final m in e.memories) ...m.photos,
  ].length;
  var done = 0;
  Future<PdfPhoto> shrink(PdfPhoto ph) async {
    final data = ph.data;
    if (data == null) return const PdfPhoto(null);
    try {
      final out = await prepare(data);
      if (out == null) return const PdfPhoto(null);
      return PdfPhoto(
        null,
        data: out.bytes,
        aspect: out.width / out.height,
        bytes: out.bytes.length,
      );
    } catch (e) {
      logError('Album photo unavailable', e);
      return const PdfPhoto(null);
    }
  }

  final profile = content.profilePhoto == null
      ? null
      : await shrink(content.profilePhoto!);
  final entries = <PdfEntry>[];
  for (final e in content.entries) {
    entries.add(
      PdfEntry(
        number: e.number,
        title: e.title,
        description: e.description,
        completed: e.completed,
        memories: [
          for (final m in e.memories)
            PdfMemory(
              title: m.title,
              body: m.body,
              date: m.date,
              location: m.location,
              hashtags: m.hashtags,
              photos: [
                for (final ph in m.photos)
                  await shrink(ph).whenComplete(
                    () => onProgress?.call(
                      ++done / (total == 0 ? 1 : total) * 0.6,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
  final job = _PdfJob(
    content: content.withPhotos(profile, const []),
    volumes: _volumes(entries, pdfMemoryVolumeImageBudget),
    assets: assets,
    outDir: '',
  );
  final out = <(String, Uint8List)>[];
  await _buildPdfs(
    job,
    (v) => onProgress?.call(0.6 + v * 0.4),
    (name, bytes) async => out.add((name, bytes)),
  );
  return out;
}

/// Splits the entries into PDF parts by photo size, keeping list order.
List<List<PdfEntry>> _volumes(List<PdfEntry> entries, int budget) {
  final volumes = <List<PdfEntry>>[[]];
  var bytes = 0;
  for (final e in entries) {
    if (volumes.last.isNotEmpty && bytes + e.imageBytes > budget) {
      volumes.add([]);
      bytes = 0;
    }
    volumes.last.add(e);
    bytes += e.imageBytes;
  }
  return volumes;
}

/// Built here, not inline, so the closure sent to the background isolate
/// captures only [job] (closures in [exportAlbumPdf] share a context
/// that also holds the UI's progress callback, which can't be sent).
Future<List<String>> Function(void Function(double)) _pdfTask(_PdfJob job) =>
    (report) => _writePdfs(job, report);

bool _outOfSpace(FileSystemException e) {
  final c = e.osError?.errorCode;
  return c == 28 || c == 112 || c == 39;
}

class _PdfJob {
  _PdfJob({
    required this.content,
    required this.volumes,
    required this.assets,
    required this.outDir,
  });

  final AlbumPdfContent content;
  final List<List<PdfEntry>> volumes;
  final AlbumPdfAssets assets;
  final String outDir;
}

// ---------------------------------------------------------------------------
// Runs on a background isolate.

const _paper = PdfColor.fromInt(0xFFFBF8F1);
const _ink = PdfColor.fromInt(0xFF1F2421);
const _muted = PdfColor.fromInt(0xFF5F6461);
const _green = PdfColor.fromInt(0xFF3F7A35);
const _purple = PdfColor.fromInt(0xFF3B1F4A);
const _line = PdfColor.fromInt(0xFFE2DDD0);

Future<List<String>> _writePdfs(
  _PdfJob job,
  void Function(double) report,
) async {
  final out = <String>[];
  await _buildPdfs(job, report, (name, bytes) async {
    final path = p.join(job.outDir, name);
    final partial = File('$path.partial');
    partial.writeAsBytesSync(bytes, flush: true);
    partial.renameSync(path);
    out.add(path);
  });
  return out;
}

/// Lays out every part of the album and hands each finished PDF to
/// [emit] (file name, contents) before starting the next.
Future<void> _buildPdfs(
  _PdfJob job,
  void Function(double) report,
  Future<void> Function(String name, Uint8List bytes) emit,
) async {
  final a = job.assets;
  final heading = pw.Font.ttf(ByteData.sublistView(a.heading));
  final regular = pw.Font.ttf(ByteData.sublistView(a.regular));
  final bold = pw.Font.ttf(ByteData.sublistView(a.bold));
  final italic = pw.Font.ttf(ByteData.sublistView(a.italic));
  final emblem = pw.MemoryImage(a.emblem);
  final c = job.content;
  final s = _Styles(heading);
  final pageTheme = pw.PageTheme(
    pageFormat: PdfPageFormat.a5,
    margin: const pw.EdgeInsets.fromLTRB(36, 40, 36, 32),
    // Body text uses Noto Sans; arrows and symbols it lacks come from
    // the fallback fonts. (Scripts like CJK and emoji aren't bundled and
    // show as a placeholder box.)
    theme: pw.ThemeData.withFont(
      base: regular,
      bold: bold,
      italic: italic,
      boldItalic: bold,
      fontFallback: [
        for (final f in a.fallbacks) pw.Font.ttf(ByteData.sublistView(f)),
      ],
    ),
    buildBackground: (_) =>
        pw.FullPage(ignoreMargins: true, child: pw.Container(color: _paper)),
  );
  pw.ImageProvider? profile;
  if (c.profilePhoto case final photo? when photo.isAvailable) {
    profile = pw.MemoryImage(photo.read());
  }

  final parts = job.volumes.length;
  final totalEntries = job.volumes.fold(0, (n, v) => n + v.length);
  var built = 0;
  for (var v = 0; v < parts; v++) {
    final doc = pw.Document(
      title: 'My 1000 Things — Journey ${c.journeyNumber}',
      author: c.name.isEmpty ? null : c.name,
      creator: 'Project: 1000',
    );
    doc.addPage(
      pw.Page(
        pageTheme: pageTheme,
        build: (_) => _cover(c, s, emblem, profile, v, parts),
      ),
    );
    if (v == 0) {
      doc.addPage(
        pw.Page(pageTheme: pageTheme, build: (_) => _intro(c, s, profile)),
      );
    }

    pw.Widget footer(pw.Context ctx) => pw.Container(
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 10),
      child: pw.Text(
        'Journey ${c.journeyNumber} · ${ctx.pageNumber}',
        style: s.small,
      ),
    );

    // Things without memories share pages; each thing with memories
    // starts on a fresh page. The list order is kept throughout.
    final quiet = <PdfEntry>[];
    void flushQuiet() {
      if (quiet.isEmpty) return;
      final group = List.of(quiet);
      quiet.clear();
      doc.addPage(
        pw.MultiPage(
          pageTheme: pageTheme,
          footer: footer,
          build: (_) => [
            for (final e in group) ...[
              ..._entryHeader(e, s),
              pw.SizedBox(height: 10),
              pw.Divider(color: _line, thickness: 0.6),
              pw.SizedBox(height: 10),
            ],
          ],
        ),
      );
    }

    for (final e in job.volumes[v]) {
      if (e.memories.isEmpty) {
        quiet.add(e);
      } else {
        flushQuiet();
        doc.addPage(
          pw.MultiPage(
            pageTheme: pageTheme,
            footer: footer,
            build: (ctx) => [
              ..._entryHeader(e, s),
              pw.SizedBox(height: 14),
              for (var i = 0; i < e.memories.length; i++)
                ..._memory(
                  e.memories[i],
                  e.memories.length > 1 ? i + 1 : null,
                  s,
                  pageTheme.pageFormat.availableWidth,
                ),
            ],
          ),
        );
      }
      report(++built / (totalEntries + parts) * 0.8);
    }
    flushQuiet();
    if (v == parts - 1) {
      doc.addPage(
        pw.Page(pageTheme: pageTheme, build: (_) => _closing(c, s, profile)),
      );
    }

    await emit(albumPdfName(c.journeyNumber, v, parts), await doc.save());
    report((built + v + 1) / (totalEntries + parts));
  }
}

class _Styles {
  _Styles(pw.Font heading)
    : h1 = pw.TextStyle(font: heading, fontSize: 30, color: _purple),
      h2 = pw.TextStyle(font: heading, fontSize: 18, color: _green),
      h3 = pw.TextStyle(font: heading, fontSize: 15, color: _ink),
      number = pw.TextStyle(font: heading, fontSize: 24, color: _purple),
      big = pw.TextStyle(font: heading, fontSize: 20, color: _ink);

  final pw.TextStyle h1, h2, h3, number, big;
  final body = const pw.TextStyle(fontSize: 10.5, color: _ink, lineSpacing: 3);
  final small = const pw.TextStyle(fontSize: 8.5, color: _muted);
  final meta = const pw.TextStyle(fontSize: 9.5, color: _muted);
  final label = pw.TextStyle(
    fontSize: 8.5,
    color: _muted,
    fontWeight: pw.FontWeight.bold,
    letterSpacing: 1.2,
  );
}

pw.Widget _avatar(pw.ImageProvider image, double size) => pw.ClipOval(
  child: pw.SizedBox(
    width: size,
    height: size,
    child: pw.Image(image, fit: pw.BoxFit.cover),
  ),
);

pw.Widget _cover(
  AlbumPdfContent c,
  _Styles s,
  pw.ImageProvider emblem,
  pw.ImageProvider? profile,
  int part,
  int parts,
) {
  return pw.Column(
    children: [
      pw.SizedBox(height: 30),
      pw.Image(emblem, width: 96, height: 96),
      pw.SizedBox(height: 28),
      pw.Text('MY 1000 THINGS', style: s.h1, textAlign: pw.TextAlign.center),
      pw.SizedBox(height: 10),
      pw.Text('JOURNEY ${c.journeyNumber}', style: s.h2),
      pw.SizedBox(height: 18),
      pw.Text(c.datesLine, style: s.body, textAlign: pw.TextAlign.center),
      pw.SizedBox(height: 6),
      pw.Text(c.thingsLine, style: s.h3, textAlign: pw.TextAlign.center),
      if (parts > 1) ...[
        pw.SizedBox(height: 10),
        pw.Text('PART ${part + 1} OF $parts', style: s.label),
      ],
      pw.Spacer(),
      if (profile != null) ...[_avatar(profile, 72), pw.SizedBox(height: 10)],
      if (c.name.isNotEmpty) pw.Text(c.name, style: s.h3),
      if (c.nickname.isNotEmpty && c.nickname != c.name)
        pw.Text('"${c.nickname}"', style: s.meta),
      pw.SizedBox(height: 20),
    ],
  );
}

pw.Widget _factRows(List<(String, String)> facts, _Styles s) => pw.Column(
  children: [
    for (final (label, value) in facts)
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 7),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _line, width: 0.6)),
        ),
        child: pw.Row(
          children: [
            pw.Expanded(child: pw.Text(label.toUpperCase(), style: s.label)),
            pw.Text(
              value,
              style: s.body.copyWith(fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
      ),
  ],
);

pw.Widget _intro(AlbumPdfContent c, _Styles s, pw.ImageProvider? profile) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text('MY JOURNEY', style: s.h1),
      pw.SizedBox(height: 4),
      pw.Text('JOURNEY ${c.journeyNumber}', style: s.h2),
      pw.SizedBox(height: 18),
      _factRows(c.facts, s),
      if (c.bio.isNotEmpty) ...[
        pw.SizedBox(height: 22),
        pw.Text('ABOUT ME', style: s.label),
        pw.SizedBox(height: 6),
        pw.Text(c.bio, style: s.body),
      ],
    ],
  );
}

pw.Widget _closing(AlbumPdfContent c, _Styles s, pw.ImageProvider? profile) {
  return pw.Column(
    children: [
      pw.Spacer(),
      pw.Text(c.closingTitle, style: s.h1, textAlign: pw.TextAlign.center),
      pw.SizedBox(height: 18),
      for (final line in c.closingLines)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Text(line, style: s.big),
        ),
      pw.SizedBox(height: 22),
      for (final (label, value) in c.closingFacts)
        pw.Text('$label: $value', style: s.body),
      pw.Spacer(),
      if (profile != null) _avatar(profile, 56),
      pw.SizedBox(height: 16),
    ],
  );
}

List<pw.Widget> _entryHeader(PdfEntry e, _Styles s) => [
  pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(e.number, style: s.number),
      pw.SizedBox(width: 12),
      pw.Expanded(
        child: pw.Padding(
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text(e.title.toUpperCase(), style: s.h3),
        ),
      ),
    ],
  ),
  if (e.description.isNotEmpty) ...[
    pw.SizedBox(height: 6),
    pw.Text(
      e.description,
      style: s.body.copyWith(fontStyle: pw.FontStyle.italic, color: _muted),
      overflow: pw.TextOverflow.span,
    ),
  ],
  pw.SizedBox(height: 6),
  pw.Text(
    e.completed,
    style: s.meta.copyWith(color: _green, fontWeight: pw.FontWeight.bold),
  ),
];

List<pw.Widget> _memory(PdfMemory m, int? index, _Styles s, double width) {
  final meta = [m.date, if (m.location.isNotEmpty) m.location].join('  ·  ');
  return [
    if (index != null) ...[
      pw.Text('MEMORY $index', style: s.label.copyWith(color: _purple)),
      pw.SizedBox(height: 6),
    ],
    ..._photos(m.photos, s, width),
    if (m.title.isNotEmpty) ...[
      pw.Text(m.title, style: s.h3),
      pw.SizedBox(height: 4),
    ],
    if (m.body.isNotEmpty) ...[
      pw.Text(m.body, style: s.body, overflow: pw.TextOverflow.span),
      pw.SizedBox(height: 6),
    ],
    pw.Text(meta, style: s.meta),
    if (m.hashtags.isNotEmpty) ...[
      pw.SizedBox(height: 3),
      pw.Text(
        m.hashtags.map((t) => '#$t').join('  '),
        style: s.meta.copyWith(color: _green),
      ),
    ],
    pw.SizedBox(height: 20),
  ];
}

/// Photo-first: one large photo, then the rest two by two. Each row is
/// a separate widget so pages can break between rows.
List<pw.Widget> _photos(List<PdfPhoto> photos, _Styles s, double width) {
  if (photos.isEmpty) return const [];
  const gap = 8.0;
  final rows = <pw.Widget>[];
  final hero = photos.first;
  final heroHeight = (width / hero.aspect).clamp(120.0, 300.0);
  rows.add(_photo(hero, width, heroHeight, s));
  final rest = photos.sublist(1);
  final cell = (width - gap) / 2;
  for (var i = 0; i < rest.length; i += 2) {
    rows.add(pw.SizedBox(height: gap));
    rows.add(
      pw.Row(
        children: [
          _photo(rest[i], cell, cell * 0.75, s),
          pw.SizedBox(width: gap),
          if (i + 1 < rest.length)
            _photo(rest[i + 1], cell, cell * 0.75, s)
          else
            pw.SizedBox(width: cell),
        ],
      ),
    );
  }
  rows.add(pw.SizedBox(height: 12));
  return rows;
}

pw.Widget _photo(PdfPhoto ph, double width, double height, _Styles s) {
  if (!ph.isAvailable) {
    return pw.Container(
      width: width,
      height: height,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _line),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Text('Photo unavailable', style: s.meta),
    );
  }
  return pw.SizedBox(
    width: width,
    height: height,
    child: pw.Image(pw.MemoryImage(ph.read()), fit: pw.BoxFit.contain),
  );
}
