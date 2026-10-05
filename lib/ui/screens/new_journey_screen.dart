import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../backup_flows.dart';
import '../feedback.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../theme.dart';

/// Archives the finished journey and begins the next. The user must
/// choose how the new list starts; nothing is decided for them, and the
/// finished journey is kept in full.
class NewJourneyScreen extends StatefulWidget {
  const NewJourneyScreen({super.key});

  @override
  State<NewJourneyScreen> createState() => _NewJourneyScreenState();
}

class _NewJourneyScreenState extends State<NewJourneyScreen> {
  bool? _reuse;
  CalendarDate _start = CalendarDate.today();
  bool _busy = false;

  Future<void> _pickStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _start.toDateTime(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
      helpText: 'New journey starts on',
    );
    if (picked != null) {
      setState(() => _start = CalendarDate.fromDateTime(picked));
    }
  }

  Future<void> _archiveAndStart() async {
    final store = StoreScope.read(context);
    final old = store.journey.number;
    setState(() => _busy = true);
    final ok = await guard(
      context,
      () => store.startNewJourney(newStartedOn: _start, reuseList: _reuse!),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    showMessage(
      context,
      'Journey ${old + 1} has begun. Journey $old is kept safe in your '
      'Journey History.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final n = store.journey.number;
    final ready = store.progression.isComplete;

    Widget bullet(String text) => Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Row(
        children: [
          Icon(Icons.check_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('New journey')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text('START A NEW JOURNEY?', style: display(26)),
          const SizedBox(height: 12),
          Text(
            'Journey $n will be preserved in your Journey History.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 12),
          const Text('Your previous:'),
          const SizedBox(height: 6),
          bullet('Bucket-list items, numbers and order'),
          bullet('Completion dates'),
          bullet('Memories, comments and hashtags'),
          bullet('Photos'),
          bullet('Life Album'),
          const SizedBox(height: 4),
          const Text('will remain available, read-only, forever.'),
          const SizedBox(height: 28),
          Text('How should Journey ${n + 1} begin?', style: display(18)),
          const SizedBox(height: 10),
          _Choice(
            selected: _reuse == true,
            icon: Icons.content_copy_rounded,
            title: 'Reuse my list',
            text:
                'Copy Journey $n\'s things — numbers, titles, descriptions and '
                'order — into Journey ${n + 1}. Everything starts not '
                'completed, with no memories or photos.',
            onTap: () => setState(() => _reuse = true),
          ),
          const SizedBox(height: 10),
          _Choice(
            selected: _reuse == false,
            icon: Icons.edit_note_rounded,
            title: 'Start with a new list',
            text:
                'Journey ${n + 1} begins empty. You write a new list, one '
                'thing at a time.',
            onTap: () => setState(() => _reuse = false),
          ),
          const SizedBox(height: 20),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_rounded),
            title: Text('Journey ${n + 1} starts on'),
            subtitle: Text(longDate(_start)),
            trailing: TextButton(
              onPressed: _pickStart,
              child: const Text('Change'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tip: make a backup first, so your whole history is also safe '
            'outside this phone.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => exportFlow(context),
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Back up first'),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: !ready || _reuse == null || _busy
                ? null
                : _archiveAndStart,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Text('ARCHIVE & START NEW JOURNEY'),
          ),
          if (_reuse == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Choose how the new list begins.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.selected,
    required this.icon,
    required this.title,
    required this.text,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: display(17, weight: 500)),
                      const SizedBox(height: 4),
                      Text(text),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? scheme.primary : scheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
