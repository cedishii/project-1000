// Performance check against whatever archive is on the device (read-only:
// it only scrolls, searches and filters). Load a large backup first, then:
//   flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/perf_test.dart
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:project_1000/state/app_store.dart';
import 'package:project_1000/state/list_view_filter.dart';
import 'package:project_1000/ui/app.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scroll, search and filter performance', (tester) async {
    final openWatch = Stopwatch()..start();
    late AppStore store;
    await tester.pumpWidget(Project1000App(storeLoader: () async {
      store = await AppStore.open();
      return store;
    }));
    for (var i = 0; i < 100 && find.byTooltip('Settings').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final openMs = openWatch.elapsedMilliseconds;
    await tester.pumpAndSettle();

    final timings = <FrameTiming>[];
    void collect(List<FrameTiming> t) => timings.addAll(t);
    SchedulerBinding.instance.addTimingsCallback(collect);
    final list = find.byType(Scrollable).first;
    for (var i = 0; i < 20; i++) {
      await tester.fling(list, const Offset(0, -2500), 6000);
      await tester.pumpAndSettle();
    }
    for (var i = 0; i < 10; i++) {
      await tester.fling(list, const Offset(0, 2500), 6000);
      await tester.pumpAndSettle();
    }
    SchedulerBinding.instance.removeTimingsCallback(collect);

    final build = timings.map((t) => t.buildDuration.inMicroseconds).toList()..sort();
    final raster = timings.map((t) => t.rasterDuration.inMicroseconds).toList()..sort();
    int pct(List<int> l, double p) => l.isEmpty ? 0 : l[(l.length * p).floor().clamp(0, l.length - 1)];

    final searchWatch = Stopwatch()..start();
    final matches = await store.search('travel');
    final searchMs = searchWatch.elapsedMilliseconds;
    final filterWatch = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      visibleItems(store.items, searchMatches: matches, filter: ListFilter.completed);
    }
    final filterUs = filterWatch.elapsedMicroseconds / 100;

    final report = {
      'items': store.items.length,
      'open_ms': openMs,
      'frames': timings.length,
      'build_p50_us': pct(build, .5),
      'build_p90_us': pct(build, .9),
      'build_p99_us': pct(build, .99),
      'raster_p50_us': pct(raster, .5),
      'raster_p90_us': pct(raster, .9),
      'raster_p99_us': pct(raster, .99),
      'frames_over_16ms': timings
          .where((t) => t.totalSpan > const Duration(milliseconds: 16)).length,
      'search_ms': searchMs,
      'search_hits': matches.length,
      'filter_us': filterUs,
    };
    binding.reportData = report;
    debugPrint('PERF $report');
    expect(store.items.length, greaterThan(0));
    // Keep the window alive briefly so the frame callback flushes.
    await tester.pump(const Duration(milliseconds: 100));
    PlatformDispatcher.instance.onReportTimings;
  });
}
