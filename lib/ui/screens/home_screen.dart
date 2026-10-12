import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../state/app_store.dart';
import '../../state/list_view_filter.dart';
import '../app.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../item_actions.dart';
import '../layout.dart';
import '../store_scope.dart';
import '../theme.dart';
import '../widgets/emblem.dart';
import '../widgets/item_widgets.dart';
import '../widgets/level_widgets.dart';
import 'item_detail_screen.dart';
import 'item_editor_screen.dart';
import 'journey_complete_screen.dart';
import 'profile_screen.dart';
import 'reorder_screen.dart';
import 'settings_screen.dart';

/// The main list, always shown in the user's saved order.
///
/// Search and filters only hide rows; they never change the order.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchController = TextEditingController();
  ListFilter _filter = ListFilter.all;
  String _query = '';
  Set<String>? _matches;
  Timer? _debounce;
  AppStore? _store;
  int _searchGeneration = 0;

  /// The item shown beside the list on wide screens.
  String? _selected;
  bool _twoPane = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = StoreScope.read(context);
    if (store != _store) {
      _store?.removeListener(_refreshSearch);
      _store = store..addListener(_refreshSearch);
      if (store.recoveredFromInterruptedImport) {
        store.recoveredFromInterruptedImport = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            showMessage(
              context,
              'An import was interrupted last time. Your previous list was '
              'kept unchanged.',
            );
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _store?.removeListener(_refreshSearch);
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      _query = value.trim();
      _refreshSearch();
    });
  }

  /// Re-runs the search (also when data changes while a search is shown).
  Future<void> _refreshSearch() async {
    final query = _query;
    final generation = ++_searchGeneration;
    if (query.isEmpty) {
      if (_matches != null) setState(() => _matches = null);
      return;
    }
    try {
      final ids = await _store!.search(query);
      if (mounted && generation == _searchGeneration) {
        setState(() => _matches = ids);
      }
    } catch (e, s) {
      if (mounted) showError(context, e, s);
    }
  }

  void _clearSearch() {
    _searchController.clear();
    _debounce?.cancel();
    _query = '';
    _refreshSearch();
  }

  Future<void> _add() async {
    final store = StoreScope.read(context);
    if (store.isFull) {
      showMessage(
        context,
        'Your list already has ${count(maxItems)} things. Delete one to make room.',
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ItemEditorScreen()),
    );
  }

  void _openProfile() => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const ProfileScreen()),
  );

  void _open(BucketItem item) {
    if (_twoPane) {
      setState(() => _selected = item.id);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ItemDetailScreen(itemId: item.id)),
    );
  }

  /// Wide screens: the list and the selected thing side by side. The
  /// list keeps its phone layout; nothing is reordered or hidden.
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _twoPane = constraints.maxWidth >= Breakpoints.twoPane;
        if (!_twoPane) return _list(context);
        final store = StoreScope.of(context);
        final selected = _selected == null ? null : store.itemById(_selected!);
        final scheme = Theme.of(context).colorScheme;
        return Row(
          children: [
            SizedBox(width: listPaneWidth, child: _list(context)),
            VerticalDivider(
              width: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
            Expanded(
              child: selected == null
                  ? const _NothingSelected()
                  : ItemDetailScreen(
                      key: ValueKey(selected.id),
                      itemId: selected.id,
                      onClose: () => setState(() => _selected = null),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _list(BuildContext context) {
    final store = StoreScope.of(context);
    final items = store.items;
    final scheme = Theme.of(context).colorScheme;

    // Search and filter only hide rows; the saved order is kept.
    final matches = _matches;
    final visible = visibleItems(
      items,
      searchMatches: matches,
      filter: _filter,
    );
    final narrowed = matches != null || _filter != ListFilter.all;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const Emblem(size: 34),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appName, style: display(21)),
                  Text(
                    appTagline,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (items.length > 1)
            IconButton(
              tooltip: 'Reorder list',
              icon: const Icon(Icons.swap_vert_rounded),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ReorderScreen()),
              ),
            ),
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: _openProfile,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: items.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add'),
            ),
      body: items.isEmpty
          ? _EmptyList(onAdd: _add, journey: store.journey.number)
          : CustomScrollView(
              slivers: [
                if (store.progression.isComplete)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: JourneyCompleteBanner(journey: store.journey),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: ProgressHeader(
                      completed: store.completedCount,
                      listed: items.length,
                      footer: CompactLevelRow(
                        journey: store.journey.number,
                        progression: store.progression,
                        onTap: _openProfile,
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  sliver: SliverToBoxAdapter(
                    child: TextField(
                      controller: _searchController,
                      onChanged: _onQueryChanged,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search titles, memories, #tags, numbers',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: ListenableBuilder(
                          listenable: _searchController,
                          builder: (context, _) =>
                              _searchController.text.isEmpty
                              ? const SizedBox.shrink()
                              : IconButton(
                                  tooltip: 'Clear search',
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: _clearSearch,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  sliver: SliverToBoxAdapter(
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final f in ListFilter.values)
                          ChoiceChip(
                            label: Text(switch (f) {
                              ListFilter.all => 'All',
                              ListFilter.completed => 'Completed',
                              ListFilter.notCompleted => 'Not completed',
                            }),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                          ),
                      ],
                    ),
                  ),
                ),
                if (narrowed)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        'Showing ${count(visible.length)} of ${count(items.length)} · list order unchanged',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                if (visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          matches != null
                              ? 'Nothing matches "$_query".'
                              : _filter == ListFilter.completed
                              ? 'Nothing completed yet. It\'s coming.'
                              : 'Everything here is completed!',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                    sliver: SliverList.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = visible[index];
                        return ItemTile(
                          key: ValueKey(item.id),
                          item: item,
                          memoryCount: store.memoryCountOf(item.id),
                          onTap: () => _open(item),
                          onToggle: () => toggleCompletion(context, item),
                          selected: _twoPane && item.id == _selected,
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.onAdd, required this.journey});

  final VoidCallback onAdd;

  /// The current journey's number; a new journey says so.
  final int journey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Emblem(size: 120),
              const SizedBox(height: 28),
              if (journey > 1) ...[
                Text(
                  'JOURNEY $journey BEGINS.',
                  style: display(16, color: theme.colorScheme.primary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
              ],
              Text(
                'Your list is empty.',
                style: display(26),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'You have ${count(maxItems)} possibilities.',
                style: display(
                  18,
                  weight: 500,
                  color: theme.colorScheme.secondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Text(
                'What do you want to do before you die?',
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add your first thing'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The detail side before anything is chosen.
class _NothingSelected extends StatelessWidget {
  const _NothingSelected();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Emblem(size: 72),
            const SizedBox(height: 16),
            Text(
              'Choose a thing to see it here.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
