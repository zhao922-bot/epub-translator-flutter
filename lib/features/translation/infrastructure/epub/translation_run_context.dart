import 'dart:async';

import 'package:dio/dio.dart';

import '../../domain/repositories/translation_repository.dart';
import 'epub_repacker.dart';
import 'translation_work_queue.dart';

/// Mutable state belongs to one invocation, even when a translator is reused.
class TranslationRunContext {
  TranslationRunContext({
    required int concurrency,
    CancelToken? cancelToken,
    this.isCancelled,
  }) : requests = TranslationRequestBudget(concurrency),
       cancelToken = cancelToken ?? CancelToken();

  final TranslationRequestBudget requests;
  final CancelToken cancelToken;
  final TranslationCancellationCheck? isCancelled;
  final Set<String> degradedBlocks = <String>{};
  int apiDegradedBlocks = 0;
  Timer? _cancellationTimer;

  void throwIfCancelled() {
    if (isCancelled?.call() ?? false) {
      if (!cancelToken.isCancelled) cancelToken.cancel('Translation cancelled');
    }
    if (cancelToken.isCancelled) {
      throw const TranslationCancelledException();
    }
  }

  /// Callback cancellation has no event source. Poll while the invocation is
  /// alive so a callback changing during a request also cancels Dio's token.
  void watchCancellation() {
    throwIfCancelled();
    if (isCancelled == null) return;
    _cancellationTimer = Timer.periodic(const Duration(milliseconds: 25), (_) {
      try {
        throwIfCancelled();
      } on TranslationCancelledException {
        _cancellationTimer?.cancel();
      }
    });
  }

  void dispose() {
    _cancellationTimer?.cancel();
    _cancellationTimer = null;
  }

  void markDegraded({
    required String chapterPath,
    required String blockId,
    bool apiCounted = false,
  }) {
    final bool added = degradedBlocks.add(
      EpubRepacker.degradedKeyForBlock(
        chapterPath: chapterPath,
        blockId: blockId,
      ),
    );
    if (added && apiCounted) apiDegradedBlocks += 1;
  }
}
