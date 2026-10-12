import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_1000/ui/theme.dart';

/// design/tokens.json is what the web app styles itself with; it must
/// stay identical to the Flutter theme.
void main() {
  final tokens =
      jsonDecode(File('design/tokens.json').readAsStringSync()) as Map;

  String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  test('brand colours', () {
    final brand = tokens['brand'] as Map;
    expect(brand['green'], hex(Brand.green));
    expect(brand['deepGreen'], hex(Brand.deepGreen));
    expect(brand['purple'], hex(Brand.purple));
    expect(brand['blush'], hex(Brand.blush));
    expect(brand['wall'], hex(Brand.wall));
    expect(brand['paper'], hex(Brand.paper));
  });

  for (final brightness in Brightness.values) {
    test('${brightness.name} colour scheme', () {
      final s = buildTheme(brightness).colorScheme;
      final t = (tokens['color'] as Map)[brightness.name] as Map;
      expect(t['primary'], hex(s.primary));
      expect(t['secondary'], hex(s.secondary));
      expect(t['tertiary'], hex(s.tertiary));
      expect(t['surface'], hex(s.surface));
      expect(t['surfaceContainerLowest'], hex(s.surfaceContainerLowest));
      expect(t['surfaceContainerLow'], hex(s.surfaceContainerLow));
      expect(t['surfaceContainer'], hex(s.surfaceContainer));
    });
  }

  test('shapes', () {
    final theme = buildTheme(Brightness.light);
    final radius = tokens['radius'] as Map;
    double r(ShapeBorder? b) =>
        ((b as RoundedRectangleBorder).borderRadius as BorderRadius).topLeft.x;
    expect(r(theme.cardTheme.shape), radius['card']);
    expect(r(theme.floatingActionButtonTheme.shape), radius['fab']);
    expect(
      (theme.inputDecorationTheme.border as OutlineInputBorder)
          .borderRadius
          .topLeft
          .x,
      radius['input'],
    );
    expect(r(theme.chipTheme.shape), radius['chip']);
    expect(displayFont, (tokens['font'] as Map)['display']['family']);
  });
}
