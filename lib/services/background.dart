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
  final send = port.sendPort;
  try {
    return await Isolate.run(() => job(send.send));
  } finally {
    await sub.cancel();
    port.close();
  }
}
