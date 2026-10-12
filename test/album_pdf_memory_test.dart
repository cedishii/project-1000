import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:project_1000/data/models.dart';
import 'package:project_1000/services/album/album_pdf.dart';
import 'package:project_1000/services/photo_storage.dart';

/// The website builds the Life Album PDF in memory from photo bytes; it
/// must come out the same as the phone's file-based PDF.
void main() {
  final jpeg = Uint8List.fromList(
    img.encodeJpg(
      img.Image(width: 300, height: 200)..clear(img.ColorRgb8(200, 80, 40)),
    ),
  );
  ShrunkImage? shrink(Uint8List data) {
    final decoded = img.decodeImage(data);
    if (decoded == null) return null;
    return ShrunkImage(
      Uint8List.fromList(img.encodeJpg(decoded)),
      decoded.width,
      decoded.height,
    );
  }

  Uint8List asset(String name) => File(name).readAsBytesSync();
  final assets = AlbumPdfAssets(
    heading: asset('assets/fonts/pdf/Fredoka-SemiBold.ttf'),
    regular: asset('assets/fonts/pdf/NotoSans-Regular.ttf'),
    bold: asset('assets/fonts/pdf/NotoSans-Bold.ttf'),
    italic: asset('assets/fonts/pdf/NotoSans-Italic.ttf'),
    emblem: asset('assets/branding/emblem.png'),
    fallbacks: [
      asset('assets/fonts/pdf/NotoSansMath-Arrows.ttf'),
      asset('assets/fonts/pdf/NotoSansSymbols2-Subset.ttf'),
    ],
  );

  AlbumPdfContent content(PdfPhoto Function(int kind) photo) => AlbumPdfContent(
    journeyNumber: 2,
    datesLine: 'June 15, 2031 → May 1, 2040',
    thingsLine: '1,000 THINGS COMPLETED',
    name: 'Test Person',
    nickname: 'Tess',
    profilePhoto: photo(0),
    facts: const [('Started', 'June 15, 2031')],
    bio: 'Bio ✓ 日本',
    closingTitle: 'THAT WAS JOURNEY 2.',
    closingLines: const ['1,000 THINGS.'],
    closingFacts: const [('Started', 'June 15, 2031')],
    entries: [
      for (var i = 1; i <= 12; i++)
        PdfEntry(
          number: formatNumber(i),
          title: 'Thing $i',
          description: '',
          completed: 'Completed March 18, 2035',
          memories: [
            if (i.isEven)
              PdfMemory(
                title: 'Memory $i',
                body: 'Text',
                date: 'March 18, 2035',
                location: 'Iceland',
                hashtags: const ['travel'],
                // A good photo, a damaged one and a missing one.
                photos: [photo(0), photo(1), photo(2)],
              ),
          ],
        ),
    ],
  );

  int pages(Uint8List pdf) =>
      RegExp(r'/Type\s*/Page(?!s)').allMatches(latin1.decode(pdf)).length;

  test('in-memory PDF matches the file-based one page for page', () async {
    final dir = await Directory.systemTemp.createTemp('p1000_pdfmem_');
    addTearDown(() => dir.delete(recursive: true));
    final good = File(p.join(dir.path, 'a.jpg'))..writeAsBytesSync(jpeg);
    final broken = File(p.join(dir.path, 'b.jpg'))..writeAsBytesSync([1, 2]);

    final files = await exportAlbumPdf(
      content: content(
        (k) => PdfPhoto(switch (k) {
          0 => good.path,
          1 => broken.path,
          _ => null,
        }),
      ),
      assets: assets,
      outDir: Directory(p.join(dir.path, 'out')),
      workDir: Directory(p.join(dir.path, 'work')),
      prepare: (path) async => shrink(File(path).readAsBytesSync()),
    );

    final progress = <double>[];
    final memory = await buildAlbumPdfInMemory(
      content: content(
        (k) => PdfPhoto(
          null,
          data: switch (k) {
            0 => jpeg,
            1 => Uint8List.fromList([1, 2]),
            _ => null,
          },
        ),
      ),
      assets: assets,
      prepare: (data) async => shrink(data),
      onProgress: progress.add,
    );

    expect(memory.map((m) => m.$1), ['My-1000-Things-Journey-2.pdf']);
    final pdf = memory.single.$2;
    expect(ascii.decode(pdf.sublist(0, 5)), '%PDF-');
    expect(latin1.decode(pdf.sublist(pdf.length - 8)), contains('%%EOF'));
    expect(pages(pdf), pages(files.single.readAsBytesSync()));
    expect(pages(pdf), greaterThan(5));
    expect(progress.last, closeTo(1, 0.001));
    expect(progress, orderedEquals([...progress]..sort()));
  });
}
