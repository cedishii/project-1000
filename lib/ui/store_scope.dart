import 'package:flutter/widgets.dart';

import '../state/app_store.dart';

/// Makes the [AppStore] available to every screen and rebuilds dependents
/// when it changes.
class StoreScope extends InheritedNotifier<AppStore> {
  const StoreScope({super.key, required AppStore store, required super.child})
      : super(notifier: store);

  /// The store, rebuilding the caller when it changes.
  static AppStore of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoreScope>()!.notifier!;

  /// The store, without subscribing to changes (for callbacks).
  static AppStore read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<StoreScope>()!.notifier!;
}
