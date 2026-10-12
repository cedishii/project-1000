import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../album/album_export.dart';
import '../formatting.dart';
import '../journey_facts.dart';
import '../store_scope.dart';
import '../theme.dart';
import 'journey_complete_screen.dart';
import 'journey_items_screen.dart';
import 'life_album_screen.dart';

/// One journey's summary, with its Life Album, PDF and list.
class JourneyScreen extends StatefulWidget {
  const JourneyScreen({super.key, required this.journeyId});

  final String journeyId;

  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends State<JourneyScreen> {
  Future<JourneySummary?>? _summary;
  String? _loadedKey;

  void _loadIfNeeded() {
    final store = StoreScope.of(context);
    final key =
        '${store.journeyRevision}/${store.memoryRevision}/'
        '${store.completedCount}/${store.items.length}';
    if (key != _loadedKey) {
      _loadedKey = key;
      _summary = store.journeySummaries().then(
        (all) => all.where((s) => s.journey.id == widget.journeyId).firstOrNull,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    _loadIfNeeded();
    return FutureBuilder<JourneySummary?>(
      future: _summary,
      builder: (context, snap) {
        final summary = snap.data;
        if (summary == null) {
          return Scaffold(
            appBar: AppBar(),
            body: snap.connectionState == ConnectionState.done
                ? const Center(child: Text('This journey can\'t be found.'))
                : const Center(child: CircularProgressIndicator()),
          );
        }
        return _JourneyView(
          facts: JourneyFacts.of(StoreScope.read(context), summary),
        );
      },
    );
  }
}

class _JourneyView extends StatelessWidget {
  const _JourneyView({required this.facts});

  final JourneyFacts facts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final journey = facts.journey;
    final current = journey.isActive;

    return Scaffold(
      appBar: AppBar(title: Text('Journey ${facts.number}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          Text('JOURNEY ${facts.number}', style: display(32)),
          const SizedBox(height: 6),
          Text(
            facts.datesLine,
            style: theme.textTheme.titleMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            current
                ? 'Current journey'
                : 'Archived · a permanent, read-only record of this journey.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: current ? scheme.primary : scheme.secondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Column(
                children: [
                  for (final (label, value) in facts.rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Flexible(
                            child: Text(
                              value,
                              textAlign: TextAlign.end,
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LifeAlbumScreen(journeyId: journey.id),
              ),
            ),
            icon: const Icon(Icons.auto_stories_rounded),
            label: Text(
              facts.isFinished ? 'View Life Album' : 'View Life Album so far',
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => exportAlbumPdfFlow(context, journey.id),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: Text(
              kIsWeb
                  ? 'Download Life Album as PDF'
                  : 'Export Life Album as PDF',
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: current
                ? () => Navigator.of(context).popUntil((r) => r.isFirst)
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => JourneyItemsScreen(journey: journey),
                    ),
                  ),
            icon: const Icon(Icons.format_list_numbered_rounded),
            label: Text(
              current
                  ? 'Go to my list'
                  : 'Browse the list (${count(facts.summary.itemCount)})',
            ),
          ),
          if (current && facts.progress.isComplete) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () => openNewJourney(context),
              icon: const Icon(Icons.restart_alt_rounded),
              label: const Text('Start a new journey'),
            ),
          ],
          if (!current) ...[
            const SizedBox(height: 18),
            Text(
              'Archived journeys can be viewed, searched, exported and '
              'backed up, but not changed, so the record stays exactly as '
              'it was.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
