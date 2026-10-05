import '../data/models.dart';

enum ListFilter { all, completed, notCompleted }

/// The rows to show for a search and filter.
///
/// This is a view only: it walks [items] in their saved order and hides
/// rows; it never sorts, so clearing the search/filter shows the exact
/// original order again.
List<BucketItem> visibleItems(
  List<BucketItem> items, {
  Set<String>? searchMatches,
  ListFilter filter = ListFilter.all,
}) {
  return [
    for (final i in items)
      if ((searchMatches == null || searchMatches.contains(i.id)) &&
          switch (filter) {
            ListFilter.all => true,
            ListFilter.completed => i.isCompleted,
            ListFilter.notCompleted => !i.isCompleted,
          })
        i
  ];
}
