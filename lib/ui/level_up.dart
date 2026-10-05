import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../data/progression.dart';
import 'formatting.dart';
import 'theme.dart';

OverlayEntry? _current;

/// A small, brief "LEVEL UP!" card at the top of the screen. It doesn't
/// block anything, disappears by itself (or when tapped), and doesn't
/// animate when the system asks for reduced motion. Screen readers hear
/// it announced.
void showLevelUp(BuildContext context, {required int from, required int to}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _current?.remove();
  final milestone = milestoneLevels.contains(to);
  final things = Progression.thingsForLevel(to);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _LevelUpCard(
      from: from,
      to: to,
      exp: to * expPerLevel,
      milestone: milestone ? '${count(things)} things' : null,
      onDone: () {
        if (_current == entry) _current = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _current = entry;
  overlay.insert(entry);
  final view = View.maybeOf(context);
  if (view != null) {
    SemanticsService.sendAnnouncement(
      view,
      'Level up. Level $from to level $to. ${count(to * expPerLevel)} EXP.',
      Directionality.of(context),
    );
  }
}

class _LevelUpCard extends StatefulWidget {
  const _LevelUpCard({
    required this.from,
    required this.to,
    required this.exp,
    required this.milestone,
    required this.onDone,
  });

  final int from;
  final int to;
  final int exp;
  final String? milestone;
  final VoidCallback onDone;

  @override
  State<_LevelUpCard> createState() => _LevelUpCardState();
}

class _LevelUpCardState extends State<_LevelUpCard>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 260),
  );
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timer != null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
    _timer = Timer(const Duration(milliseconds: 3200), _dismiss);
  }

  Future<void> _dismiss() async {
    _timer?.cancel();
    if (!mounted) return;
    if (!MediaQuery.disableAnimationsOf(context)) {
      await _controller.reverse();
    }
    widget.onDone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeIn,
    );
    return Positioned(
      left: 16,
      right: 16,
      top: MediaQuery.paddingOf(context).top + 12,
      child: FadeTransition(
        opacity: _controller,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, -0.4),
            end: Offset.zero,
          ).animate(curve),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Material(
                color: scheme.secondary,
                elevation: 6,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _dismiss,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                    child: Row(
                      children: [
                        Icon(
                          widget.milestone != null
                              ? Icons.emoji_events_rounded
                              : Icons.arrow_upward_rounded,
                          color: scheme.onSecondary,
                          size: 30,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'LEVEL UP!',
                                style: display(
                                  13,
                                  color: scheme.onSecondary.withValues(
                                    alpha: 0.8,
                                  ),
                                ).copyWith(letterSpacing: 1.5),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'LEVEL ${widget.from} → LEVEL ${widget.to}',
                                style: display(20, color: scheme.onSecondary),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                [
                                  '${count(widget.exp)} EXP',
                                  if (widget.milestone != null)
                                    'Milestone: ${widget.milestone}',
                                ].join('  ·  '),
                                style: TextStyle(
                                  color: scheme.onSecondary.withValues(
                                    alpha: 0.85,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
