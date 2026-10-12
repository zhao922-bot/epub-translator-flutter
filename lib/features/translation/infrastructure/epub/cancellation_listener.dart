import 'package:dio/dio.dart';

/// Dio exposes a Future rather than removable cancellation listeners. Keep
/// one bridge per token, and detach operation-specific closures on completion.
class CancellationListener {
  static final Expando<_CancellationListeners> _byToken = Expando();

  static void Function() listen(CancelToken token, void Function() callback) {
    if (token.isCancelled) {
      callback();
      return () {};
    }
    var listeners = _byToken[token];
    if (listeners == null) {
      listeners = _CancellationListeners();
      _byToken[token] = listeners;
      token.whenCancel.then((_) => listeners!.cancel());
    }
    final bridge = listeners;
    bridge.callbacks.add(callback);
    return () => bridge.callbacks.remove(callback);
  }

  static int activeListenerCount(CancelToken token) =>
      _byToken[token]?.callbacks.length ?? 0;
}

class _CancellationListeners {
  final Set<void Function()> callbacks = {};

  void cancel() {
    final pending = callbacks.toList();
    callbacks.clear();
    for (final callback in pending) {
      // One throwing callback must not skip the rest: each listener gets
      // its own guard so cancellation still reaches every subscriber.
      try {
        callback();
      } catch (_) {
        // Cancellation delivery is best-effort; a failing listener must
        // not break the others or the cancellation itself.
      }
    }
  }
}
