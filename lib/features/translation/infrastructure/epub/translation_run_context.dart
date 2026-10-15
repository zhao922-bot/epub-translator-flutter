import 'dart:async';

import 'package:dio/dio.dart';

import '../../domain/repositories/translation_repository.dart';
import 'epub_repacker.dart';
import 'translation_work_queue.dart';
import 'translation_api_client.dart';
import 'translation_consistency_checker.dart';

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
  final Map<String, String> degradedReasons = <String, String>{};
  int apiDegradedBlocks = 0;
  String cacheSourceIdentity = '';
  final TranslationApiMetrics styleMetrics = TranslationApiMetrics();
  int semanticRequests = 0;
  final ReviewEvidenceIndex semanticEvidence = ReviewEvidenceIndex();
  Map<String, Object> sourceHints = const {};
  int semanticReservedTokens = 0;
  final Set<String> semanticReviewed = {};
  final Set<String> semanticSkipped = {};
  final Map<String, List<Map<String, String>>> consistencyFindings = {};
  final Set<String> semanticUnreviewed = {};
  final Set<String> semanticAuditSamples = {};
  final Set<String> reusedDraftBlocks = {};
  final Map<String, String> semanticUnreviewedReasons = {};
  final Map<String, Map<String, String>> semanticTerms = {};
  final Set<String> semanticSingleRetries = {};
  final List<Map<String, Object?>> semanticCorrections = [];

  bool isUnreviewed(String chapterPath, String id) =>
      semanticUnreviewed.contains(
        EpubRepacker.degradedKeyForBlock(chapterPath: chapterPath, blockId: id),
      );
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
    String? reason,
  }) {
    final String key = EpubRepacker.degradedKeyForBlock(
      chapterPath: chapterPath,
      blockId: blockId,
    );
    final bool added = degradedBlocks.add(key);
    if (reason != null) degradedReasons[key] = reason;
    if (added && apiCounted) apiDegradedBlocks += 1;
  }
}
