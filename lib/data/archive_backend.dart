import 'dart:typed_data';

import 'archive_repository.dart';
import 'models.dart';

/// Where the archive is kept: on this phone ([LocalArchive], SQLite and
/// files) or in the signed-in cloud account (CloudArchive, Supabase).
///
/// [AppStore] holds the app's state and talks only to this interface, so
/// every screen works the same with either. Both implementations follow
/// the same rules (docs/CLOUD.md, "Shared business logic").
abstract interface class ArchiveBackend {
  Future<Journey> activeJourney();
  Future<Profile> loadProfile();

  /// The items of [journeyId] (default: the active journey) in the
  /// user's order.
  Future<List<BucketItem>> loadItems({String? journeyId});
  Future<Map<String, int>> memoryCounts({String? journeyId});
  Future<Set<String>> searchItemIds(String query, {String? journeyId});

  Future<BucketItem> addItem(String title, String description);
  Future<void> updateItemText(String id, String title, String description);
  Future<void> setCompleted(String id, bool completed, {CalendarDate? on});

  /// Deletes an item with its memories and their photo files.
  Future<void> deleteItem(String id);
  Future<void> saveOrder(List<String> orderedIds);

  Future<List<Memory>> loadMemories(String itemId);
  Future<List<Memory>> loadMemoriesByIds(List<String> ids);

  /// Saves a memory, storing its new (pending) photos first and removing
  /// photos it no longer has. Returns the memory's id.
  Future<String> saveMemory(MemoryDraft draft);
  Future<void> deleteMemory(String id);

  Future<List<JourneySummary>> journeySummaries();
  Future<List<AlbumEntry>> albumOutline(String journeyId);

  /// Sets the active journey's own start date (journeys after the first;
  /// Journey 1 uses the profile's date, see AppStore.setJourneyStart).
  Future<void> setJourneyStart(CalendarDate? date);

  /// Archives the finished active journey and begins the next one,
  /// keeping [profile] (with a copy of its picture) with the archived
  /// journey. Nothing is deleted.
  Future<Journey> startNewJourney({
    required CalendarDate? startedOn,
    required CalendarDate completedOn,
    required Profile profile,
    required CalendarDate newStartedOn,
    required bool reuseList,
  });

  /// Saves the profile's fields as given (including `photo`).
  Future<void> saveProfile(Profile profile);

  /// Stores [jpeg] as the profile picture of [current] and removes the
  /// old picture.
  Future<void> setProfilePhoto(Profile current, Uint8List jpeg);
  Future<void> removeProfilePhoto(Profile current);

  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
}
