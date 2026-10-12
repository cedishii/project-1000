import 'package:flutter/material.dart';

import '../../services/cloud/friends.dart';
import '../formatting.dart';
import '../widgets/item_widgets.dart';
import 'friends_screen.dart';

/// A friend's shared bucket list: read-only, in their own order, without
/// memories or photos. If they make it private (or the friendship ends)
/// the next load shows that it's private.
class FriendListScreen extends StatefulWidget {
  const FriendListScreen({super.key, required this.api, required this.person});

  final FriendsApi api;
  final Person person;

  @override
  State<FriendListScreen> createState() => _FriendListScreenState();
}

class _FriendListScreenState extends State<FriendListScreen> {
  late Future<List<SharedItem>> _items = widget.api.sharedList(
    widget.person.userId,
  );

  Future<void> _reload() async {
    final next = widget.api.sharedList(widget.person.userId);
    setState(() {
      _items = next;
    });
    await next.catchError((Object _) => <SharedItem>[]);
  }

  void _show(SharedItem item) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NumberLabel(item.number, completed: item.isCompleted),
            const SizedBox(height: 8),
            Text(item.title, style: Theme.of(context).textTheme.titleLarge),
            if (item.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(item.description),
            ],
            const SizedBox(height: 12),
            Text(
              item.isCompleted
                  ? item.completedOn == null
                        ? 'Done'
                        : 'Done ${longDate(item.completedOn!)}'
                  : 'Not done yet',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final name = widget.person.displayName;
    return Scaffold(
      appBar: AppBar(title: Text('$name\'s list')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<SharedItem>>(
          future: _items,
          builder: (context, snap) {
            final error = snap.error;
            if (error is FriendsException && error.code == 'list_not_shared') {
              return EmptyHint(
                icon: Icons.lock_outline_rounded,
                text: '$name\'s list is private.',
              );
            }
            if (error != null) {
              return ErrorRetry(error: error, onRetry: _reload);
            }
            final items = snap.data;
            if (items == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (items.isEmpty) {
              return EmptyHint(
                icon: Icons.checklist_rounded,
                text: '$name\'s list is empty so far.',
              );
            }
            final done = items.where((i) => i.isCompleted).length;
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: items.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                    child: Text(
                      '${count(done)} of ${count(items.length)} done · read-only',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  );
                }
                final item = items[i - 1];
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _show(item),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 66,
                            child: NumberLabel(
                              item.number,
                              completed: item.isCompleted,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Semantics(
                            label: item.isCompleted
                                ? 'Completed'
                                : 'Not completed',
                            child: CompletionMark(completed: item.isCompleted),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
