import 'package:flutter/material.dart';

import '../../services/album/album_plan.dart';
import '../album/album_export.dart';
import '../album/album_pages.dart';
import '../formatting.dart';
import '../journey_facts.dart';
import '../store_scope.dart';

/// A journey's Life Album, read like a book: cover, introduction, one
/// or more pages per completed thing in the list's own order, and a
/// closing page. Pages load their memories and photos only when shown.
class LifeAlbumScreen extends StatefulWidget {
  const LifeAlbumScreen({super.key, required this.journeyId});

  final String journeyId;

  @override
  State<LifeAlbumScreen> createState() => _LifeAlbumScreenState();
}

class _LifeAlbumScreenState extends State<LifeAlbumScreen> {
  final _controller = PageController();
  late final Future<(JourneyFacts, List<AlbumPage>)> _album = _load();
  int _page = 0;

  Future<(JourneyFacts, List<AlbumPage>)> _load() async {
    final store = StoreScope.read(context);
    final summary = (await store.journeySummaries()).firstWhere(
      (s) => s.journey.id == widget.journeyId,
    );
    final outline = await store.albumOutline(widget.journeyId);
    return (JourneyFacts.of(store, summary), planAlbum(outline));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int page) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.jumpToPage(page);
    } else {
      _controller.animateToPage(
        page,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(JourneyFacts, List<AlbumPage>)>(
      future: _album,
      builder: (context, snap) {
        final data = snap.data;
        final title = data == null
            ? 'Life Album'
            : 'Life Album · Journey ${data.$1.number}';
        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            actions: [
              IconButton(
                tooltip: 'Export as PDF',
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: data == null
                    ? null
                    : () => exportAlbumPdfFlow(context, widget.journeyId),
              ),
            ],
          ),
          body: snap.hasError
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'The album couldn\'t be opened. Nothing was changed; '
                      'please try again.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : data == null
              ? const Center(child: CircularProgressIndicator())
              : _book(data.$1, data.$2),
        );
      },
    );
  }

  Widget _book(JourneyFacts facts, List<AlbumPage> pages) {
    final last = pages.length - 1;
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: pages.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: AlbumPageView(page: pages[i], facts: facts),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _page > 0 ? () => _go(_page - 1) : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                  label: const Text('Previous'),
                ),
                Expanded(
                  child: Text(
                    'Page ${count(_page + 1)} / ${count(pages.length)}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                TextButton.icon(
                  onPressed: _page < last ? () => _go(_page + 1) : null,
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.chevron_right_rounded),
                  label: const Text('Next'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
