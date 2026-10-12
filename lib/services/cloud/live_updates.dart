import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/log.dart';

/// Tells an open app promptly that the account changed somewhere else
/// (another phone, the website), so it can fetch the changes.
///
/// It listens, through Supabase Realtime, to the account's own row in
/// `public.sync_heads`, which the server bumps on every change to the
/// archive (row-level security: nobody receives another account's
/// signal). The signal carries no data; [onChange] then syncs or reloads
/// the normal way, so nothing depends on a message arriving: the app
/// still catches up on start, when it returns to the foreground, and
/// after every change it makes.
class LiveUpdates {
  LiveUpdates._(this._channel);

  final RealtimeChannel _channel;
  Timer? _debounce;

  static LiveUpdates? start(
    SupabaseClient client,
    Future<void> Function() onChange,
  ) {
    final user = client.auth.currentUser?.id;
    if (user == null) return null;
    late final LiveUpdates live;
    final channel = client
        .channel('p1000-sync-$user')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sync_heads',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: user,
          ),
          callback: (_) => live._changed(onChange),
        );
    live = LiveUpdates._(channel);
    channel.subscribe((status, error) {
      if (error != null) logError('Live updates: $status', error);
      // (Re)joined, e.g. back online after a dropped connection: catch up
      // now (and send changes made offline) instead of at the next retry.
      if (status == RealtimeSubscribeStatus.subscribed) live._changed(onChange);
    });
    return live;
  }

  /// Several changes in a row (an import, a reorder) become one fetch.
  void _changed(Future<void> Function() onChange) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      onChange().catchError((Object e, StackTrace s) {
        logError('Live update failed', e, s);
      });
    });
  }

  Future<void> stop() async {
    _debounce?.cancel();
    try {
      await _channel.unsubscribe();
    } catch (_) {}
  }
}
