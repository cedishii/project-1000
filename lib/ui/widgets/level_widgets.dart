import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/progression.dart';
import '../formatting.dart';
import '../store_scope.dart';
import '../theme.dart';

/// The profile picture in a circle, or a quiet default: the user's
/// initials, or a person icon when there is no name either.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.profile, this.size = 88});

  final Profile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = StoreScope.read(context);
    final photo = profile.photo;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final initials = _initials(
      profile.name.isNotEmpty ? profile.name : profile.nickname,
    );
    final fallback = Container(
      color: scheme.secondaryContainer,
      alignment: Alignment.center,
      child: initials.isEmpty
          ? Icon(
              Icons.person_rounded,
              size: size * 0.55,
              color: scheme.onSecondaryContainer,
            )
          : Text(
              initials,
              style: display(size * 0.36, color: scheme.onSecondaryContainer),
            ),
    );
    return Semantics(
      label: 'Profile picture',
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.surface, width: size / 30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: ClipOval(
          child: photo == null
              ? fallback
              : Image(
                  image: ResizeImage(
                    FileImage(File(store.location.resolve(photo))),
                    width: px,
                    height: px,
                  ),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }

  static String _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return '';
    final first = words.first.characters.first;
    final last = words.length > 1 ? words.last.characters.first : '';
    return (first + last).toUpperCase();
  }
}

/// A rounded progress bar. The numbers are always shown next to it; the
/// bar only illustrates them.
class LevelBar extends StatelessWidget {
  const LevelBar({
    super.key,
    required this.value,
    this.height = 12,
    this.color,
    this.semanticsLabel,
  });

  final double value;
  final double height;
  final Color? color;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: semanticsLabel,
      value: '${(value * 100).toStringAsFixed(1)}%',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: animate ? 0 : value, end: value),
            duration: animate
                ? const Duration(milliseconds: 700)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => LinearProgressIndicator(
              value: v == 0 ? 0 : v.clamp(0.015, 1.0),
              minHeight: height,
              backgroundColor: scheme.surfaceContainer,
              color: color ?? scheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// "LEVEL 37" with the number as the hero.
class LevelNumber extends StatelessWidget {
  const LevelNumber({super.key, required this.level, this.size = 64});

  final int level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Level $level',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'LEVEL',
              style: display(
                size * 0.24,
                weight: 600,
                color: scheme.onSurfaceVariant,
              ).copyWith(letterSpacing: 2),
            ),
            Text('$level', style: display(size, color: scheme.secondary)),
          ],
        ),
      ),
    );
  }
}

/// Compact level line for the home screen: "LEVEL 24 · 240,000 EXP" and
/// a thin bar toward the next level. Tapping opens the profile.
class CompactLevelRow extends StatelessWidget {
  const CompactLevelRow({
    super.key,
    required this.journey,
    required this.progression,
    required this.onTap,
  });

  /// Journey number; shown from Journey 2 on.
  final int journey;
  final Progression progression;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = progression;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        if (journey > 1)
                          TextSpan(
                            text: 'JOURNEY $journey  ·  ',
                            style: display(
                              14,
                              weight: 500,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        TextSpan(
                          text: 'LEVEL ${p.level}',
                          style: display(15, color: scheme.secondary),
                        ),
                        TextSpan(
                          text: '  ·  ${count(p.exp)} EXP',
                          style: display(
                            14,
                            weight: 500,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  LevelBar(
                    value: p.levelFraction,
                    height: 6,
                    color: scheme.secondary,
                    semanticsLabel: p.isMaxLevel
                        ? 'Maximum level'
                        : 'Progress to level ${p.level + 1}',
                  ),
                  const SizedBox(height: 4),
                  Text(
                    p.isMaxLevel
                        ? 'Max level'
                        : '${count(p.expIntoLevel)} / ${count(expPerLevel)} EXP '
                              'to Level ${p.level + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
