import 'dart:async';
import 'dart:collection';

/// A request budget shared by batches, retries and individual fallbacks.
/// Acquire only around the HTTP request, never around a parent batch that can
/// enqueue child requests (which would deadlock when all permits are held).
class TranslationRequestBudget {
  TranslationRequestBudget(int concurrency)
    : limit = concurrency < 1 ? 1 : concurrency;

  final int limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() request) async {
    if (_active < limit) {
      _active += 1;
    } else {
      final Completer<void> ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    }
    try {
      return await request();
    } finally {
      if (_waiting.isEmpty) {
        _active -= 1;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}

/// Fixed worker count, rather than fixed windows. Stops claiming work after
/// the first failure, drains already-started work, then preserves its stack.
class TranslationWorkQueue {
  const TranslationWorkQueue();

  Future<List<R>> map<T, R>(
    List<T> items, {
    required int concurrency,
    required Future<R> Function(T item, int index) process,
    void Function()? throwIfCancelled,
  }) async {
    if (items.isEmpty) return <R>[];
    final int limit = concurrency < 1 ? 1 : concurrency;
    final List<R?> results = List<R?>.filled(items.length, null);
    int next = 0;
    Object? failure;
    StackTrace? failureStack;

    Future<void> worker() async {
      while (failure == null && next < items.length) {
        try {
          throwIfCancelled?.call();
          final int index = next++;
          results[index] = await process(items[index], index);
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
        }
      }
    }

    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < limit && i < items.length; i++) worker(),
    ]);
    if (failure != null) {
      Error.throwWithStackTrace(failure!, failureStack!);
    }
    return <R>[for (final R? result in results) result as R];
  }
}
