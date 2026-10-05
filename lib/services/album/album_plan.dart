/// Splits a journey into the pages of its Life Album.
///
/// The album follows the journey's list order exactly: pages are only
/// ever cut between consecutive entries, never reordered. Only the
/// outline (memory ids and sizes) is needed here; each page loads its own
/// memories when it is shown, so even a journey with thousands of
/// memories opens instantly.
library;

import '../../data/archive_repository.dart';
import '../../data/models.dart';

sealed class AlbumPage {
  const AlbumPage();
}

/// "MY 1000 THINGS · JOURNEY 1"
class AlbumCoverPage extends AlbumPage {
  const AlbumCoverPage();
}

/// "MY JOURNEY": dates, duration, totals, bio.
class AlbumIntroPage extends AlbumPage {
  const AlbumIntroPage();
}

/// One completed thing with some (or all) of its memories.
class AlbumItemPage extends AlbumPage {
  const AlbumItemPage({
    required this.item,
    required this.memories,
    required this.part,
    required this.parts,
    required this.firstMemory,
    required this.totalMemories,
    required this.style,
  });

  final BucketItem item;
  final List<AlbumMemoryMeta> memories;

  /// 0-based index of this page's first memory among the item's memories,
  /// and how many the item has (for "MEMORY 3" labels).
  final int firstMemory;
  final int totalMemories;

  /// 0-based part, when an item's memories fill several pages.
  final int part;
  final int parts;

  /// Varies the layout from page to page (0, 1, 2, …).
  final int style;

  bool get isContinued => part > 0;
}

/// Consecutive completed things that have no memories, a few per page.
class AlbumListPage extends AlbumPage {
  const AlbumListPage(this.items);

  final List<BucketItem> items;
}

/// Shown when nothing has been completed yet.
class AlbumEmptyPage extends AlbumPage {
  const AlbumEmptyPage();
}

/// "THAT WAS JOURNEY 1."
class AlbumClosingPage extends AlbumPage {
  const AlbumClosingPage();
}

/// How many memory-less things share a page.
const int albumListPageSize = 4;

/// Rough page capacity, in "memory units" (see [_weight]).
const double _pageCapacity = 3.4;
const double _headerWeight = 0.6;

double _weight(AlbumMemoryMeta m) {
  final text = m.textLength / 600;
  return 1 + (m.photoCount > 0 ? 1.6 : 0) + (text > 3 ? 3 : text);
}

List<AlbumPage> planAlbum(List<AlbumEntry> entries) {
  final pages = <AlbumPage>[const AlbumCoverPage(), const AlbumIntroPage()];
  final quiet = <BucketItem>[];
  void flushQuiet() {
    if (quiet.isNotEmpty) pages.add(AlbumListPage(List.of(quiet)));
    quiet.clear();
  }

  var style = 0;
  for (final e in entries) {
    if (e.memories.isEmpty) {
      quiet.add(e.item);
      if (quiet.length == albumListPageSize) flushQuiet();
      continue;
    }
    flushQuiet();
    // Fill pages with memories in order, at least one per page.
    final chunks = <List<AlbumMemoryMeta>>[[]];
    var used = _headerWeight;
    for (final m in e.memories) {
      final w = _weight(m);
      if (chunks.last.isNotEmpty && used + w > _pageCapacity) {
        chunks.add([]);
        used = _headerWeight / 2;
      }
      chunks.last.add(m);
      used += w;
    }
    var first = 0;
    for (var i = 0; i < chunks.length; i++) {
      pages.add(
        AlbumItemPage(
          item: e.item,
          memories: chunks[i],
          part: i,
          parts: chunks.length,
          firstMemory: first,
          totalMemories: e.memories.length,
          style: style++,
        ),
      );
      first += chunks[i].length;
    }
  }
  flushQuiet();
  if (entries.isEmpty) pages.add(const AlbumEmptyPage());
  pages.add(const AlbumClosingPage());
  return pages;
}
