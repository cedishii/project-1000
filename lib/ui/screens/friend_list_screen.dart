import 'package:flutter/material.dart';

import '../../services/cloud/friends.dart';
import '../formatting.dart';
import '../theme.dart';
import '../widgets/item_widgets.dart';
import 'friends_screen.dart';

/// A friend's shared bucket list: read-only, in their own order. Memories
/// (and their photos) appear only if the friend shares them too. If they
/// make it private (or the friendship ends) the next load shows that.
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
    isScrollControlled: item.memoryCount > 0,
    builder: (context) => item.memoryCount > 0
        ? DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            maxChildSize: 0.95,
            builder: (context, scroll) => _ItemSheet(
              api: widget.api,
              person: widget.person,
              item: item,
              scroll: scroll,
            ),
          )
        : _ItemSheet(api: widget.api, person: widget.person, item: item),
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
            final scheme = Theme.of(context).colorScheme;
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
                          if (item.memoryCount > 0)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Semantics(
                                label: item.memoryCount == 1
                                    ? '1 memory'
                                    : '${item.memoryCount} memories',
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.auto_stories_outlined,
                                      size: 18,
                                      color: scheme.secondary,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '${item.memoryCount}',
                                      style: TextStyle(color: scheme.secondary),
                                    ),
                                  ],
                                ),
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

/// One entry of a friend's list, with its memories when they share them.
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({
    required this.api,
    required this.person,
    required this.item,
    this.scroll,
  });

  final FriendsApi api;
  final Person person;
  final SharedItem item;
  final ScrollController? scroll;

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  late Future<List<SharedMemory>>? _memories = _load();

  Future<List<SharedMemory>>? _load() => widget.item.memoryCount > 0
      ? widget.api.sharedMemories(widget.person.userId, widget.item.number)
      : null;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final header = [
      NumberLabel(item.number, completed: item.isCompleted),
      const SizedBox(height: 8),
      Text(item.title, style: theme.textTheme.titleLarge),
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
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
    ];
    if (_memories == null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: header,
          ),
        ),
      );
    }
    return FutureBuilder<List<SharedMemory>>(
      future: _memories,
      builder: (context, snap) {
        final memories = snap.data;
        final error = snap.error;
        return ListView(
          controller: widget.scroll,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          children: [
            ...header,
            const SizedBox(height: 16),
            if (error is FriendsException &&
                error.code == 'memories_not_shared')
              EmptyHint(
                icon: Icons.lock_outline_rounded,
                text: '${widget.person.displayName}\'s memories are private.',
              )
            else if (error != null)
              ErrorRetry(
                error: error,
                onRetry: () => setState(() {
                  _memories = _load();
                }),
              )
            else if (memories == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              for (final (i, m) in memories.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SharedMemoryCard(
                    api: widget.api,
                    owner: widget.person.userId,
                    memory: m,
                    index: i + 1,
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// A friend's memory, laid out like the owner's own (MemoryCard), but
/// read-only and with photos fetched from the friend's shared storage.
class _SharedMemoryCard extends StatelessWidget {
  const _SharedMemoryCard({
    required this.api,
    required this.owner,
    required this.memory,
    required this.index,
  });

  final FriendsApi api;
  final String owner;
  final SharedMemory memory;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final px = (110 * MediaQuery.devicePixelRatioOf(context)).round();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Memory #$index',
                  style: display(14, weight: 500, color: scheme.secondary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    longDate(memory.date),
                    style: muted,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (memory.title.isNotEmpty) ...[
              Text(memory.title, style: display(20, weight: 500)),
              const SizedBox(height: 6),
            ],
            if (memory.body.isNotEmpty)
              Text(
                memory.body,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
              ),
            if (memory.photos.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 110,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: memory.photos.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox.square(
                      dimension: 110,
                      child: Material(
                        color: scheme.surfaceContainer,
                        child: InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => _FriendPhotoViewer(
                                api: api,
                                owner: owner,
                                photos: memory.photos,
                                initialIndex: i,
                              ),
                            ),
                          ),
                          child: Ink.image(
                            image: ResizeImage(
                              api.photo(owner, memory.photos[i].thumb),
                              width: px,
                              policy: ResizeImagePolicy.fit,
                            ),
                            fit: BoxFit.cover,
                            onImageError: (_, _) {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (memory.location.isNotEmpty || memory.hashtags.isNotEmpty)
              const SizedBox(height: 12),
            if (memory.location.isNotEmpty)
              Row(
                children: [
                  Icon(
                    Icons.place_outlined,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(child: Text(memory.location, style: muted)),
                ],
              ),
            if (memory.hashtags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    for (final t in memory.hashtags)
                      Text(
                        '#$t',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A friend's memory photos, full screen, with swipe and pinch-to-zoom.
class _FriendPhotoViewer extends StatefulWidget {
  const _FriendPhotoViewer({
    required this.api,
    required this.owner,
    required this.photos,
    required this.initialIndex,
  });

  final FriendsApi api;
  final String owner;
  final List<SharedPhoto> photos;
  final int initialIndex;

  @override
  State<_FriendPhotoViewer> createState() => _FriendPhotoViewerState();
}

class _FriendPhotoViewerState extends State<_FriendPhotoViewer> {
  late final _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final maxPx = (size.longestSide * MediaQuery.devicePixelRatioOf(context))
        .round();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: widget.photos.length > 1
            ? Text(
                '${_index + 1} / ${widget.photos.length}',
                style: const TextStyle(color: Colors.white),
              )
            : null,
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.photos.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => InteractiveViewer(
          maxScale: 5,
          child: Center(
            child: Image(
              image: ResizeImage(
                widget.api.photo(widget.owner, widget.photos[i].file),
                width: maxPx,
                height: maxPx,
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.contain,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
              errorBuilder: (_, _, _) => const Center(
                child: Text(
                  'This photo can\'t be shown.',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
