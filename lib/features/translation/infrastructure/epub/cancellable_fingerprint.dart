import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../domain/repositories/translation_repository.dart';
import 'cancellation_listener.dart';

/// Cancel the digest subscription, which closes the upstream file read too.
Future<Digest> cancellableFingerprint(
  Stream<List<int>> bytes, {
  required CancelToken cancelToken,
  void Function()? throwIfCancelled,
}) async {
  if (cancelToken.isCancelled) {
    throw const TranslationCancelledException();
  }
  throwIfCancelled?.call();
  final completed = Completer<Digest>();
  final subscription = sha256
      .bind(bytes)
      .listen(
        (digest) {
          if (!completed.isCompleted) completed.complete(digest);
        },
        onError: (Object error, StackTrace stack) {
          if (!completed.isCompleted) completed.completeError(error, stack);
        },
      );
  Future<void> cancel(Object error, [StackTrace? stack]) async {
    if (completed.isCompleted) return;
    try {
      await subscription.cancel();
    } finally {
      if (!completed.isCompleted) completed.completeError(error, stack);
    }
  }

  final detach = CancellationListener.listen(
    cancelToken,
    () => unawaited(cancel(const TranslationCancelledException())),
  );
  // The invocation also supports a callback cancellation API. Poll it even
  // when a slow filesystem has not delivered another chunk yet.
  final poll = throwIfCancelled == null
      ? null
      : Timer.periodic(const Duration(milliseconds: 50), (_) {
          try {
            throwIfCancelled();
          } catch (error, stack) {
            unawaited(cancel(error, stack));
          }
        });
  try {
    return await completed.future;
  } finally {
    poll?.cancel();
    detach();
    await subscription.cancel();
  }
}
