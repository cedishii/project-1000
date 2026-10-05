import '../data/models.dart';
import '../data/progression.dart';
import '../state/app_store.dart';
import 'formatting.dart';

/// The facts about one journey, worded for display. Used by the profile,
/// the Life Album, its PDF and the completion screen, so they always say
/// the same thing. Everything comes from the user's own data.
class JourneyFacts {
  JourneyFacts._({
    required this.summary,
    required this.started,
    required this.finished,
    required this.profile,
  }) : progress = Progression(summary.completedCount);

  factory JourneyFacts.of(AppStore store, JourneySummary summary) {
    final j = summary.journey;
    final complete = summary.completedCount >= maxItems;
    return JourneyFacts._(
      summary: summary,
      started: store.startOf(j),
      finished: j.isArchived
          ? j.completedOn
          : (complete ? store.lastCompletedOn : null),
      // An archived journey shows the profile as it was back then.
      profile: j.isArchived ? (j.snapshot ?? const Profile()) : store.profile,
    );
  }

  final JourneySummary summary;
  final Progression progress;
  final CalendarDate? started;

  /// Null while the journey is still in progress.
  final CalendarDate? finished;
  final Profile profile;

  Journey get journey => summary.journey;
  int get number => journey.number;
  bool get isFinished => finished != null && progress.isComplete;

  String get startedText => started == null ? 'Not set' : longDate(started!);
  String get finishedText => finished == null ? 'Present' : longDate(finished!);

  /// "October 6, 2026 → June 14, 2031".
  String get datesLine => '$startedText → $finishedText';

  /// "4 years, 8 months, 8 days", or null without a start date.
  String? get duration {
    final s = started;
    if (s == null) return null;
    final end = finished ?? CalendarDate.today();
    if (end.compareTo(s) < 0) return null;
    return durationText(s, end);
  }

  /// Label → value rows: the journey summary.
  List<(String, String)> get rows => [
    ('Started', startedText),
    (
      isFinished ? 'Finished' : 'Status',
      isFinished ? finishedText : 'In progress',
    ),
    if (duration != null) (isFinished ? 'Duration' : 'So far', duration!),
    ('Things completed', '${count(progress.completed)} / ${count(maxItems)}'),
    ('EXP earned', count(progress.exp)),
    (isFinished ? 'Final level' : 'Level', 'Level ${progress.level}'),
    ('Completion', percent(progress.completed, maxItems)),
    ('Memories', count(summary.memoryCount)),
    ('Photos', count(summary.photoCount)),
  ];

  String get closingTitle =>
      isFinished ? 'THAT WAS JOURNEY $number.' : 'JOURNEY $number, SO FAR.';

  List<String> get closingLines => [
    '${count(progress.completed)} ${progress.completed == 1 ? 'THING' : 'THINGS'}.',
    '${count(progress.exp)} EXP.',
    'LEVEL ${progress.level}.',
    '${percent(progress.completed, maxItems)} COMPLETE.',
  ];

  List<(String, String)> get closingFacts => [
    ('Started', startedText),
    if (isFinished) ('Completed', finishedText),
  ];
}

/// Years, months and days from [a] to [b] (b not before a).
String durationText(CalendarDate a, CalendarDate b) {
  var years = b.year - a.year;
  var months = b.month - a.month;
  var days = b.day - a.day;
  if (days < 0) {
    months--;
    // Days in the month before b's month.
    days += DateTime(b.year, b.month, 0).day;
  }
  if (months < 0) {
    years--;
    months += 12;
  }
  final parts = [
    if (years > 0) plural(years, 'year'),
    if (months > 0) plural(months, 'month'),
    if (days > 0) plural(days, 'day'),
  ];
  return parts.isEmpty ? 'Less than a day' : parts.join(', ');
}
