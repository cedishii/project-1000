/// Levels and EXP. Nothing here is stored: everything is derived from
/// how many things on the current journey's list are completed, so the
/// numbers always match the list and can't be farmed.
library;

import 'models.dart';

/// Every completed thing is worth exactly this much EXP. No bonuses.
const int expPerThing = 1000;

/// EXP needed per level: every 10 completed things = +1 level.
const int expPerLevel = 10000;

const int maxLevel = 100;

/// A full journey: 1,000 things × 1,000 EXP.
const int maxExp = maxItems * expPerThing;

/// Levels that mark a milestone (10, 50, 100, 250, 500, 750, 1,000 things).
const List<int> milestoneLevels = [1, 5, 10, 25, 50, 75, 100];

/// Progress on one journey, from its number of completed things.
class Progression {
  Progression(int completed) : completed = completed.clamp(0, maxItems);

  final int completed;

  int get exp => completed * expPerThing;

  /// floor(EXP / 10,000), between 0 and 100.
  int get level => (exp ~/ expPerLevel).clamp(0, maxLevel);

  bool get isMaxLevel => level >= maxLevel;

  /// EXP earned within the current level (0–9,999); 10,000 at Level 100.
  int get expIntoLevel => isMaxLevel ? expPerLevel : exp - level * expPerLevel;

  int get expToNextLevel => isMaxLevel ? 0 : expPerLevel - expIntoLevel;

  double get levelFraction => expIntoLevel / expPerLevel;

  double get journeyFraction => completed / maxItems;

  int get remaining => maxItems - completed;

  /// 1,000 / 1,000: the journey is finished.
  bool get isComplete => completed >= maxItems;

  /// Things needed to reach [level].
  static int thingsForLevel(int level) => level * expPerLevel ~/ expPerThing;
}
