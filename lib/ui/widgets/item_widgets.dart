import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../formatting.dart';
import '../theme.dart';

/// The item's number, given strong visual presence.
class NumberLabel extends StatelessWidget {
  const NumberLabel(
    this.number, {
    super.key,
    this.size = 22,
    this.completed = false,
  });

  final int number;
  final double size;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = formatNumber(number);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '#',
            style: TextStyle(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          TextSpan(text: text.substring(1)),
        ],
      ),
      style: display(
        size,
        weight: 600,
        color: completed ? scheme.primary : scheme.secondary,
      ),
    );
  }
}

/// Round check mark: filled when completed.
class CompletionMark extends StatelessWidget {
  const CompletionMark({super.key, required this.completed, this.size = 28});

  final bool completed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: completed ? scheme.primary : Colors.transparent,
        border: Border.all(
          color: completed ? scheme.primary : scheme.outline,
          width: 2,
        ),
      ),
      child: completed
          ? Icon(Icons.check_rounded, size: size * 0.7, color: scheme.onPrimary)
          : null,
    );
  }
}

/// One row of the list.
class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    required this.memoryCount,
    required this.onTap,
    this.onToggle,
    this.selected = false,
  });

  final BucketItem item;
  final int memoryCount;
  final VoidCallback onTap;

  /// Shown next to the list (wide screens): highlighted.
  final bool selected;

  /// Null for a read-only row (an archived journey).
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      color: selected ? scheme.secondaryContainer : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 66,
                child: NumberLabel(item.number, completed: item.isCompleted),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (item.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          item.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (memoryCount > 0 || item.isCompleted)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: DefaultTextStyle(
                          style: theme.textTheme.labelSmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          child: Wrap(
                            spacing: 10,
                            children: [
                              if (item.isCompleted && item.completedOn != null)
                                Text('Done ${shortDate(item.completedOn!)}'),
                              if (memoryCount > 0)
                                Text(plural(memoryCount, 'memory', 'memories')),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (onToggle != null)
                IconButton(
                  tooltip: item.isCompleted
                      ? 'Mark as not completed'
                      : 'Mark as completed',
                  onPressed: onToggle,
                  icon: CompletionMark(completed: item.isCompleted),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Semantics(
                    label: item.isCompleted ? 'Completed' : 'Not completed',
                    child: CompletionMark(completed: item.isCompleted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Completed / remaining / percentage, with an optional compact level
/// row underneath.
class ProgressHeader extends StatelessWidget {
  const ProgressHeader({
    super.key,
    required this.completed,
    required this.listed,
    this.footer,
  });

  final int completed;
  final int listed;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fraction = completed / maxItems;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: 76,
                  height: 76,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: fraction),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => Stack(
                      fit: StackFit.expand,
                      children: [
                        CircularProgressIndicator(
                          value: value == 0 ? 0 : value.clamp(0.012, 1.0),
                          strokeWidth: 8,
                          strokeCap: StrokeCap.round,
                          backgroundColor: scheme.surfaceContainer,
                        ),
                        Center(
                          child: Text(
                            percent(completed, maxItems),
                            style: display(15, color: scheme.primary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: count(completed),
                              style: display(30, color: scheme.secondary),
                            ),
                            TextSpan(
                              text: ' / ${count(maxItems)}',
                              style: display(
                                18,
                                weight: 500,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text('completed', style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 6),
                      Text(
                        '${count(maxItems - completed)} remaining · '
                        '${count(listed)} written down',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (footer != null) ...[const Divider(height: 22), footer!],
          ],
        ),
      ),
    );
  }
}
