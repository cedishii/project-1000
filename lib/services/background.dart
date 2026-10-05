import 'dart:async';
import 'dart:isolate';

/// Runs [job] on a background isolate, forwarding progress (0.0–1.0) it
/// reports to [onProgress] on the calling isolate.
Future<R> runWithProgress<R>(
  FutureOr<R> Function(void Function(double progress) report) job, {
  void Function(double progress)? onProgress,
}) async {
  final port = ReceivePort();
  final sub = port.listen((m) {
    if (m is double) onProgress?.call(m);
  });
  try {
    return await _spawn(job, port.sendPort);
  } finally {
    await sub.cancel();
    port.close();
  }
}

/// Kept separate on purpose: the closure sent to the new isolate may only
/// capture [job] and [send]. Defined inside [runWithProgress] it would
/// also carry [onProgress] (which can reference UI objects that can't be
/// sent between isolates) and the send would fail.
Future<R> _spawn<R>(
  FutureOr<R> Function(void Function(double)) job,
  SendPort send,
) => Isolate.run(() => job(send.send));
