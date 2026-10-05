import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:project_1000/data/archive_repository.dart';
import 'package:project_1000/data/models.dart';
import 'package:project_1000/state/app_store.dart';

import 'helpers.dart';

void main() {
  late TestArchive archive;
  late AppStore store;

  setUp(() async {
    archive = await TestArchive.create();
    store = await archive.open();
  });
  tearDown(() => archive.dispose());

  Future<void> addFive() async {
    for (final t in [
      'Learn Japanese',
      'Visit Japan',
      'Learn to swim',
      'See a concert',
      'Build my own house',
    ]) {
      await store.addItem(t, '');
    }
  }

  test('a fresh install has zero items and default settings', () async {
    expect(store.items, isEmpty);
    expect(store.completedCount, 0);
    store = await archive.restart();
    expect(store.items, isEmpty);
  });

  test('Phase 2 critical sequence: completing never moves items; '
      'order survives restarts; manual order persists', () async {
    // 1. Create five items.
    await addFive();
    expect(numbersOf(store), [1, 2, 3, 4, 5]);

    // 2–3. Complete #004; it does not move.
    await store.setCompleted(store.items[3].id, true);
    expect(numbersOf(store), [1, 2, 3, 4, 5]);
    expect(store.items[3].isCompleted, isTrue);

    // 4–5. Complete #001; it does not move.
    await store.setCompleted(store.items[0].id, true);
    expect(numbersOf(store), [1, 2, 3, 4, 5]);

    // 6–7. Restart; order unchanged.
    store = await archive.restart();
    expect(numbersOf(store), [1, 2, 3, 4, 5]);
    expect(store.items.map((i) => i.isCompleted), [
      true,
      false,
      false,
      true,
      false,
    ]);

    // 8–9. Add another; it goes to the end as #006.
    await store.addItem('Write a book', '');
    expect(numbersOf(store), [1, 2, 3, 4, 5, 6]);

    // 10. Manually move #006 to second place.
    final ids = store.items.map((i) => i.id).toList();
    final moved = ids.removeAt(5);
    ids.insert(1, moved);
    await store.saveOrder(ids);
    expect(numbersOf(store), [1, 6, 2, 3, 4, 5]);

    // 11–12. Restart; manual order persists.
    store = await archive.restart();
    expect(numbersOf(store), [1, 6, 2, 3, 4, 5]);
    expect(titlesOf(store)[1], 'Write a book');
  });

  test('editing an item does not move it', () async {
    await addFive();
    await store.updateItemText(store.items[2].id, 'Learn to swim well', 'x');
    expect(numbersOf(store), [1, 2, 3, 4, 5]);
    expect(store.items[2].title, 'Learn to swim well');
    expect(store.items[2].description, 'x');
  });

  test(
    'deleting keeps other numbers; the freed number is reused at the end',
    () async {
      await addFive();
      await store.deleteItem(store.items[2].id); // #003
      expect(numbersOf(store), [1, 2, 4, 5]);
      store = await archive.restart();
      expect(numbersOf(store), [1, 2, 4, 5]);

      final added = await store.addItem('New dream', '');
      expect(added.number, 3);
      // Appended at the end — never inserted by number.
      expect(numbersOf(store), [1, 2, 4, 5, 3]);
    },
  );

  test('un-completing keeps the previous completion date', () async {
    await addFive();
    final id = store.items[1].id;
    final day = CalendarDate(2032, 9, 18);
    await store.setCompleted(id, true, on: day);
    expect(store.items[1].completedOn, day);
    await store.setCompleted(id, false);
    expect(store.items[1].isCompleted, isFalse);
    expect(store.items[1].completedOn, day);
    store = await archive.restart();
    expect(store.items[1].completedOn, day);
  });

  test('the list holds at most 1000 items, numbered #001–#1000', () async {
    final repo = store.repository;
    for (var i = 0; i < maxItems; i++) {
      await repo.addItem('Thing ${i + 1}', '');
    }
    store = await archive.restart();
    expect(store.items.length, 1000);
    expect(store.items.first.label, '#001');
    expect(store.items.last.label, '#1000');
    expect(
      () => store.addItem('One too many', ''),
      throwsA(isA<ListFullException>()),
    );
  });

  test(
    'a bad order is rejected and leaves the saved order untouched',
    () async {
      await addFive();
      final ids = store.items.map((i) => i.id).toList();
      await expectLater(
        store.saveOrder(ids.sublist(1)),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        store.saveOrder([...ids.sublist(1), ids[1]]),
        throwsA(isA<StateError>()),
      );
      store = await archive.restart();
      expect(numbersOf(store), [1, 2, 3, 4, 5]);
    },
  );

  test('theme setting persists', () async {
    await store.setThemeMode(ThemeMode.dark);
    store = await archive.restart();
    expect(store.themeMode, ThemeMode.dark);
  });
}
