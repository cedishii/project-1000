import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../widgets/item_widgets.dart';

/// The only place where the list's order changes: the user drags items,
/// uses the arrows, or moves an item to a chosen position. Every change
/// is saved immediately.
class ReorderScreen extends StatelessWidget {
  const ReorderScreen({super.key});

  Future<void> _move(BuildContext context, int from, int to) async {
    final store = StoreScope.read(context);
    final ids = store.items.map((i) => i.id).toList();
    if (from == to || to < 0 || to >= ids.length) return;
    final id = ids.removeAt(from);
    ids.insert(to, id);
    await guard(context, () => store.saveOrder(ids));
  }

  Future<void> _moveTo(BuildContext context, int from, BucketItem item) async {
    final total = StoreScope.read(context).items.length;
    final controller = TextEditingController(text: '${from + 1}');
    final target = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move ${item.label}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'New place in the list (1–$total)',
          ),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, int.tryParse(controller.text)),
              child: const Text('Move')),
        ],
      ),
    );
    if (target == null || !context.mounted) return;
    await _move(context, from, target.clamp(1, total) - 1);
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final items = store.items;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reorder'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done')),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Drag the handle, use the arrows, or tap a row to move it to a '
              'specific place. Numbers stay with their items. Changes are '
              'saved right away.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: 40),
              itemCount: items.length,
              // newIndex is already adjusted for the removed item.
              onReorderItem: (oldIndex, newIndex) =>
                  _move(context, oldIndex, newIndex),
              itemBuilder: (context, index) {
                final item = items[index];
                return Material(
                  key: ValueKey(item.id),
                  color: theme.colorScheme.surface,
                  child: ListTile(
                    onTap: () => _moveTo(context, index, item),
                    contentPadding: const EdgeInsets.only(left: 4, right: 8),
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.drag_indicator_rounded),
                      ),
                    ),
                    title: Row(children: [
                      SizedBox(
                          width: 58,
                          child: NumberLabel(item.number,
                              size: 17, completed: item.isCompleted)),
                      Expanded(
                        child: Text(item.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ]),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(left: 58),
                      child: Text('Place ${count(index + 1)}'),
                    ),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Move up',
                        onPressed: index == 0
                            ? null
                            : () => _move(context, index, index - 1),
                        icon: const Icon(Icons.keyboard_arrow_up_rounded),
                      ),
                      IconButton(
                        tooltip: 'Move down',
                        onPressed: index == items.length - 1
                            ? null
                            : () => _move(context, index, index + 1),
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      ),
                    ]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
