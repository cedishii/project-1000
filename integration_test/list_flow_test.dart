// On-device test of the list: empty state, adding, completing, search,
// filters and reordering — through the real UI.
//
// Run on a connected device/emulator:
//   flutter test integration_test/list_flow_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_1000/state/app_store.dart';
import 'package:project_1000/ui/app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() async {
    // A fresh, separate folder: never touches the app's real data.
    root = await Directory.systemTemp.createTemp('p1000_it_');
  });
  tearDown(() => root.delete(recursive: true));

  /// Pumps until [finder] matches (real storage work takes real time).
  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    bool gone = false,
  }) async {
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty != gone) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('Timed out waiting for $finder');
  }

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(
      Project1000App(storeLoader: () => AppStore.open(root: root)),
    );
    await waitFor(tester, find.byType(Scaffold));
    await waitFor(tester, find.byTooltip('Settings'));
  }

  Future<void> addItem(WidgetTester tester, String title) async {
    final first = find.text('Add your first thing');
    await tester.tap(first.evaluate().isNotEmpty ? first : find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, title);
    await tester.tap(find.text('Save'));
    await waitFor(tester, find.text(title));
    await waitFor(tester, find.text('Save'), gone: true);
  }

  /// Titles in the order they appear on screen (top to bottom).
  List<String> onScreenOrder(WidgetTester tester, List<String> titles) {
    final present = titles.where((t) => find.text(t).evaluate().isNotEmpty);
    final withY = [
      for (final t in present) (t, tester.getTopLeft(find.text(t).first).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return withY.map((e) => e.$1).toList();
  }

  const titles = [
    'Learn Japanese',
    'Visit Japan',
    'Learn to swim',
    'See a concert',
    'Build my own house',
  ];

  testWidgets('list flow', (tester) async {
    await launch(tester);

    // Fresh install: empty.
    expect(find.text('Your list is empty.'), findsOneWidget);
    expect(find.text('You have 1,000 possibilities.'), findsOneWidget);

    for (final t in titles) {
      await addItem(tester, t);
    }
    expect(onScreenOrder(tester, titles), titles);
    expect(find.text('0%'), findsOneWidget);

    // Complete the 4th item via its check button.
    Future<void> complete(String title) async {
      final row = find.ancestor(
        of: find.text(title),
        matching: find.byType(Card),
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Mark as completed')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Mark as completed'));
      await waitFor(
        tester,
        find.descendant(
          of: find.ancestor(of: find.text(title), matching: find.byType(Card)),
          matching: find.byTooltip('Mark as not completed'),
        ),
      );
    }

    await complete('See a concert');
    expect(onScreenOrder(tester, titles), titles, reason: 'must not move');
    await complete('Learn Japanese');
    expect(onScreenOrder(tester, titles), titles, reason: 'must not move');
    expect(find.text('0.2%'), findsOneWidget);
    expect(find.textContaining('998 remaining'), findsOneWidget);

    // Filter: completed only, in saved order; then back to all.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Completed'));
    await tester.pumpAndSettle();
    expect(onScreenOrder(tester, titles), ['Learn Japanese', 'See a concert']);
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    expect(onScreenOrder(tester, titles), titles);

    // Search, then clear.
    await tester.enterText(find.byType(TextField).first, 'japan');
    FocusManager.instance.primaryFocus?.unfocus(); // close the keyboard
    await waitFor(tester, find.text('Learn to swim'), gone: true);
    expect(onScreenOrder(tester, titles), ['Learn Japanese', 'Visit Japan']);
    await tester.tap(find.byTooltip('Clear search'));
    await waitFor(tester, find.text('Learn to swim'));
    expect(onScreenOrder(tester, titles), titles);

    // Reorder: move the first item down one place.
    await tester.tap(find.byTooltip('Reorder list'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move down').first);
    await waitFor(tester, find.text('Place 1'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final reordered = [titles[1], titles[0], ...titles.skip(2)];
    expect(onScreenOrder(tester, titles), reordered);

    // "Restart": a brand new app instance on the same data.
    await tester.pumpWidget(const SizedBox());
    await launch(tester);
    expect(onScreenOrder(tester, titles), reordered);
    expect(find.text('0.2%'), findsOneWidget);
  });
}
