/// Plain data classes for the archive. They know nothing about the UI or
/// the database layout.
library;

/// Maximum number of things on the list.
const int maxItems = 1000;

/// A calendar date with no time or time zone (e.g. a completion day).
///
/// Stored as `yyyy-MM-dd` so a date never shifts when the phone changes
/// time zones, and stays readable in exported backups for decades.
class CalendarDate implements Comparable<CalendarDate> {
  const CalendarDate(this.year, this.month, this.day);

  factory CalendarDate.fromDateTime(DateTime d) =>
      CalendarDate(d.year, d.month, d.day);

  factory CalendarDate.today() => CalendarDate.fromDateTime(DateTime.now());

  /// Parses `yyyy-MM-dd`. Throws [FormatException] on anything else.
  factory CalendarDate.parse(String s) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (m == null) throw FormatException('Invalid date', s);
    final d = CalendarDate(
        int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    final check = d.toDateTime();
    if (check.year != d.year || check.month != d.month || check.day != d.day) {
      throw FormatException('Invalid date', s);
    }
    return d;
  }

  final int year;
  final int month;
  final int day;

  DateTime toDateTime() => DateTime(year, month, day);

  String toIso() => '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

  @override
  int compareTo(CalendarDate other) => toIso().compareTo(other.toIso());

  @override
  bool operator ==(Object other) =>
      other is CalendarDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => toIso();
}

/// One thing on the list.
class BucketItem {
  const BucketItem({
    required this.id,
    required this.number,
    required this.position,
    required this.title,
    required this.description,
    required this.isCompleted,
    required this.completedOn,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Stable unique ID (UUID). Never changes.
  final String id;

  /// The item's number, #1–#1000. Belongs to the item for its whole life:
  /// never renumbered when other items move or are deleted.
  final int number;

  /// Where the item sits in the user's list (0 = top). Only ever changed
  /// by the user reordering explicitly.
  final int position;

  final String title;
  final String description;
  final bool isCompleted;

  /// The day it was completed. Kept even if the item is later marked not
  /// completed, so that history is never silently lost.
  final CalendarDate? completedOn;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// `#001` … `#1000`.
  String get label => formatNumber(number);
}

String formatNumber(int n) => '#${n.toString().padLeft(3, '0')}';

/// A journal entry attached to an item.
class Memory {
  const Memory({
    required this.id,
    required this.itemId,
    required this.position,
    required this.title,
    required this.body,
    required this.date,
    required this.location,
    required this.hashtags,
    required this.photos,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String itemId;

  /// Order among the item's memories (the order they were added).
  final int position;
  final String title;
  final String body;
  final CalendarDate date;
  final String location;

  /// Normalised tags without the leading `#`, in the order entered.
  final List<String> hashtags;
  final List<PhotoRef> photos;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// A photo stored inside the archive folder.
class PhotoRef {
  const PhotoRef({
    required this.id,
    required this.memoryId,
    required this.position,
    required this.file,
    required this.thumb,
    required this.width,
    required this.height,
    required this.createdAt,
  });

  final String id;
  final String memoryId;
  final int position;

  /// Paths relative to the archive folder, e.g. `photos/<id>.jpg`.
  final String file;
  final String thumb;
  final int? width;
  final int? height;
  final DateTime createdAt;
}

/// Turns user input like "#Travel, japan  #dream" into
/// `[travel, japan, dream]`: lowercase, no `#`, no duplicates.
List<String> parseHashtags(String input) {
  final out = <String>[];
  for (final m in RegExp(r'[\p{L}\p{N}_]+', unicode: true).allMatches(input)) {
    final tag = m[0]!.toLowerCase();
    if (!out.contains(tag)) out.add(tag);
  }
  return out;
}
