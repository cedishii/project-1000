import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_1000/state/app_store.dart';
import 'package:project_1000/ui/app.dart';
import 'package:project_1000/ui/screens/item_detail_screen.dart';

import 'helpers.dart';

/// Wide screens show the list and the chosen thing side by side; phones
/// keep opening it as its own page.
void main() {
  late TestArchive archive;
  late AppStore store;

  setUp(() async {
    archive = await TestArchive.create();
  });
  tearDown(() => archive.dispose());

  /// Lets real database work finish between frames (pumpAndSettle alone
  /// would wait forever on a loading spinner).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> launch(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      store = await archive.open();
      await store.addItem('Watch the Northern Lights', 'Someday');
      await store.addItem('Learn to sail', '');
    });
    await tester.pumpWidget(Project1000App(storeLoader: () async => store));
    await settle(tester);
  }

  testWidgets('desktop: details open beside the list', (tester) async {
    await launch(tester, const Size(1440, 900));
    expect(find.text('Choose a thing to see it here.'), findsOneWidget);

    await tester.tap(find.text('Learn to sail'));
    await settle(tester);
    expect(find.byType(ItemDetailScreen), findsOneWidget);
    // Still on the home route: the list is visible next to the details.
    expect(find.text('Watch the Northern Lights'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    final list = tester.getRect(find.text('Watch the Northern Lights'));
    final detail = tester.getRect(find.byType(ItemDetailScreen));
    expect(detail.left, greaterThan(list.right));
  });

  testWidgets('phone: details open as their own page', (tester) async {
    await launch(tester, const Size(400, 800));
    expect(find.text('Choose a thing to see it here.'), findsNothing);

    await tester.tap(find.text('Learn to sail'));
    await settle(tester);
    expect(find.byType(ItemDetailScreen), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('Watch the Northern Lights'), findsNothing);
  });
}
