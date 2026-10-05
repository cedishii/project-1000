import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/progression.dart';
import '../formatting.dart';
import '../journey_facts.dart';
import '../store_scope.dart';
import '../theme.dart';
import '../widgets/level_widgets.dart';
import 'journey_complete_screen.dart';
import 'journey_screen.dart';
import 'life_album_screen.dart';
import 'profile_editor_screen.dart';

/// The user's private profile and life-progress dashboard: who they are,
/// their level and EXP on the current journey, and every journey so far.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Future<List<JourneySummary>>? _summaries;
  String? _loadedKey;

  void _loadIfNeeded() {
    final store = StoreScope.of(context);
    final key =
        '${store.journeyRevision}/${store.memoryRevision}/'
        '${store.completedCount}/${store.items.length}';
    if (key != _loadedKey) {
      _loadedKey = key;
      _summaries = store.journeySummaries();
    }
  }

  void _edit() => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const ProfileEditorScreen()),
  );

  @override
  Widget build(BuildContext context) {
    _loadIfNeeded();
    final store = StoreScope.of(context);
    final p = store.progression;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            tooltip: 'Edit profile',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _edit,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          _Identity(profile: store.profile, onEdit: _edit),
          const SizedBox(height: 20),
          if (p.isComplete) ...[
            JourneyCompleteBanner(journey: store.journey),
            const SizedBox(height: 12),
          ],
          _LevelCard(progression: p),
          const SizedBox(height: 12),
          _JourneyCard(
            journey: store.journey,
            started: store.startOf(store.journey),
            progression: p,
          ),
          const SizedBox(height: 12),
          _Milestones(progression: p),
          FutureBuilder<List<JourneySummary>>(
            future: _summaries,
            builder: (context, snap) {
              final all = snap.data;
              if (all == null) return const SizedBox(height: 40);
              return _History(summaries: all);
            },
          ),
        ],
      ),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.profile, required this.onEdit});

  final Profile profile;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final details = [
      if (profile.age != null) 'Age ${profile.age}',
      if (profile.startedOn != null) 'Started ${longDate(profile.startedOn!)}',
    ];
    return Column(
      children: [
        ProfileAvatar(profile: profile, size: 104),
        const SizedBox(height: 14),
        if (profile.name.isEmpty && profile.nickname.isEmpty)
          TextButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.person_add_alt_rounded),
            label: const Text('Add your name and photo'),
          )
        else ...[
          Text(
            profile.name.isNotEmpty ? profile.name : profile.nickname,
            style: display(26),
            textAlign: TextAlign.center,
          ),
          if (profile.nickname.isNotEmpty &&
              profile.name.isNotEmpty &&
              profile.nickname != profile.name)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '"${profile.nickname}"',
                style: display(17, weight: 500, color: scheme.secondary),
              ),
            ),
        ],
        if (details.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              details.join('  ·  '),
              style: muted,
              textAlign: TextAlign.center,
            ),
          ),
        if (profile.bio.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Text(
              profile.bio,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

/// Current level and progress toward the next one.
class _LevelCard extends StatelessWidget {
  const _LevelCard({required this.progression});

  final Progression progression;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = progression;
    final small = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                LevelNumber(level: p.level, size: 68),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${count(p.exp)} EXP',
                      style: display(24, color: scheme.primary),
                    ),
                    Text('of ${count(maxExp)}', style: small),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              p.isMaxLevel ? 'MAX LEVEL' : 'PROGRESS TO LEVEL ${p.level + 1}',
              style: small?.copyWith(letterSpacing: 1.2),
            ),
            const SizedBox(height: 8),
            LevelBar(
              value: p.levelFraction,
              height: 14,
              color: scheme.secondary,
              semanticsLabel: p.isMaxLevel
                  ? 'Maximum level reached'
                  : 'Progress to level ${p.level + 1}',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${count(p.expIntoLevel)} / ${count(expPerLevel)} EXP',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  p.isMaxLevel
                      ? '${count(maxExp)} EXP'
                      : '${count(p.expToNextLevel)} EXP TO LEVEL ${p.level + 1}',
                  style: small,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Overall progress through the current journey's 1,000 things.
class _JourneyCard extends StatelessWidget {
  const _JourneyCard({
    required this.journey,
    required this.started,
    required this.progression,
  });

  final Journey journey;
  final CalendarDate? started;
  final Progression progression;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = progression;

    Widget stat(String value, String label) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: display(20, color: scheme.onSurface)),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'YOUR JOURNEY  ·  JOURNEY ${journey.number}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.primary,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: count(p.completed),
                    style: display(34, color: scheme.secondary),
                  ),
                  TextSpan(
                    text: ' / ${count(maxItems)} THINGS',
                    style: display(
                      18,
                      weight: 500,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            LevelBar(
              value: p.journeyFraction,
              height: 14,
              semanticsLabel: 'Journey progress',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                stat(percent(p.completed, maxItems), 'COMPLETE'),
                stat(count(p.remaining), 'THINGS REMAINING'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                stat(count(p.exp), '/ ${count(maxExp)} EXP'),
                stat('${p.level}', 'LEVEL'),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              started == null
                  ? 'Start date not set — add it in your profile.'
                  : 'Since ${longDate(started!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LifeAlbumScreen(journeyId: journey.id),
                    ),
                  ),
                  icon: const Icon(Icons.auto_stories_rounded),
                  label: Text(
                    p.isComplete ? 'Life Album' : 'Life Album so far',
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => JourneyScreen(journeyId: journey.id),
                    ),
                  ),
                  child: const Text('Journey details'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The seven big milestones, marked with icons and words as well as
/// colour.
class _Milestones extends StatelessWidget {
  const _Milestones({required this.progression});

  final Progression progression;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MILESTONES',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.primary,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final level in milestoneLevels)
                  _Milestone(level: level, reached: progression.level >= level),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Milestone extends StatelessWidget {
  const _Milestone({required this.level, required this.reached});

  final int level;
  final bool reached;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final things = Progression.thingsForLevel(level);
    return Semantics(
      label:
          '${count(things)} things, level $level: '
          '${reached ? 'reached' : 'not reached yet'}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: reached ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: reached ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                reached
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 18,
                color: reached ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: 6),
              Text(
                '${count(things)} · Lv $level',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: reached
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Journey History and lifetime totals.
class _History extends StatelessWidget {
  const _History({required this.summaries});

  final List<JourneySummary> summaries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final store = StoreScope.read(context);
    final finished = summaries.where((s) => s.journey.isArchived).toList();
    final lifetimeThings = summaries.fold(0, (n, s) => n + s.completedCount);

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 28, 4, 10),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: scheme.primary,
          letterSpacing: 1.2,
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header('JOURNEY HISTORY'),
        for (final s in summaries) ...[
          _JourneyTile(facts: JourneyFacts.of(store, s)),
          const SizedBox(height: 8),
        ],
        if (finished.isNotEmpty) ...[
          header('LIFETIME'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${plural(finished.length, 'journey')} completed',
                    style: display(20),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${count(lifetimeThings)} things completed in all',
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    '${count(lifetimeThings * expPerThing)} lifetime EXP',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Lifetime EXP adds up every journey. It doesn\'t change '
                    'your level: each journey has its own 0 → '
                    '${count(maxExp)} EXP, and your level comes from the '
                    'current journey only.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _JourneyTile extends StatelessWidget {
  const _JourneyTile({required this.facts});

  final JourneyFacts facts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = facts.progress;
    final current = facts.journey.isActive;
    final s = facts.started, f = facts.finished;
    final dates =
        '${s == null ? 'Start not set' : monthYear(s)} → '
        '${current ? 'Present' : (f == null ? '' : monthYear(f))}';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => JourneyScreen(journeyId: facts.journey.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('JOURNEY ${facts.number}', style: display(18)),
                        const SizedBox(width: 8),
                        _Tag(
                          current ? 'CURRENT' : 'ARCHIVED',
                          color: current ? scheme.primary : scheme.secondary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${count(p.completed)} / ${count(maxItems)}  ·  '
                      'Level ${p.level}  ·  '
                      '${percent(p.completed, maxItems)} complete',
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      dates,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color),
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color,
        letterSpacing: 1,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
