import 'package:flutter/material.dart';

/// Widths where the layout changes (Material 3 window size classes).
class Breakpoints {
  /// Below this: phones. The app looks exactly as designed for phones.
  static const medium = 600.0;

  /// From here: landscape tablets, laptops and desktops.
  static const expanded = 840.0;

  /// From here: large desktops and wide screens.
  static const large = 1200.0;

  /// The home screen shows the list and the selected thing side by side
  /// when it is at least this wide.
  static const twoPane = 1100.0;
}

/// Width of the list beside the selected thing.
const double listPaneWidth = 420;

/// Readable width of a single screen (editors, settings, …).
const double readableWidth = 880;

/// The widest the app's frame gets. On large screens it leaves room for
/// the list and the selected thing side by side (home screen); other
/// screens stay at [readableWidth] inside it. The phone layout is never
/// just stretched across a monitor.
double contentWidthFor(double windowWidth) {
  if (windowWidth >= Breakpoints.large) return 1240;
  if (windowWidth >= Breakpoints.expanded) return 760;
  return windowWidth;
}

/// Page transitions that keep every screen except the first (the home
/// screen) at [readableWidth], centred, on wide frames.
class ReadablePageTransitions extends PageTransitionsBuilder {
  const ReadablePageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => const PageTransitionsTheme().buildTransitions(
    route,
    context,
    animation,
    secondaryAnimation,
    route.isFirst ? child : _ReadableWidth(child: child),
  );
}

class _ReadableWidth extends StatelessWidget {
  const _ReadableWidth({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.size.width <= readableWidth) return child;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Center(
        child: SizedBox(
          width: readableWidth,
          child: MediaQuery(
            data: media.copyWith(size: Size(readableWidth, media.size.height)),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The app's themes with [ReadablePageTransitions] on every platform.
ThemeData withReadablePages(ThemeData theme) => theme.copyWith(
  pageTransitionsTheme: PageTransitionsTheme(
    builders: {
      for (final platform in TargetPlatform.values)
        platform: const ReadablePageTransitions(),
    },
  ),
);

/// Centres every screen at [contentWidthFor] on wide windows, on a soft
/// background, with a hairline edge; on phones it does nothing. Screens
/// below see the content width as their screen size.
class AdaptiveFrame extends StatelessWidget {
  const AdaptiveFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final content = contentWidthFor(width);
    if (content >= width) return child;
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainer,
      child: Center(
        child: Container(
          width: content,
          decoration: BoxDecoration(
            border: Border.symmetric(
              vertical: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: MediaQuery(
            data: media.copyWith(size: Size(content, media.size.height)),
            child: child,
          ),
        ),
      ),
    );
  }
}
