import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../item_actions.dart';
import '../store_scope.dart';
import '../theme.dart';
import '../widgets/item_widgets.dart';
import '../widgets/memory_card.dart';
import 'item_editor_screen.dart';
import 'memory_editor_screen.dart';

class ItemDetailScreen extends StatefulWidget {
  const ItemDetailScreen({super.key, required this.itemId});

  final String itemId;

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  Future<List<Memory>>? _memories;
  int _loadedRevision = -1;

  void _loadIfNeeded() {
    final store = StoreScope.of(context);
    if (_loadedRevision != store.memoryRevision) {
      _loadedRevision = store.memoryRevision;
      _memories = store.loadMemories(widget.itemId);
    }
  }

  Future<void> _openEditor(BucketItem item, [Memory? memory]) =>
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => MemoryEditorScreen(item: item, memory: memory)));

  Future<void> _deleteMemory(Memory memory, int index) async {
    final ok = await confirm(
      context,
      title: 'Delete memory #$index?',
      message: memory.photos.isEmpty
          ? 'This memory will be permanently deleted.'
          : 'This memory and its ${plural(memory.photos.length, 'photo')} '
              'will be permanently deleted.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await guard(context, () => StoreScope.read(context).deleteMemory(memory.id));
  }

  @override
  Widget build(BuildContext context) {
    _loadIfNeeded();
    final store = StoreScope.of(context);
    final item = store.itemById(widget.itemId);
    if (item == null) {
      // Deleted while open.
      return Scaffold(appBar: AppBar());
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ItemEditorScreen(item: item))),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) async {
              if (value == 'delete') {
                final deleted = await deleteItemFlow(context, item);
                if (deleted && context.mounted) Navigator.pop(context);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline_rounded),
                  title: Text('Delete'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(item),
        icon: const Icon(Icons.edit_note_rounded),
        label: const Text('Add memory'),
      ),
      body: FutureBuilder<List<Memory>>(
        future: _memories,
        builder: (context, snap) {
          final memories = snap.data ?? const <Memory>[];
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                sliver: SliverList.list(children: [
                  NumberLabel(item.number,
                      size: 48, completed: item.isCompleted),
                  const SizedBox(height: 10),
                  Text(item.title, style: display(28, weight: 600)),
                  if (item.description.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(item.description,
                        style:
                            theme.textTheme.bodyLarge?.copyWith(height: 1.5)),
                  ],
                  const SizedBox(height: 22),
                  _CompletionCard(item: item),
                  const SizedBox(height: 28),
                  Row(children: [
                    Text('Memories', style: display(20, weight: 500)),
                    const SizedBox(width: 8),
                    if (memories.isNotEmpty)
                      Text('${memories.length}',
                          style: display(20,
                              weight: 500, color: scheme.onSurfaceVariant)),
                  ]),
                  const SizedBox(height: 12),
                ]),
              ),
              if (snap.hasError)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('Memories couldn\'t be loaded. Nothing has '
                        'been deleted; please reopen this page.'),
                  ),
                )
              else if (snap.connectionState != ConnectionState.done &&
                  snap.data == null)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else if (memories.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      item.isCompleted
                          ? 'You did it. Write down how it went, and add a '
                              'photo or two.'
                          : 'No memories yet. Plans, first steps and the big '
                              'day itself all belong here.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList.separated(
                    itemCount: memories.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => MemoryCard(
                      key: ValueKey(memories[i].id),
                      memory: memories[i],
                      index: i + 1,
                      onEdit: () => _openEditor(item, memories[i]),
                      onDelete: () => _deleteMemory(memories[i], i + 1),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
          );
        },
      ),
    );
  }
}

class _CompletionCard extends StatelessWidget {
  const _CompletionCard({required this.item});

  final BucketItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => toggleCompletion(context, item),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            CompletionMark(completed: item.isCompleted, size: 32),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.isCompleted ? 'Completed' : 'Not completed',
                      style: display(18,
                          weight: 500,
                          color: item.isCompleted
                              ? scheme.primary
                              : scheme.onSurface)),
                  if (item.completedOn != null)
                    Text(
                      item.isCompleted
                          ? longDate(item.completedOn!)
                          : 'Previously completed ${longDate(item.completedOn!)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            Text(item.isCompleted ? 'Undo' : 'Mark done',
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: scheme.primary)),
          ]),
        ),
      ),
    );
  }
}
