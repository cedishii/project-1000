import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../formatting.dart';
import '../theme.dart';
import 'photo_widgets.dart';

/// One memory, shown like a page in a journal.
class MemoryCard extends StatelessWidget {
  const MemoryCard({
    super.key,
    required this.memory,
    required this.index,
    this.onEdit,
    this.onDelete,
  });

  final Memory memory;

  /// 1-based number of this memory within its item.
  final int index;

  /// Both null for a read-only memory (an archived journey).
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 6, 16),
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
                  if (onEdit != null && onDelete != null)
                    PopupMenuButton<String>(
                      tooltip: 'Memory options',
                      onSelected: (v) => v == 'edit' ? onEdit!() : onDelete!(),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    )
                  else
                    const SizedBox(height: 40),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (memory.title.isNotEmpty) ...[
                      Text(memory.title, style: display(20, weight: 500)),
                      const SizedBox(height: 6),
                    ],
                    if (memory.body.isNotEmpty)
                      Text(
                        memory.body,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.55,
                        ),
                      ),
                    if (memory.photos.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _PhotoStrip(photos: memory.photos),
                    ],
                    if (memory.location.isNotEmpty ||
                        memory.hashtags.isNotEmpty)
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
            ],
          ),
        ),
      ),
    );
  }
}

/// A horizontal, lazily built row of thumbnails.
class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({required this.photos});

  final List<PhotoRef> photos;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 110,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => PhotoThumb(
          photo: photos[i],
          size: 110,
          onTap: () => openPhotoViewer(context, photos, i),
        ),
      ),
    );
  }
}
