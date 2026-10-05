import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../state/app_store.dart';
import '../../state/list_view_filter.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../theme.dart';
import '../widgets/item_widgets.dart';
import '../widgets/memory_card.dart';

/// An archived journey's list, read-only, in its saved order. Search
/// only hides rows, as on the home screen.
class JourneyItemsScreen extends StatefulWidget {
  const JourneyItemsScreen({super.key, required this.journey});

  final Journey journey;

  @override
  State<JourneyItemsScreen> createState() => _JourneyItemsScreenState();
}

class _JourneyItemsScreenState extends State<JourneyItemsScreen> {
  late final Future<(List<BucketItem>, Map<String, int>)> _data;
  Set<String>? _matches;
  Timer? _debounce;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final store = StoreScope.read(context);
    _data = _load(store);
  }

  Future<(List<BucketItem>, Map<String, int>)> _load(AppStore store) async => (
    await store.loadJourneyItems(widget.journey.id),
    await store.memoryCountsFor(widget.journey.id),
  );

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onQuery(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      final q = value.trim();
      final gen = ++_generation;
      if (q.isEmpty) {
        setState(() => _matches = null);
        return;
      }
      try {
        final ids = await StoreScope.read(context)
            .searchJourney(widget.journey.id, q);
        if (mounted && gen == _generation) setState(() => _matches = ids);
      } catch (e, s) {
        if (mounted) showError(context, e, s);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Journey ${widget.journey.number} list')),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          final data = snap.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final (items, counts) = data;
          final visible = visibleItems(items, searchMatches: _matches);
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: TextField(
                    onChanged: _onQuery,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: 'Search this journey',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                ),
              ),
              if (_matches != null)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      'Showing ${count(visible.length)} of '
                      '${count(items.length)} · list order unchanged',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                sliver: SliverList.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => ItemTile(
                    key: ValueKey(visible[i].id),
                    item: visible[i],
                    memoryCount: counts[visible[i].id] ?? 0,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ArchivedItemScreen(item: visible[i]),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One thing from an archived journey, with its memories, read-only.
class ArchivedItemScreen extends StatefulWidget {
  const ArchivedItemScreen({super.key, required this.item});

  final BucketItem item;

  @override
  State<ArchivedItemScreen> createState() => _ArchivedItemScreenState();
}

class _ArchivedItemScreenState extends State<ArchivedItemScreen> {
  late final Future<List<Memory>> _memories = StoreScope.read(context)
      .loadMemories(widget.item.id);

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: FutureBuilder<List<Memory>>(
        future: _memories,
        builder: (context, snap) {
          final memories = snap.data ?? const <Memory>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
            children: [
              NumberLabel(item.number, size: 48, completed: item.isCompleted),
              const SizedBox(height: 10),
              Text(item.title, style: display(28)),
              if (item.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  item.description,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  CompletionMark(completed: item.isCompleted, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.isCompleted
                          ? 'Completed${item.completedOn == null ? '' : ' ${longDate(item.completedOn!)}'}'
                          : 'Not completed',
                      style: display(16, weight: 500, color: scheme.primary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text('Memories', style: display(20, weight: 500)),
              const SizedBox(height: 12),
              if (snap.connectionState != ConnectionState.done)
                const Center(child: CircularProgressIndicator())
              else if (memories.isEmpty)
                Text(
                  'No memories were written for this thing.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                )
              else
                for (var i = 0; i < memories.length; i++) ...[
                  MemoryCard(memory: memories[i], index: i + 1),
                  const SizedBox(height: 12),
                ],
            ],
          );
        },
      ),
    );
  }
}
