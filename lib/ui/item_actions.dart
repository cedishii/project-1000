import 'package:flutter/material.dart';

import '../data/models.dart';
import 'feedback.dart';
import 'formatting.dart';
import 'level_up.dart';
import 'screens/journey_complete_screen.dart';
import 'store_scope.dart';
import 'theme.dart';

/// Marks an item completed (asking for the date) or not completed
/// (asking for confirmation). The item never moves in the list.
///
/// Completing a thing earns 1,000 EXP; crossing a level shows a brief
/// level-up note, and the 1,000th thing opens the journey-complete
/// screen. Un-completing simply recalculates (EXP is always derived from
/// the list, so it can't be farmed).
Future<void> toggleCompletion(BuildContext context, BucketItem item) async {
  final store = StoreScope.read(context);
  if (item.isCompleted) {
    final ok = await confirm(
      context,
      title: 'Mark ${item.label} as not completed?',
      message: item.completedOn == null
          ? 'You can mark it completed again any time.'
          : 'The completion date (${longDate(item.completedOn!)}) will be '
                'kept on record, and offered again if you complete it later.',
      confirmLabel: 'Mark not completed',
    );
    if (!ok || !context.mounted) return;
    await guard(context, () => store.setCompleted(item.id, false));
    return;
  }

  final date = await pickCompletionDate(context, item);
  if (date == null || !context.mounted) return;
  final before = store.progression;
  final ok = await guard(
    context,
    () => store.setCompleted(item.id, true, on: date),
  );
  if (!ok || !context.mounted) return;
  final after = store.progression;
  if (after.isComplete && !before.isComplete) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const JourneyCompleteScreen(),
      ),
    );
  } else if (after.level > before.level) {
    showLevelUp(context, from: before.level, to: after.level);
  }
}

/// Bottom sheet: "Completed on [date]". Defaults to today, or to the
/// earlier completion date if the item had one.
Future<CalendarDate?> pickCompletionDate(
  BuildContext context,
  BucketItem item,
) {
  return showModalBottomSheet<CalendarDate>(
    context: context,
    showDragHandle: true,
    builder: (context) => _CompletionSheet(item: item),
  );
}

class _CompletionSheet extends StatefulWidget {
  const _CompletionSheet({required this.item});

  final BucketItem item;

  @override
  State<_CompletionSheet> createState() => _CompletionSheetState();
}

class _CompletionSheetState extends State<_CompletionSheet> {
  late CalendarDate _date = widget.item.completedOn ?? CalendarDate.today();

  Future<void> _change() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.toDateTime(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
      helpText: 'Completed on',
    );
    if (picked != null) {
      setState(() => _date = CalendarDate.fromDateTime(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.item.label,
              style: display(18, color: theme.colorScheme.secondary),
            ),
            const SizedBox(height: 4),
            Text(widget.item.title, style: display(22)),
            const SizedBox(height: 20),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_available_rounded),
              title: const Text('Completed on'),
              subtitle: Text(longDate(_date)),
              trailing: TextButton(
                onPressed: _change,
                child: const Text('Change'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, _date),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Mark as completed'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for confirmation, then permanently deletes the item with its
/// memories and photos. Returns true if deleted.
Future<bool> deleteItemFlow(BuildContext context, BucketItem item) async {
  final store = StoreScope.read(context);
  final memories = store.memoryCountOf(item.id);
  final ok = await confirm(
    context,
    title: 'Delete ${item.label}?',
    message:
        '"${item.title}"'
        '${memories > 0 ? ' and its ${plural(memories, 'memory', 'memories')} (with photos)' : ''}'
        ' will be permanently deleted. This can\'t be undone.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!ok || !context.mounted) return false;
  return guard(context, () => store.deleteItem(item.id));
}
