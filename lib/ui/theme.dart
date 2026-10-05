import 'package:flutter/material.dart';

/// Colours taken from the logo.
class Brand {
  static const green = Color(0xFF6DBE5A);
  static const deepGreen = Color(0xFF3F7A35);
  static const purple = Color(0xFF3B1F4A);
  static const blush = Color(0xFFF07A6A);
  static const wall = Color(0xFF29302E);
  static const paper = Color(0xFFFBF8F1);
}

/// Rounded display font used for numbers and headings.
const displayFont = 'Fredoka';

TextStyle display(double size, {double weight = 600, Color? color}) =>
    TextStyle(
      fontFamily: displayFont,
      fontSize: size,
      fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
      fontVariations: [FontVariation('wght', weight)],
      color: color,
      height: 1.1,
    );

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: Brand.green,
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xFF8FD67C) : Brand.deepGreen,
        secondary: dark ? const Color(0xFFCDB4DB) : Brand.purple,
        tertiary: Brand.blush,
        surface: dark ? const Color(0xFF1C2120) : Brand.paper,
        surfaceContainerLowest: dark ? const Color(0xFF171B1A) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF222826)
            : const Color(0xFFF5F1E7),
        surfaceContainer: dark
            ? const Color(0xFF272E2C)
            : const Color(0xFFEFEADF),
      );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: display(22, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: display(16, weight: 500),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
