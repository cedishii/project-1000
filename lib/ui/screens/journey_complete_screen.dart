import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/progression.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../theme.dart';
import '../widgets/emblem.dart';
import 'journey_screen.dart';
import 'life_album_screen.dart';
import 'new_journey_screen.dart';

/// Shown when the 1,000th thing is completed. Nothing is reset or
/// archived here: the user decides what happens next.
class JourneyCompleteScreen extends StatelessWidget {
  const JourneyCompleteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final p = store.progression;
    final journey = store.journey;
    final scheme = Theme.of(context).colorScheme;
    final started = store.startOf(journey);
    final finished = store.lastCompletedOn;
    final animate = !MediaQuery.disableAnimationsOf(context);

    if (!p.isComplete) {
      // A thing was marked not completed while this was open.
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              '${count(p.completed)} / ${count(maxItems)} things completed.',
              style: display(20),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    Widget line(String text, {double size = 22, Color? color}) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: display(size, color: color),
        textAlign: TextAlign.center,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text('Journey ${journey.number}'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: animate ? 0.6 : 1, end: 1),
                    duration: animate
                        ? const Duration(milliseconds: 900)
                        : Duration.zero,
                    curve: Curves.elasticOut,
                    builder: (context, v, child) =>
                        Transform.scale(scale: v, child: child),
                    child: const Emblem(size: 110),
                  ),
                  const SizedBox(height: 24),
                  line('YOU DID IT.', size: 40, color: scheme.secondary),
                  const SizedBox(height: 14),
                  line('LEVEL $maxLevel', size: 28, color: scheme.primary),
                  line('${count(maxItems)} / ${count(maxItems)} THINGS'),
                  line('${count(maxExp)} EXP'),
                  line('100% COMPLETE'),
                  if (started != null || finished != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      '${started == null ? '' : longDate(started)} → '
                      '${finished == null ? '' : longDate(finished)}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => JourneyScreen(journeyId: journey.id),
                        ),
                      ),
                      icon: const Icon(Icons.flag_rounded),
                      label: const Text('VIEW MY JOURNEY'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              LifeAlbumScreen(journeyId: journey.id),
                        ),
                      ),
                      icon: const Icon(Icons.auto_stories_rounded),
                      label: const Text('VIEW LIFE ALBUM'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: () => openNewJourney(context),
                      icon: const Icon(Icons.restart_alt_rounded),
                      label: const Text('START A NEW JOURNEY'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Nothing changes until you choose. Your list stays exactly '
                    'as it is.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void openNewJourney(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute(builder: (_) => const NewJourneyScreen()),
);

/// A small banner for when the journey is finished but no new one has
/// been started yet.
class JourneyCompleteBanner extends StatelessWidget {
  const JourneyCompleteBanner({super.key, required this.journey});

  final Journey journey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => const JourneyCompleteScreen(),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Icons.emoji_events_rounded,
                color: scheme.onSecondaryContainer,
                size: 32,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Journey ${journey.number} complete',
                      style: display(18, color: scheme.onSecondaryContainer),
                    ),
                    Text(
                      'Level 100 · 1,000 / 1,000. What\'s next?',
                      style: TextStyle(color: scheme.onSecondaryContainer),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSecondaryContainer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
