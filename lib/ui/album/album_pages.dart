import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../services/album/album_plan.dart';
import '../formatting.dart';
import '../journey_facts.dart';
import '../store_scope.dart';
import '../theme.dart';
import '../widgets/emblem.dart';
import '../widgets/level_widgets.dart';
import '../widgets/photo_widgets.dart';

/// One page of the Life Album, drawn as a sheet of paper. Long pages
/// scroll inside the sheet rather than being cut off.
class AlbumPageView extends StatelessWidget {
  const AlbumPageView({super.key, required this.page, required this.facts});

  final AlbumPage page;
  final JourneyFacts facts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final child = switch (page) {
      AlbumCoverPage() => _Cover(facts: facts),
      AlbumIntroPage() => _Intro(facts: facts),
      final AlbumItemPage p => _ItemPage(page: p),
      final AlbumListPage p => _ListPage(items: p.items),
      AlbumEmptyPage() => const _EmptyPage(),
      AlbumClosingPage() => _Closing(facts: facts),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF242A28) : const Color(0xFFFFFDF8),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.4 : 0.10),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight - 56),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle? _label(BuildContext context, {Color? color}) =>
    Theme.of(context).textTheme.labelMedium?.copyWith(
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      letterSpacing: 1.4,
      fontWeight: FontWeight.w700,
    );

class _Cover extends StatelessWidget {
  const _Cover({required this.facts});

  final JourneyFacts facts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = facts.profile;
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          children: [
            const SizedBox(height: 12),
            const Emblem(size: 96),
            const SizedBox(height: 26),
            Text(
              'MY 1000 THINGS',
              style: display(32, color: scheme.secondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              'JOURNEY ${facts.number}',
              style: display(20, color: scheme.primary),
            ),
            const SizedBox(height: 18),
            Text(facts.datesLine, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              '${count(facts.progress.completed)} '
              '${facts.progress.completed == 1 ? 'THING' : 'THINGS'} COMPLETED',
              style: display(16),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        const SizedBox(height: 32),
        if (!profile.isEmpty)
          Column(
            children: [
              ProfileAvatar(profile: profile, size: 84),
              const SizedBox(height: 10),
              if (profile.name.isNotEmpty)
                Text(profile.name, style: display(18)),
              if (profile.nickname.isNotEmpty &&
                  profile.nickname != profile.name)
                Text(
                  '"${profile.nickname}"',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
      ],
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.facts});

  final JourneyFacts facts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('MY JOURNEY', style: display(30, color: scheme.secondary)),
        const SizedBox(height: 4),
        Text(
          'JOURNEY ${facts.number}',
          style: display(17, color: scheme.primary),
        ),
        const SizedBox(height: 18),
        for (final (label, value) in facts.rows)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: scheme.outlineVariant, width: 0.6),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(label.toUpperCase(), style: _label(context)),
                ),
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
          ),
        if (facts.profile.bio.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('ABOUT ME', style: _label(context)),
          const SizedBox(height: 6),
          Text(
            facts.profile.bio,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          ),
        ],
      ],
    );
  }
}

class _ItemHeader extends StatelessWidget {
  const _ItemHeader({required this.item, this.continued = false});

  final BucketItem item;
  final bool continued;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (continued) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(
          '${item.label}  ${item.title.toUpperCase()}  ·  CONTINUED',
          style: _label(context, color: scheme.secondary),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(item.label, style: display(30, color: scheme.secondary)),
        const SizedBox(height: 4),
        Text(item.title.toUpperCase(), style: display(22)),
        if (item.description.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            item.description,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontStyle: FontStyle.italic,
              color: scheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
        if (item.completedOn != null) ...[
          const SizedBox(height: 10),
          Text(
            'COMPLETED ${longDate(item.completedOn!).toUpperCase()}',
            style: _label(context, color: scheme.primary),
          ),
        ],
        const SizedBox(height: 18),
      ],
    );
  }
}

/// A completed thing with its memories, loaded when the page is shown.
class _ItemPage extends StatefulWidget {
  const _ItemPage({required this.page});

  final AlbumItemPage page;

  @override
  State<_ItemPage> createState() => _ItemPageState();
}

class _ItemPageState extends State<_ItemPage> {
  late final Future<List<Memory>> _memories = StoreScope.read(context)
      .loadMemoriesByIds([for (final m in widget.page.memories) m.id]);

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ItemHeader(item: page.item, continued: page.isContinued),
        FutureBuilder<List<Memory>>(
          future: _memories,
          builder: (context, snap) {
            final memories = snap.data;
            if (memories == null) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < memories.length; i++)
                  _AlbumMemory(
                    memory: memories[i],
                    style: page.style + i,
                    // Numbered across the item's pages.
                    label: page.totalMemories > 1
                        ? 'MEMORY ${page.firstMemory + i + 1}'
                        : null,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// One memory, photo first. The layout varies with [style] and the
/// number of photos so pages don't all look the same.
class _AlbumMemory extends StatelessWidget {
  const _AlbumMemory({required this.memory, required this.style, this.label});

  final Memory memory;
  final int style;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final photos = memory.photos;
    final hasText = memory.title.isNotEmpty || memory.body.isNotEmpty;
    final meta = [
      longDate(memory.date),
      if (memory.location.isNotEmpty) memory.location,
    ].join('  ·  ');

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (memory.title.isNotEmpty) ...[
          Text(memory.title, style: display(19, weight: 500)),
          const SizedBox(height: 6),
        ],
        if (memory.body.isNotEmpty)
          Container(
            padding: photos.isEmpty
                ? const EdgeInsets.only(left: 14)
                : EdgeInsets.zero,
            decoration: photos.isEmpty
                ? BoxDecoration(
                    border: Border(
                      left: BorderSide(color: scheme.secondary, width: 3),
                    ),
                  )
                : null,
            child: Text(
              memory.body,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
            ),
          ),
      ],
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Text(
          meta,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (memory.hashtags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              memory.hashtags.map((t) => '#$t').join('  '),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary),
            ),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            Text(
              '$label  ·  ${shortDate(memory.date).toUpperCase()}',
              style: _label(context, color: scheme.secondary),
            ),
            const SizedBox(height: 10),
          ],
          // Text-first on alternate single-photo pages, for variety.
          if (photos.length == 1 && style.isOdd && hasText) ...[
            text,
            const SizedBox(height: 12),
            _AlbumPhotos(photos: photos, style: style),
          ] else ...[
            if (photos.isNotEmpty) ...[
              _AlbumPhotos(photos: photos, style: style),
              const SizedBox(height: 14),
            ],
            text,
          ],
          details,
        ],
      ),
    );
  }
}

/// Large first photo, then the rest in a grid. Tap to view full screen.
class _AlbumPhotos extends StatelessWidget {
  const _AlbumPhotos({required this.photos, required this.style});

  final List<PhotoRef> photos;
  final int style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        const gap = 8.0;
        // Two photos sit side by side on some pages.
        if (photos.length == 2 && style.isEven) {
          final w = (width - gap) / 2;
          return Row(
            children: [
              _AlbumPhoto(photos: photos, index: 0, width: w, height: w * 1.25),
              const SizedBox(width: gap),
              _AlbumPhoto(photos: photos, index: 1, width: w, height: w * 1.25),
            ],
          );
        }
        final hero = photos.first;
        final aspect =
            (hero.width != null && hero.height != null && hero.height! > 0)
            ? hero.width! / hero.height!
            : 4 / 3;
        final heroHeight = (width / aspect).clamp(160.0, 460.0);
        final cell = (width - gap * 2) / 3;
        return Column(
          children: [
            _AlbumPhoto(
              photos: photos,
              index: 0,
              width: width,
              height: heroHeight,
            ),
            if (photos.length > 1) ...[
              const SizedBox(height: gap),
              Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 1; i < photos.length; i++)
                    _AlbumPhoto(
                      photos: photos,
                      index: i,
                      width: cell,
                      height: cell,
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _AlbumPhoto extends StatelessWidget {
  const _AlbumPhoto({
    required this.photos,
    required this.index,
    required this.width,
    required this.height,
  });

  final List<PhotoRef> photos;
  final int index;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.read(context);
    final scheme = Theme.of(context).colorScheme;
    final photo = photos[index];
    final px = (width * MediaQuery.devicePixelRatioOf(context)).round();
    final file = File(store.location.resolve(photo.file));
    final unavailable = Container(
      color: scheme.surfaceContainer,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(height: 4),
          Text(
            'Photo unavailable',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: GestureDetector(
          onTap: () => openPhotoViewer(context, photos, index),
          child: Image(
            image: ResizeImage(
              FileImage(file),
              width: px,
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.cover,
            semanticLabel: 'Photo',
            errorBuilder: (_, _, _) => unavailable,
          ),
        ),
      ),
    );
  }
}

/// Completed things without memories, a few to a page.
class _ListPage extends StatelessWidget {
  const _ListPage({required this.items});

  final List<BucketItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Divider(height: 36, color: scheme.outlineVariant),
          Text(items[i].label, style: display(24, color: scheme.secondary)),
          const SizedBox(height: 4),
          Text(items[i].title.toUpperCase(), style: display(18)),
          if (items[i].description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              items[i].description,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (items[i].completedOn != null) ...[
            const SizedBox(height: 6),
            Text(
              'COMPLETED ${longDate(items[i].completedOn!).toUpperCase()}',
              style: _label(context, color: scheme.primary),
            ),
          ],
        ],
      ],
    );
  }
}

class _EmptyPage extends StatelessWidget {
  const _EmptyPage();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Text(
        'Nothing completed yet.\nEach thing you complete gets its own page.',
        textAlign: TextAlign.center,
        style: display(18, weight: 500),
      ),
    ),
  );
}

class _Closing extends StatelessWidget {
  const _Closing({required this.facts});

  final JourneyFacts facts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 24),
        Text(
          facts.closingTitle,
          style: display(28, color: scheme.secondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        for (final line in facts.closingLines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(line, style: display(22)),
          ),
        const SizedBox(height: 22),
        for (final (label, value) in facts.closingFacts)
          Text('$label: $value', textAlign: TextAlign.center),
        const SizedBox(height: 28),
        if (facts.profile.photo != null)
          ProfileAvatar(profile: facts.profile, size: 64),
      ],
    );
  }
}
