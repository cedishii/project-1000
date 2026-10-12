import 'package:flutter/material.dart';

/// Widths where the layout changes (Material 3 window size classes).
class Breakpoints {
  /// Below this: phones. The app looks exactly as designed for phones.
  static const medium = 600.0;

  /// From here: landscape tablets, laptops and desktops.
  static const expanded = 840.0;

  /// From here: large desktops and wide screens.
  static const large = 1200.0;
}

/// The widest the app's content gets, so lines stay readable and the
/// phone layout is never just stretched across a monitor.
double contentWidthFor(double windowWidth) {
  if (windowWidth >= Breakpoints.large) return 880;
  if (windowWidth >= Breakpoints.expanded) return 760;
  return windowWidth;
}

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
