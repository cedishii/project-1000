import 'package:flutter_test/flutter_test.dart';
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/state/app_store.dart';
import 'package:project_1000/state/list_view_filter.dart';

import 'helpers.dart';

void main() {
  late TestArchive archive;
  late AppStore store;

  setUp(() async {
    archive = await TestArchive.create();
    store = await archive.open();
    // #001 incomplete, #002 completed, #003 incomplete, #004 completed,
    // #005 incomplete — then manually reordered so order != number order.
    for (final t in ['Learn Japanese', 'Visit Japan', 'Learn to swim',
        'See the Northern Lights', 'Build a house']) {
      await store.addItem(t, t == 'Visit Japan' ? 'Tokyo and Kyoto' : '');
    }
    await store.setCompleted(store.items[1].id, true);
    await store.setCompleted(store.items[3].id, true);
    final ids = store.items.map((i) => i.id).toList();
    await store.saveOrder([ids[4], ids[0], ids[1], ids[2], ids[3]]);
  });
  tearDown(() => archive.dispose());

  List<int> numbers(List<BucketItem> items) =>
      items.map((i) => i.number).toList();

  test('filters show matching rows in the saved order', () {
    final items = store.items;
    expect(numbers(items), [5, 1, 2, 3, 4]);
    expect(numbers(visibleItems(items, filter: ListFilter.completed)), [2, 4]);
    expect(numbers(visibleItems(items, filter: ListFilter.notCompleted)),
        [5, 1, 3]);
    expect(numbers(visibleItems(items)), [5, 1, 2, 3, 4]);
  });

  test('search covers titles, descriptions, numbers, memory text and tags',
      () async {
    Future<List<int>> find(String q) async => numbers(
        visibleItems(store.items, searchMatches: await store.search(q)));

    expect(await find('japan'), [1, 2]); // case-insensitive, saved order
    expect(await find('kyoto'), [2]); // description
    expect(await find('#004'), [4]); // number with # and zeros
    expect(await find('3'), [3]);
    expect(await find('nothing like this'), isEmpty);
    expect(await find('100%'), isEmpty); // LIKE wildcards are escaped

    final swim = store.items.firstWhere((i) => i.number == 3);
    await store.saveMemory(MemoryDraft(
      itemId: swim.id,
      title: 'First lesson',
      body: 'Swallowed half the pool',
      date: CalendarDate(2030, 1, 2),
      location: 'Manila',
      hashtags: ['milestone', 'summer'],
      photos: const [],
    ));
    expect(await find('swallowed'), [3]); // memory text
    expect(await find('manila'), [3]); // memory location
    expect(await find('#milestone'), [3]); // hashtag
    expect(await find('first lesson'), [3]); // memory title
  });

  test('search + filter, then clearing both, restores the exact order',
      () async {
    final before = store.items.map((i) => i.id).toList();
    final matches = await store.search('japan');
    final narrowed = visibleItems(store.items,
        searchMatches: matches, filter: ListFilter.completed);
    expect(numbers(narrowed), [2]);

    // Nothing in the database changed.
    store = await archive.restart();
    expect(store.items.map((i) => i.id).toList(), before);
    expect(visibleItems(store.items).map((i) => i.id).toList(), before);
  });
}
