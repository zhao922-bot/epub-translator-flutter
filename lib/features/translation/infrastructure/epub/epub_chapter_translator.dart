import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:path/path.dart' as path;

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/logging/app_logger.dart';
import '../../../../shared/io/atomic_file_writer.dart';
import '../../../../shared/platform/native_platform_bridge.dart';
import '../../../../shared/security/sensitive_text.dart';
import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/job_resume_state.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/models/translation_job.dart';
import '../../domain/models/translation_run_result.dart';
import '../../domain/models/translation_style_profile.dart';
import '../../domain/repositories/translation_repository.dart';
import '../translation_cache_store.dart';
import '../translation_quality.dart';
import '../cache_restoration_scanner.dart';
import '../epub_isolate_worker.dart';
import 'epub_repacker.dart';
import 'epub_html_extractor.dart';
import 'chapter_source_restorer.dart';
import 'epub_source_guard.dart';
import 'xhtml_html_compatibility.dart';
import 'footnote_batch_planner.dart';
import 'protected_anchor_text_slots.dart';
import 'epub_semantics.dart';
import 'translation_api_client.dart';
import 'cancellable_fingerprint.dart';
import 'translation_batch_planner.dart';
import 'translation_progress_persistence.dart';
import 'translation_run_context.dart';
import 'translation_work_queue.dart';

part 'epub_book_memory.dart';
part 'epub_translation_strategy.dart';

/// Orchestrates cache, book-memory, batch planning, and API translation.
///
/// ZIP inspect/repack live in [EpubInspector] / [EpubRepacker]. HTTP details in
/// [TranslationApiClient]; batch sizing/context in [TranslationBatchPlanner].
class EpubChapterTranslator {
  EpubChapterTranslator({
    TranslationCacheStore? cacheStore,
    EpubRepacker? repacker,
    TranslationApiClient? apiClient,
    TranslationBatchPlanner? batchPlanner,
    FootnoteBatchPlanner? footnoteBatchPlanner,
  }) : _cacheStore = cacheStore ?? TranslationCacheStore(),
       _repacker = repacker ?? EpubRepacker(),
       _apiClient = apiClient ?? const TranslationApiClient(),
       _batchPlanner = batchPlanner ?? const TranslationBatchPlanner(),
       _footnoteBatchPlanner =
           footnoteBatchPlanner ?? const FootnoteBatchPlanner();

  /// Blocks whose translation could not pass quality checks or whose
  /// API connection/response timed out. They degrade to their last usable
  /// translation (or source HTML when no response arrived) so the whole book
  /// can continue. Recorded so the run report can list them honestly.
  /// Keyed by chapter-scoped degraded key
  /// ([EpubRepacker.degradedKeyForBlock]), not by bare block id: block ids
  /// restart per chapter (`p-1` exists in nearly every chapter), so a bare
  /// id would collide across chapters and mis-mark innocent blocks as
  /// untranslated. (Not keyed by identity either: block instances are copied
  /// around ([ExtractedBlock.copyWith]), so identity checks would silently
  /// miss.)
  TranslationRunContext _run = TranslationRunContext(concurrency: 1);
  Set<String> get _degradedBlocks => _run.degradedBlocks;

  /// Degraded blocks counted as completed API work in either pipeline.
  /// Subtracted from the run-local `apiTranslatedBlocks` counter for the
  /// performance report so "translated N blocks" only counts blocks that
  /// actually got translated text.
  ///
  /// The protected-anchor slot sub-pipeline is shared by both: its degrade
  /// points take `apiCounted` from the calling pipeline (main block batches
  /// count every block up front, footnote persistence counts per reference),
  /// so the subtraction stays exact no matter which pipeline degraded.
  int get _apiDegradedBlocks => _run.apiDegradedBlocks;

  /// Records [blockId] of [chapterPath] as degraded. The chapter scope is
  /// required because block ids are only unique within a chapter.
  ///
  /// Pass [apiCounted] when the block will count as completed API work in
  /// `apiTranslatedBlocks`, including footnote-path degrades.
  /// Callers of the shared protected-slot pipeline forward their own
  /// pipeline's value.
  void _markDegradedBlock({
    required String chapterPath,
    required String blockId,
    bool apiCounted = false,
    String? reason,
  }) {
    _run.markDegraded(
      chapterPath: chapterPath,
      blockId: blockId,
      apiCounted: apiCounted,
      reason: reason,
    );
  }

  /// Whether [blockId] of [chapterPath] was recorded as degraded.
  bool _isDegradedBlock({
    required String chapterPath,
    required String blockId,
  }) {
    return _degradedBlocks.contains(
      EpubRepacker.degradedKeyForBlock(
        chapterPath: chapterPath,
        blockId: blockId,
      ),
    );
  }

  final TranslationCacheStore _cacheStore;
  final EpubRepacker _repacker;
  final TranslationApiClient _apiClient;
  final TranslationBatchPlanner _batchPlanner;
  final FootnoteBatchPlanner _footnoteBatchPlanner;
  late final _EpubBookMemory _memory = _EpubBookMemory(this);
  late final _EpubTranslationStrategy _strategy = _EpubTranslationStrategy(
    this,
  );

  EpubChapterTranslator _invocation(TranslationRunContext run) {
    final EpubChapterTranslator invocation = EpubChapterTranslator(
      cacheStore: _cacheStore,
      repacker: _repacker,
      apiClient: _apiClient,
      batchPlanner: _batchPlanner,
      footnoteBatchPlanner: _footnoteBatchPlanner,
    );
    invocation._run = run;
    return invocation;
  }

  Future<Response<dynamic>> _postChatCompletions({
    required Dio dio,
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) {
    if (!data.containsKey('max_tokens')) _TranslationRequestBudget.apply(data);
    return _run.requests.run(() async {
      _run.throwIfCancelled();
      if (cancelToken?.isCancelled ?? false) {
        throw const TranslationCancelledException();
      }
      final onMemoryAttempt =
          Zone.current[_memoryAttemptKey] as void Function(Duration)?;
      final stopwatch = onMemoryAttempt == null ? null : (Stopwatch()..start());
      try {
        return await _apiClient.postChatCompletions(
          dio: dio,
          data: data,
          cancelToken: cancelToken ?? _run.cancelToken,
        );
      } finally {
        if (stopwatch != null) {
          stopwatch.stop();
          onMemoryAttempt!(stopwatch.elapsed);
        }
      }
    });
  }

  static final Object _memoryAttemptKey = Object();
  static const String _cacheSchemaVersion = 'v17-structure-repair';

  // Memory checkpoints keep their independent quality schema.
  static const String qualityCacheSchemaVersion = 'v16-quality-memory-lru';

  static int htmlBudgetTokensForTest(String html) =>
      _TranslationRequestBudget.estimateTokens(html);

  static ({int fixedTokens, int payloadTokens, int totalTokens}) requestBudgetForTest(
    Map<String, dynamic> data,
  ) => _TranslationRequestBudget.forRequest(data);

  /// Test-only merge. The [memory] JSON stands in for the in-memory
  /// [_BookMemory] (locks already resolved, e.g. from a checkpoint), so its
  /// locks are trusted; the [chapter] JSON stands in for a model reply, so
  /// model-declared locks are distrusted unless [trustedChapterLocks] is set.
  static Map<String, Object?> mergeBookMemoryForTest(
    Map<String, Object?> memory,
    Map<String, Object?> chapter, {
    bool trustedMemoryLocks = true,
    bool trustedChapterLocks = false,
  }) => _BookMemory.fromJson(
    memory,
    trustedLocks: trustedMemoryLocks,
  ).mergeChapter(_ChapterMemory.fromJson(chapter, trustedLocks: trustedChapterLocks)).toJson();

  @visibleForTesting
  static List<String> Function() protectedSlotIdsForTest(ExtractedBlock block) {
    final request = _ProtectedSlotRequest(
      id: block.id,
      block: block,
      template: ProtectedAnchorTextSlots.parse(block.sourceHtml),
      chapterPath: '',
    );
    return () => request.slotIds;
  }

  /// Retains the production checkpoint's cache across saves in a test.
  @visibleForTesting
  static Future<Future<void> Function(
    List<({String path, Map<String, Object?> memory})> timeline,
  )> bookMemoryCheckpointWriterForTest({
    required TranslationCacheStore cacheStore,
    required String jobKey,
    required int chunkSize,
    bool resume = false,
  }) async {
    final checkpoint = _BookMemoryCheckpoint(cacheStore, jobKey, chunkSize);
    if (resume) await checkpoint.load();
    return (List<({String path, Map<String, Object?> memory})> timeline) => checkpoint.save(
      timeline.isEmpty
          ? _BookMemory.fromJson({})
          : _BookMemory.fromJson(timeline.last.memory, trustedLocks: true),
      completedChapterPaths: timeline.map((entry) => entry.path).toSet(),
      timeline: [
        for (final entry in timeline)
          (path: entry.path,
           memory: _BookMemory.fromJson(entry.memory, trustedLocks: true)),
      ],
    );
  }

  static Future<void> saveBookMemoryCheckpointForTest({
    required TranslationCacheStore cacheStore,
    required String jobKey,
    required int chunkSize,
    required Map<String, Object?> memory,
    bool trustedLocks = true,
    List<({String path, Map<String, Object?> memory})> timeline = const [],
    String schema = qualityCacheSchemaVersion,
  }) => _BookMemoryCheckpoint(cacheStore, jobKey, chunkSize).save(
    _BookMemory.fromJson(memory, trustedLocks: trustedLocks),
    timeline: [
      for (final entry in timeline)
        (
          path: entry.path,
          memory: _BookMemory.fromJson(entry.memory, trustedLocks: trustedLocks),
        ),
    ],
    schema: schema,
  );

  static Future<Map<String, Object?>?> loadBookMemoryCheckpointForTest({
    required TranslationCacheStore cacheStore,
    required String jobKey,
    required int chunkSize,
  }) async => (await _BookMemoryCheckpoint(cacheStore, jobKey, chunkSize).load())?.memory.toJson();

  static Future<List<Map<String, Object?>>> loadBookMemoryTimelineForTest({
    required TranslationCacheStore cacheStore,
    required String jobKey,
    required int chunkSize,
  }) async => [
    for (final entry
        in (await _BookMemoryCheckpoint(cacheStore, jobKey, chunkSize).load())?.timeline ?? const [])
      {'path': entry.path, 'memory': entry.memory.toJson()},
  ];

  /// Mutable selection state for [selectMemorySnapshotForTest] (性能-#38).
  @visibleForTesting
  static MemorySnapshotCursor memorySnapshotCursorForTest() =>
      MemorySnapshotCursor();

  /// Incremental write-cursor decision for the positional memory timeline
  /// (性能-#52). Entries are append-only with strictly increasing positions
  /// — a re-recorded earlier chapter is dropped, never rewritten — so the
  /// write side only needs the high-water mark instead of rescanning the
  /// whole timeline per chapter (O(n^2) total). Exactly equivalent to the
  /// old per-record full scan: an entry is appended iff its position is
  /// non-null and strictly greater than every previously recorded one.
  @visibleForTesting
  static bool shouldRecordMemoryTimelineEntryForTest({
    required int? position,
    required int maxRecordedPosition,
  }) =>
      position != null && position > maxRecordedPosition;

  /// Incremental positional memory snapshot selector (性能-#38).
  ///
  /// Returns the newest timeline entry strictly before [chapterPath]'s
  /// position in [positionByPath], serialized via [serialize], or
  /// [fallback] when there is none. [cursor] holds mutable selection
  /// state across calls; chapters are visited in non-decreasing book order
  /// so each timeline entry is examined once per run (O(n) total, not
  /// O(n²)). A non-monotonic call resyncs via a fresh scan.
  ///
  /// P2-#16: [fallback] must already implement positional snapshot
  /// isolation (null — not live rolling memory — after a checkpoint
  /// restore with a non-empty timeline).
  @visibleForTesting
  static Map<String, Object?>? selectMemorySnapshotForTest({
    required List<({String path, Object memory})> timeline,
    required Map<String, int> positionByPath,
    required String chapterPath,
    required MemorySnapshotCursor cursor,
    required Map<String, Object?> Function(Object memory) serialize,
    required Map<String, Object?>? Function() fallback,
  }) {
    final int? position = positionByPath[chapterPath];
    if (position == null || position <= 0) {
      return fallback();
    }
    if (position < cursor.lastPosition) {
      cursor.index = 0;
      cursor.winner = null;
      cursor.lastPosition = -1;
    }
    cursor.lastPosition = position;
    while (cursor.index < timeline.length) {
      final entry = timeline[cursor.index];
      final int? entryPosition = positionByPath[entry.path];
      if (entryPosition == null) {
        cursor.index++;
        continue;
      }
      if (entryPosition >= position) {
        break;
      }
      cursor.winner = entry.memory;
      cursor.index++;
    }
    final Object? winner = cursor.winner;
    if (winner == null) {
      return fallback();
    }
    return serialize(winner);
  }

  /// P2-#16: snapshot fallback selection. The live rolling memory is only
  /// a safe fallback for a fresh run (or a restore that never recorded a
  /// chapter, where the live memory is still the initial memory). After a
  /// checkpoint restore with a non-empty timeline the live memory may
  /// already contain later chapters, so a chapter with no earlier entry
  /// must not receive the whole live memory (that would leak future
  /// chapters' glossary/plot/summaries).
  /// P2-#9: returning null wholesale also dropped the user-confirmed style
  /// profile (empty memory == empty style). Keep just the style-profile
  /// slice instead: later-chapter memory stays isolated, but the user's
  /// confirmed style choices survive.
  @visibleForTesting
  static Map<String, Object?>? memorySnapshotFallbackForTest({
    required bool hasRestoredMemory,
    required bool timelineIsEmpty,
    required Map<String, Object?>? liveMemory,
  }) {
    if (!hasRestoredMemory || timelineIsEmpty) {
      return liveMemory;
    }
    return _styleProfileOnlyMemory(liveMemory);
  }

  /// The user-confirmed style-profile slice of [liveMemory] (the
  /// `styleProfile`/`styleProfileConfirmed` keys only), or null when there
  /// is nothing to keep. Used by [memorySnapshotFallbackForTest] (P2-#9).
  static Map<String, Object?>? _styleProfileOnlyMemory(
    Map<String, Object?>? liveMemory,
  ) {
    if (liveMemory == null) {
      return null;
    }
    final Map<String, Object?> styleOnly = <String, Object?>{};
    final Object? styleProfile = liveMemory['styleProfile'];
    if (styleProfile != null) {
      styleOnly['styleProfile'] = styleProfile;
    }
    if (liveMemory['styleProfileConfirmed'] == true) {
      styleOnly['styleProfileConfirmed'] = true;
    }
    return styleOnly.isEmpty ? null : styleOnly;
  }

  /// Positional memory snapshot: the newest timeline entry strictly before
  /// [chapterPath] in [orderedPaths] book order, or [fallback] when none
  /// exists. A retranslated earlier chapter thus never sees rolling memory
  /// that already contains later chapters.
  @visibleForTesting
  static Map<String, Object?>? positionalMemorySnapshotForTest({
    required List<Map<String, Object?>> timeline,
    required List<String> orderedPaths,
    required String chapterPath,
    Map<String, Object?>? fallback,
  }) {
    final Map<String, int> positionByPath = <String, int>{};
    for (int i = 0; i < orderedPaths.length; i++) {
      positionByPath.putIfAbsent(orderedPaths[i], () => i);
    }
    final int? position = positionByPath[chapterPath];
    Map<String, Object?>? snapshot;
    if (position != null && position > 0) {
      for (final entry in timeline) {
        final int? entryPosition = positionByPath[entry['path'] as String?];
        final Object? memory = entry['memory'];
        if (entryPosition != null &&
            entryPosition < position &&
            memory is Map<String, Object?>) {
          snapshot = memory;
        }
      }
    }
    return snapshot ?? fallback;
  }

  static Future<InspectedChapter> releaseChapterSourcesForTest(
    InspectedChapter chapter, Directory directory,
  ) => _ChapterSourceSpool(directory: directory).release(chapter);

  static Future<InspectedChapter> restoreChapterSourcesForTest(
    InspectedChapter chapter,
    Directory directory, {
    bool Function()? isCancelled,
  }) => _ChapterSourceSpool(directory: directory).restore(
    chapter,
    isCancelled: isCancelled,
  );

  static String chineseSecondPersonInstructionForTest({
    required TranslationConfig config,
    String? normalizedTargetLanguage,
  }) {
    return EpubChapterTranslator()._strategy._chineseSecondPersonInstruction(
      config: config,
      normalizedTargetLanguage: normalizedTargetLanguage,
    );
  }

  /// Test hook for the C-30 combined style fragment (style profile +
  /// terminology gloss + second-person rule), which normalizes the target
  /// language once and reuses the result.
  static String styleInstructionFragmentForTest({
    required TranslationConfig config,
    TranslationStyleProfile? styleProfile,
    bool confirmed = false,
  }) {
    return EpubChapterTranslator()._strategy._styleInstructionFragment(
      config: config,
      styleProfile: styleProfile,
      confirmed: confirmed,
    );
  }

  /// Test hook for the terminology gloss builder, exposing the
  /// pre-normalized language override used by the combined style fragment
  /// (C-30: normalize once, reuse).
  static String terminologyGlossInstructionForTest({
    required TranslationConfig config,
    String? normalizedTargetLanguage,
  }) {
    return EpubChapterTranslator()._strategy._terminologyGlossInstruction(
      config: config,
      normalizedTargetLanguage: normalizedTargetLanguage,
    );
  }

  static bool shouldFallbackBatchDioExceptionForTest(DioException error) {
    return TranslationApiClient.shouldFallbackBatchDioException(error);
  }

  /// Records a chapter's memory timeline entry and persists the checkpoint.
  /// The record MUST precede the persist (A-2): no persist happens after the
  /// run ends, so persisting first would leave the checkpoint lagging one
  /// chapter behind after a cancellation.
  static Future<void> _recordAndPersistChapterMemory({
    required void Function() record,
    required Future<void> Function() persist,
  }) async {
    record();
    await persist();
  }

  /// Test hook for the A-2 ordering contract: [record] must run before
  /// [persist].
  @visibleForTesting
  static Future<void> recordAndPersistChapterMemoryForTest({
    required void Function() record,
    required Future<void> Function() persist,
  }) => _recordAndPersistChapterMemory(record: record, persist: persist);

  /// Selects the memory-timeline entry behind [chapterPath]'s snapshot (the
  /// newest entry strictly before the chapter in book order) and serializes
  /// only that entry via [serialize]. Selecting before serializing keeps the
  /// per-chapter cost O(1) instead of O(timeline length); [fallback] is
  /// returned when no earlier entry exists.
  @visibleForTesting
  static Map<String, Object?>? memorySnapshotForTest({
    required List<({String path, Object? memory})> timeline,
    required Map<String, int> positionByPath,
    required String chapterPath,
    required Map<String, Object?> Function(Object? memory) serialize,
    Map<String, Object?>? fallback,
  }) {
    final int? position = positionByPath[chapterPath];
    Object? winner;
    if (position != null && position > 0) {
      for (final entry in timeline) {
        final int? entryPosition = positionByPath[entry.path];
        if (entryPosition != null && entryPosition < position) {
          winner = entry.memory;
        }
      }
    }
    return winner == null ? fallback : serialize(winner);
  }

  static String sanitizeOutputSuffixForTest(String suffix) {
    return TranslationApiClient.sanitizeOutputSuffix(suffix);
  }

  /// Test-visible core of the run-local `cachePutBestEffort` closure: null
  /// when the write succeeded, or the swallowed error when it failed. The
  /// closure itself adds the warn-once logging on top of this and converts
  /// the result to the bool the write counters consume.
  static Future<Object?> putBlockCacheErrorForTest(
    TranslationCacheStore cacheStore,
    String cacheKey,
    String translatedHtml,
  ) async {
    return TranslationProgressPersistence.putError(
      cacheStore,
      cacheKey,
      translatedHtml,
    );
  }

  static String prepareBlockHtmlForTargetForTest({
    required String sourceHtml,
    required String targetLanguage,
  }) {
    return _prepareBlockHtmlForTarget(
      sourceHtml: sourceHtml,
      targetLanguage: targetLanguage,
    );
  }

  static String blockCacheKeyForTest({
    required TranslationConfig config,
    required ExtractedBlock block,
    required String chapterPath,
    String inputFingerprint = 'test-book',
    TranslationStyleProfile? confirmedStyleProfile,
  }) {
    return EpubChapterTranslator()._blockCacheKey(
      config,
      block,
      chapterPath: chapterPath,
      inputFingerprint: inputFingerprint,
      confirmedStyleProfile: confirmedStyleProfile,
    );
  }

  static String jobKeyForTest({
    required String inputFingerprint,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
  }) {
    return EpubChapterTranslator()._jobKey(
      inputFingerprint: inputFingerprint,
      config: config,
      chapters: chapters,
      confirmedStyleProfile: confirmedStyleProfile,
    );
  }

  static String normalizeInputPathForCacheForTest(String inputPath) {
    return _normalizeInputPathForCache(inputPath);
  }

  static List<Map<String, String>> styleProfileSourceChaptersForTest(
    List<InspectedChapter> chapters,
  ) {
    return _EpubBookMemory._styleProfileSourceChapters(chapters);
  }

  static bool hasRepresentativeStyleTextForTest(List<ExtractedBlock> blocks) =>
      _EpubBookMemory._hasRepresentativeStyleText(blocks);

  static Future<List<Map<String, String>>>
  restoredStyleProfileSourceChaptersForTest(
    List<InspectedChapter> chapters, {
    required bool Function() isCancelled,
    void Function(int, int)? onProgress,
  }) => _EpubBookMemory.restoredStyleProfileSourceChapters(
    chapters,
    isCancelled: isCancelled,
    onProgress: onProgress,
  );

  static String outputFilePathForTest({
    required String inputPath,
    required String outputDirectory,
    required String suffix,
  }) {
    return EpubChapterTranslator()._outputFilePath(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
      suffix: suffix,
    );
  }

  static bool htmlStructureMatchesForTest({
    required String sourceHtml,
    required String translatedHtml,
  }) {
    return _htmlStructureMatches(sourceHtml, translatedHtml);
  }

  static String lockHtmlStructureForTest({
    required String sourceHtml,
    required String translatedHtml,
    Map<String, int>? instrumentation,
  }) {
    return _lockHtmlStructure(
      sourceHtml: sourceHtml,
      translatedHtml: translatedHtml,
      instrumentation: instrumentation,
    );
  }

  static List<Map<String, Object?>> batchPlanForTest({
    required String chapterTitle,
    required int chunkSize,
    required List<ExtractedBlock> pendingBlocks,
    required List<ExtractedBlock> chapterBlocks,
  }) {
    return const TranslationBatchPlanner().planForTest(
      chapterTitle: chapterTitle,
      chunkSize: chunkSize,
      pendingBlocks: pendingBlocks,
      chapterBlocks: chapterBlocks,
    );
  }

  /// Test-only view of the blocks degraded for this translator instance.
  /// Keys are chapter-scoped (see [EpubRepacker.degradedKeyForBlock]); build
  /// the expected key with [degradedKeyForTest].
  Set<String> getDegradedBlockIdsForTest() => _degradedBlocks.toSet();

  /// Builds the chapter-scoped degraded key a test should expect in
  /// [getDegradedBlockIdsForTest].
  static String degradedKeyForTest({
    String chapterPath = '',
    required String blockId,
  }) {
    return EpubRepacker.degradedKeyForBlock(
      chapterPath: chapterPath,
      blockId: blockId,
    );
  }

  /// Test-only view of the reason recorded for a degraded block (the text
  /// shown in the run report's degraded-block sample line), or null when
  /// the block degraded without a reason.
  String? degradedReasonForTest({
    String chapterPath = '',
    required String blockId,
  }) {
    return _run.degradedReasons[degradedKeyForTest(
      chapterPath: chapterPath,
      blockId: blockId,
    )];
  }

  void _beginDegradedTracking({int concurrency = 1}) {
    _run = TranslationRunContext(concurrency: concurrency);
  }

  Future<List<String>> translateBlockBatchForTest({
    required Dio dio,
    required TranslationConfig config,
    required List<ExtractedBlock> blocks,
    String chapterTitle = '',
    String chapterPath = '',
    List<ExtractedBlock> contextBefore = const <ExtractedBlock>[],
    List<ExtractedBlock> contextAfter = const <ExtractedBlock>[],
    Map<String, Object?>? bookMemory,
    Future<void> Function(String id, String html)? onValidated,
  }) {
    _beginDegradedTracking(concurrency: config.maxConcurrent);
    return _strategy.translateBlockBatch(
      dio: dio,
      config: config,
      chapterPath: chapterPath,
      batch: TranslationBlockBatch(
        blocks,
        context: TranslationBatchContext(
          chapterTitle: chapterTitle,
          before: _batchPlanner.contextSnippets(contextBefore),
          after: _batchPlanner.contextSnippets(contextAfter),
          bookMemory: bookMemory,
        ),
      ),
      retryDelayOverride: Duration.zero,
      onValidated: onValidated,
    );
  }

  Future<Map<String, String>> translateFootnoteBatchForTest({
    required Dio dio,
    required TranslationConfig config,
    required List<FootnoteBlockReference> references,
    Map<String, Object?>? bookMemory,
    Future<void> Function(String id, String html)? onValidated,
  }) {
    _beginDegradedTracking(concurrency: config.maxConcurrent);
    return _strategy._translateFootnoteBatch(
      dio: dio,
      config: config,
      batch: FootnoteTranslationBatch(
        references,
        context: TranslationBatchContext(
          chapterTitle: 'Cross-file footnotes',
          bookMemory: bookMemory,
        ),
      ),
      retryDelayOverride: Duration.zero,
      onValidated: onValidated,
    );
  }

  Future<Map<String, Object?>> generateInitialBookMemoryForTest({
    required Dio dio,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
  }) async {
    return (await _memory.generateInitialBookMemory(
      dio: dio,
      config: config,
      chapters: chapters,
    )).toJson();
  }

  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    TranslationCancellationCheck? isCancelled,
  }) async {
    final TranslationRunContext run = TranslationRunContext(
      concurrency: config.maxConcurrent,
      cancelToken: cancelToken,
      isCancelled: isCancelled,
    );
    run.throwIfCancelled();
    if (!config.styleProfileEnabled) {
      return TranslationStyleProfile.empty;
    }
    run.watchCancellation();
    Dio? dio;
    try {
      await validateInspectedSource(chapters);
      run.throwIfCancelled();
      dio = _apiClient.buildDio(config);
      return await _invocation(run)._memory.generateStyleProfile(
        dio: dio,
        config: config,
        chapters: chapters,
        cancelToken: run.cancelToken,
        throwIfCancelled: run.throwIfCancelled,
      );
    } finally {
      // Fresh Dio per call (own HttpClient pool); close it so sockets/FDs
      // do not accumulate across runs.
      run.dispose();
      dio?.close(force: true);
    }
  }

  Future<TranslationStyleProfile> generateStyleProfileForTest({
    required Dio dio,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
    TranslationCancellationCheck? isCancelled,
  }) async {
    final TranslationRunContext run = TranslationRunContext(
      concurrency: config.maxConcurrent,
      cancelToken: cancelToken,
      isCancelled: isCancelled,
    );
    run.watchCancellation();
    try {
      return await _invocation(run)._memory.generateStyleProfile(
        dio: dio,
        config: config,
        chapters: chapters,
        cancelToken: run.cancelToken,
        throwIfCancelled: run.throwIfCancelled,
      );
    } finally {
      run.dispose();
    }
  }

  Future<Map<String, Object?>> updateBookMemoryAfterChapterForTest({
    required Dio dio,
    required TranslationConfig config,
    required Map<String, Object?> currentMemory,
    required InspectedChapter chapter,
    Set<String> degradedBlockIds = const <String>{},
  }) async {
    return (await _memory.updateBookMemoryAfterChapter(
      dio: dio,
      config: config,
      currentMemory: _BookMemory.fromJson(currentMemory, trustedLocks: true),
      chapter: chapter,
      degradedBlockIds: degradedBlockIds,
    )).toJson();
  }

  static bool _isCancelError(Object error) {
    return TranslationApiClient.isCancelError(error);
  }

  Future<String> testConnection({required TranslationConfig config}) {
    return _apiClient.testConnection(config: config);
  }

  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    required CancelToken cancelToken,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
    void Function(String chapterPath)? onChapterSourcesReleased,
  }) async {
    // Release the parent async frame's source references together with the
    // worker's lists, without mutating an immutable caller inspection list.
    chapters = chapters.toList(growable: false);
    final TranslationRunContext run = TranslationRunContext(
      concurrency: config.maxConcurrent,
      cancelToken: cancelToken,
      isCancelled: isCancelled,
    );
    final EpubChapterTranslator invocation = _invocation(run);
    _run = run;
    run.watchCancellation();
    try {
      return await invocation._translateChapters(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        config: config,
        chapters: chapters,
        cancelToken: run.cancelToken,
        confirmedStyleProfile: confirmedStyleProfile,
        onProgress: onProgress,
        isCancelled: isCancelled,
        onChapterSourcesReleased: onChapterSourcesReleased,
      );
    } finally {
      run.dispose();
    }
  }

  Future<TranslationRunResult> _translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    required CancelToken cancelToken,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
    void Function(String chapterPath)? onChapterSourcesReleased,
  }) async {
    // Localized strings for the user-visible run log; the run's UI language
    // comes from the config, not from a BuildContext (see runLog* keys).
    final AppStrings s = AppStrings(config.uiLanguage);
    // Set once the translated EPUB has been committed to disk. A late error
    // or cancellation after that point must not reframe the finished output
    // as an aborted translation (see M5).
    TranslationRunResult? committedResult;
    // Effective concurrency, clamped so a misconfigured maxConcurrent (<= 0)
    // can never wedge the batch loop below (see M9).
    final int concurrency = config.maxConcurrent < 1 ? 1 : config.maxConcurrent;
    // The Dio built for this run owns an HttpClient connection pool; it is
    // closed in the finally below so sockets/FDs do not accumulate (see M7).
    late final Dio dio;
    bool dioReady = false;
    final sourceSpool = _ChapterSourceSpool();
    final invocationChapters = chapters;
    try {
      chapters = await ChapterSourceRestorer.restore(
        chapters: chapters,
        isCancelled: () =>
            cancelToken.isCancelled || (isCancelled?.call() ?? false),
      );
      // The invocation owns this list; replace completed entries in every
      // retained list, rather than retaining the original restored chapters.
      chapters = chapters.toList(growable: false);
      // O(1) path lookups for the per-chapter release below: the loops only
      // replace entries, never reorder, so these indexes stay valid for the
      // whole run (first occurrence wins, matching indexWhere semantics).
      final Map<String, int> chapterIndexByPath = <String, int>{};
      for (int i = 0; i < chapters.length; i++) {
        chapterIndexByPath.putIfAbsent(chapters[i].path, () => i);
      }
      final Map<String, int> invocationIndexByPath = <String, int>{};
      for (int i = 0; i < invocationChapters.length; i++) {
        invocationIndexByPath.putIfAbsent(invocationChapters[i].path, () => i);
      }
      final List<InspectedChapter> selectedChapters = chapters
          .where((InspectedChapter chapter) => chapter.includeInTranslation)
          .map(
            (InspectedChapter chapter) => _prepareChapterForTarget(
              chapter,
              targetLanguage: config.targetLanguage,
            ),
          )
          .toList();
      // Book-order positions for the positional memory snapshots below.
      // Entries are replaced, never reordered, so this stays valid.
      final Map<String, int> selectedPositionByPath = <String, int>{};
      for (int i = 0; i < selectedChapters.length; i++) {
        selectedPositionByPath.putIfAbsent(selectedChapters[i].path, () => i);
      }
      final int totalBlocks = selectedChapters.fold<int>(
        0,
        (int sum, InspectedChapter chapter) => sum + chapter.blocks.length,
      );
      // Stable across checkpoints/retries, but changes when the initial memory
      // sample or preceding rolling-memory chapters change with the selection.
      final String contextIdentity = sha256
          .convert(
            utf8.encode(
              jsonEncode(
                selectedChapters.map((chapter) => chapter.path).toList(),
              ),
            ),
          )
          .toString();

      if (selectedChapters.isEmpty) {
        throw const FormatException(
          'No chapters are selected. Check at least one chapter before starting translation.',
        );
      }
      final String jobId = DateTime.now().millisecondsSinceEpoch.toString();
      final String outputFilePath = _outputFilePath(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        suffix: config.outputSuffix,
      );
      // Windows: a reader holding the previous output file open (no share
      // access) would make the final commit fail at ~98% after every API
      // call was already billed. Probe for an exclusive-access lock now so
      // the user can close the file before any paid work starts. Opening
      // in append mode never truncates; a locked file throws
      // FileSystemException here.
      //
      // This probe is deliberately best-effort: it cannot close the TOCTOU
      // window (the user may open the file mid-run), and append mode only
      // checks WRITE access while the commit rename needs DELETE. The
      // commit path itself is recoverable instead: EpubIsolateWorker
      // preserves the translated temp file and throws a localized
      // OutputFileLockedException when the rename hits a sharing
      // violation, so a late lock no longer destroys paid work.
      if (Platform.isWindows) {
        final File outputFile = File(outputFilePath);
        if (await outputFile.exists()) {
          try {
            final RandomAccessFile probe = await outputFile.open(
              mode: FileMode.append,
            );
            await probe.close();
          } on FileSystemException catch (probeError) {
            // Classify: a real sharing/lock violation (osError 32/33)
            // means another program has the file open; anything else
            // (e.g. ERROR_ACCESS_DENIED = 5 on a read-only file) is an
            // access problem and must not be misreported as "locked".
            throw StateError(
              preRunProbeErrorMessage(
                probeError,
                AppStrings(config.uiLanguage),
                outputFilePath,
              ),
            );
          }
        }
        // Windows: the lock-conflict recovery path keeps
        // `<output>.recovery.<16 digits>` (+26) beside the output, and the
        // repack commit writes `<output>.tmp.<16 digits>` (+21) before
        // promoting it. The pick-time warning only measures the directory
        // the user chose, so a deep directory plus a long book name can push
        // the longest write path past MAX_PATH (260) — failing at ~98% after
        // every API call was already billed. Fail loudly now, before any
        // paid work starts.
        await throwIfOutputPathTooLongForWindows(outputFilePath);
      }
      await validateOutputDirectory(outputDirectory, config.uiLanguage);
      if (totalBlocks == 0) {
        await validateInspectedSource(chapters, inputPath: inputPath);
        return await _repackZeroBlockSelection(
          jobId: jobId,
          inputPath: inputPath,
          outputFilePath: outputFilePath,
          config: config,
          chapters: chapters,
          selectedChapterCount: selectedChapters.length,
          cancelToken: cancelToken,
          confirmedStyleProfile: confirmedStyleProfile,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      }
      if (config.apiBaseUrl.trim().isEmpty ||
          config.apiKey.trim().isEmpty ||
          config.model.trim().isEmpty) {
        throw const FormatException(
          'API base URL, API key, and model are required before translation can start.',
        );
      }

      dio = _apiClient.buildDio(config);
      dioReady = true;
      final Stopwatch translationStopwatch = Stopwatch()..start();
      Duration totalApiElapsed = Duration.zero;
      Duration totalCacheWriteElapsed = Duration.zero;
      Duration totalMemoryElapsed = Duration.zero;
      int apiTranslatedBlocks = 0;
      int cacheWriteCount = 0;
      int memoryRequestCount = 0;
      int footnoteBatchCount = 0;
      int footnoteRequestCount = 0;

      Future<_BookMemory> trackMemoryRequests(
        Future<_BookMemory> Function() operation,
      ) => runZoned(
        operation,
        zoneValues: {
          _memoryAttemptKey: (Duration elapsed) {
            memoryRequestCount += 1;
            totalMemoryElapsed += elapsed;
          },
        },
      );

      final TranslationStyleProfile? confirmedProfile =
          config.styleProfileEnabled ? confirmedStyleProfile : null;
      final TranslationStyleProfile? userStyleProfile = confirmedProfile;
      final String inputFingerprint = await _inputFingerprint(
        inputPath,
        expectedSourceFingerprint: sourceIdentityForChapters(chapters)?.sha256,
        cancelToken: cancelToken,
      );
      final String jobKey = _jobKey(
        inputFingerprint: inputFingerprint,
        config: config,
        chapters: selectedChapters,
        confirmedStyleProfile: userStyleProfile,
      );
      JobResumeState? previousState;
      bool unreadableResumeState = false;
      final memoryCheckpoint = _BookMemoryCheckpoint(_cacheStore, jobKey, config.chunkSize);
      final restoredMemory = await memoryCheckpoint.load();
      try {
        previousState = await _cacheStore.loadJobState(jobKey);
        if (previousState != null && restoredMemory == null) {
          AppLogger.warn('Checkpoint has no compatible chunkSize/schema memory identity; discarding progress metadata.', tag: 'translate');
          previousState = null;
        }
      } catch (error) {
        unreadableResumeState = true;
        AppLogger.warn(
          'Saved checkpoint could not be read (${error.runtimeType}); scanning block caches without it.',
          tag: 'translate',
        );
      }
      final int checkpointBlocks = min(
        previousState?.completedBlocks ?? 0,
        totalBlocks,
      );
      TranslationJob currentJob = TranslationJob(
        id: jobId,
        inputPath: inputPath,
        outputPath: outputFilePath,
        status: TranslationJobStatus.running,
        phase: TranslationJobPhase.cacheRestoration,
        progress: checkpointBlocks / totalBlocks,
        currentChapter: 'Restoring cached translations',
        completedFiles: 0,
        totalFiles: selectedChapters.length,
        completedBlocks: checkpointBlocks,
        totalBlocks: totalBlocks,
        cachedBlocks: 0,
        resumedBlocks: 0,
        resumeCheckpointBlocks: checkpointBlocks,
        cacheScanScannedBlocks: 0,
        cacheScanTotalBlocks: totalBlocks,
        styleProfile: confirmedProfile ?? TranslationStyleProfile.empty,
        styleProfileConfirmed:
            !config.styleProfileEnabled || confirmedProfile != null,
        styleProfileEnabled: config.styleProfileEnabled,
      );

      void emit(TranslationJob job, String logLine) {
        currentJob = job;
        try {
          onProgress?.call(job, logLine);
        } catch (error) {
          // A UI-side progress listener must never abort a translation run.
          // Log the failure and keep the pipeline going.
          AppLogger.warn(
            'Progress callback failed (${error.runtimeType}); continuing.',
            tag: 'translate',
          );
        }
        AppLogger.debug(logLine, tag: 'translate');
      }

      void throwIfCancelled() {
        _run.throwIfCancelled();
      }

      final TranslationProgressPersistence
      persistence = TranslationProgressPersistence(
        cacheStore: _cacheStore,
        stateFor: (TranslationJob job) => _resumeStateFromJob(
          jobKey: jobKey,
          inputFingerprint: inputFingerprint,
          job: job,
        ),
        onCacheError: (Object cacheError, bool firstFailure) {
          AppLogger.warn(
            'Block cache write failed (${cacheError.runtimeType}); continuing '
            'without cache.',
            tag: 'translate',
          );
          if (firstFailure) {
            emit(
              currentJob,
              s.runLogCacheWriteFailing('${cacheError.runtimeType}'),
            );
          }
        },
        onCheckpointError: (Object error, bool firstFailure) {
          AppLogger.warn(
            'Checkpoint save failed (${error.runtimeType}); continuing '
            'without a fresh checkpoint.',
            tag: 'translate',
          );
          if (firstFailure) {
            emit(
              currentJob,
              s.runLogCheckpointSaveFailing('${error.runtimeType}'),
            );
          }
        },
      );
      final cachePutBestEffort = persistence.putBlock;
      final Map<String, String> validatedCacheWrites = <String, String>{};
      Future<bool> putValidated(String key, String html) async {
        // Retain only a digest: completed chapter HTML is released to keep
        // large-book memory bounded.
        final String digest = sha256.convert(utf8.encode(html)).toString();
        if (validatedCacheWrites[key] == digest) return false;
        final bool written = await cachePutBestEffort(key, html);
        if (written) validatedCacheWrites[key] = digest;
        return written;
      }

      final saveResumeStateBestEffort = persistence.save;

      if (previousState != null) {
        emit(
          currentJob,
          s.runLogFoundCheckpoint(
            checkpointBlocks,
            totalBlocks,
            previousState.updatedAtIso8601,
          ),
        );
      } else if (unreadableResumeState) {
        emit(currentJob, s.runLogCheckpointUnreadable);
      }

      emit(
        currentJob,
        s.runLogRestoringCache(selectedChapters.length, totalBlocks),
      );
      throwIfCancelled();

      final CacheRestorationResult restoration =
          await CacheRestorationScanner(
            readTranslation: _cacheStore.getBlockTranslation,
            configuredApiKey: config.apiKey,
          ).scan(
            chapters: selectedChapters,
            cacheKeyFor: (InspectedChapter chapter, ExtractedBlock block) =>
                _blockCacheKey(
                  config,
                  block,
                  chapterPath: chapter.path,
                  inputFingerprint: inputFingerprint,
                  contextIdentity: contextIdentity,
                  confirmedStyleProfile: userStyleProfile,
                ),
            throwIfCancelled: throwIfCancelled,
            onProgress: (CacheRestorationProgress progress) {
              emit(
                currentJob.copyWith(
                  phase: TranslationJobPhase.cacheRestoration,
                  progress: checkpointBlocks / totalBlocks,
                  completedBlocks: checkpointBlocks,
                  cachedBlocks: progress.cachedBlocks,
                  resumedBlocks: previousState == null
                      ? 0
                      : progress.cachedBlocks,
                  cacheScanScannedBlocks: progress.scannedBlocks,
                  cacheScanTotalBlocks: progress.totalBlocks,
                  currentChapter: s.runProgressRestoringCache,
                  currentBlock: null,
                ),
                s.runLogCacheScanProgress(
                  progress.scannedBlocks,
                  progress.totalBlocks,
                  progress.cachedBlocks,
                ),
              );
            },
          );
      throwIfCancelled();

      int completedBlocks = restoration.cachedBlocks;
      int completedFiles = 0;
      int cachedBlocks = restoration.cachedBlocks;
      int resumedBlocks = previousState == null ? 0 : restoration.cachedBlocks;
      final bool hasPendingBlocks = cachedBlocks < totalBlocks;
      currentJob = currentJob.copyWith(
        phase: hasPendingBlocks
            ? TranslationJobPhase.translation
            : TranslationJobPhase.cacheRestoration,
        progress: completedBlocks / totalBlocks,
        completedBlocks: completedBlocks,
        cachedBlocks: cachedBlocks,
        resumedBlocks: resumedBlocks,
        cacheScanScannedBlocks: restoration.scannedBlocks,
        cacheScanTotalBlocks: totalBlocks,
        currentChapter: hasPendingBlocks
            ? s.runProgressContinuingTranslation
            : s.runProgressAllRestoredFromCache,
        currentBlock: null,
      );
      emit(
        currentJob,
        hasPendingBlocks
            ? s.runLogCacheRestoredPartial(
                cachedBlocks,
                totalBlocks - cachedBlocks,
              )
            : s.runLogCacheRestoredAll(totalBlocks),
      );
      await saveResumeStateBestEffort(currentJob, force: true);

      final Map<String, InspectedChapter> updatedByPath =
          <String, InspectedChapter>{
            for (final InspectedChapter chapter in chapters)
              chapter.path: chapter,
          };

      _BookMemory? bookMemory = userStyleProfile == null
          ? null
          : _BookMemory.empty.copyWith(
              styleProfile: userStyleProfile,
              styleProfileConfirmed: true,
            );
      bool initialBookMemoryAttempted = false;
      final memoryChapters = <String>{...?restoredMemory?.completedChapterPaths};
      // Positional memory history for retranslated chapters: each entry is
      // the rolling memory right after its chapter's update, in book order.
      // A chapter that is (re)translated later receives the newest entry
      // before its own position, never memory already containing later
      // chapters' summaries and terms.
      final List<({String path, _BookMemory memory})> memoryTimeline = [
        ...?restoredMemory?.timeline,
      ];
      // 性能-#52: incremental write cursor for [recordMemoryTimeline].
      // Entries are append-only with strictly increasing positions (a
      // re-recorded earlier chapter is dropped, never rewritten), so the
      // write side only needs the high-water mark instead of rescanning
      // the whole timeline per chapter (O(n^2) total for a book).
      int maxRecordedTimelinePosition = -1;
      for (final entry in memoryTimeline) {
        final int? restoredPosition = selectedPositionByPath[entry.path];
        if (restoredPosition != null &&
            restoredPosition > maxRecordedTimelinePosition) {
          maxRecordedTimelinePosition = restoredPosition;
        }
      }
      if (restoredMemory != null) {
        bookMemory = restoredMemory.memory;
        initialBookMemoryAttempted = true;
        AppLogger.info('Restored book memory; skipping initial API generation.', tag: 'book-memory');
      }

      /// Rolling-memory snapshot for [chapter]'s own time position: the
      /// newest timeline entry strictly before the chapter in book order.
      ///
      /// 性能-#38: chapters are translated in book order and the timeline
      /// only appends entries with strictly increasing positions, so the
      /// selection cursor only moves forward — each timeline entry is
      /// examined once per run instead of once per chapter (O(n) total,
      /// not O(n^2)). A non-monotonic call resyncs via a fresh scan.
      ///
      /// P2-#16: when no earlier entry exists, the live memory is used as
      /// the fallback only for a fresh run (or a restore that never
      /// recorded a chapter, where the live memory is still the initial
      /// memory). After a checkpoint restore with a non-empty timeline the
      /// live rolling memory may already contain later chapters, so a
      /// chapter with no earlier entry receives no memory rather than
      /// leaking future content (positional snapshot isolation).
      final MemorySnapshotCursor snapshotCursorState =
          EpubChapterTranslator.memorySnapshotCursorForTest();

      Map<String, Object?>? snapshotFallback() {
        return EpubChapterTranslator.memorySnapshotFallbackForTest(
          hasRestoredMemory: restoredMemory != null,
          timelineIsEmpty: memoryTimeline.isEmpty,
          liveMemory: bookMemory?.toJson(),
        );
      }

      Map<String, Object?>? bookMemorySnapshotFor(InspectedChapter chapter) {
        return EpubChapterTranslator.selectMemorySnapshotForTest(
          timeline: memoryTimeline,
          positionByPath: selectedPositionByPath,
          chapterPath: chapter.path,
          cursor: snapshotCursorState,
          serialize: (Object memory) => (memory as _BookMemory).toJson(),
          fallback: snapshotFallback,
        );
      }

      /// Records a chapter's post-update memory in the positional timeline.
      /// Only forward progress extends the timeline: re-updating an earlier
      /// chapter must not rewrite history that later chapters already rely
      /// on for their own snapshots.
      void recordMemoryTimeline(String chapterPath, _BookMemory memory) {
        final int? position = selectedPositionByPath[chapterPath];
        // 性能-#52: incremental cursor — only forward progress extends the
        // timeline. Anything at or behind the high-water mark is a
        // re-recorded earlier chapter and must not rewrite history that
        // later chapters already rely on for their own snapshots.
        if (!EpubChapterTranslator.shouldRecordMemoryTimelineEntryForTest(
          position: position,
          maxRecordedPosition: maxRecordedTimelinePosition,
        )) {
          return;
        }
        memoryTimeline.add((path: chapterPath, memory: memory));
        maxRecordedTimelinePosition = position!;
      }

      Future<void> persistBookMemory() async {
        final memory = bookMemory;
        if (memory == null) return;
        bookMemory = memory.withLockedGlossary(config.lockedGlossary);
        try {
          await memoryCheckpoint.save(
            bookMemory!,
            completedChapterPaths: memoryChapters,
            timeline: memoryTimeline,
          );
        } catch (error) {
          AppLogger.warn('Book memory checkpoint save failed (${error.runtimeType}).', tag: 'book-memory');
        }
      }

      if (userStyleProfile != null && !userStyleProfile.isEmpty) {
        emit(
          currentJob,
          s.runLogStyleProfileConfirmed(userStyleProfile.summaryLabel),
        );
      }

      Future<void> ensureInitialBookMemory() async {
        if (initialBookMemoryAttempted) {
          return;
        }
        initialBookMemoryAttempted = true;
        throwIfCancelled();
        try {
          final Stopwatch memoryStopwatch = Stopwatch()..start();
          final _BookMemory initialMemory = await trackMemoryRequests(
            () => _memory.generateInitialBookMemory(
              dio: dio,
              config: config,
              chapters: chapters,
              cancelToken: cancelToken,
            ),
          );
          bookMemory = userStyleProfile == null
              ? initialMemory
              : initialMemory.copyWith(
                  styleProfile: userStyleProfile,
                  styleProfileConfirmed: true,
                );
          memoryStopwatch.stop();
          await persistBookMemory();
          if (initialMemory.isEmpty &&
              (userStyleProfile == null || userStyleProfile.isEmpty)) {
            emit(
              currentJob,
              s.runLogBookMemoryNone(_formatDuration(memoryStopwatch.elapsed)),
            );
          } else {
            emit(
              currentJob,
              s.runLogBookMemoryCreated(
                _formatDuration(memoryStopwatch.elapsed),
              ),
            );
            final TranslationStyleProfile styleProfile =
                bookMemory?.styleProfile ?? TranslationStyleProfile.empty;
            if (!config.styleProfileEnabled) {
              emit(currentJob, s.runLogStyleProfileDisabled);
            } else if (userStyleProfile != null && !userStyleProfile.isEmpty) {
              emit(
                currentJob,
                s.runLogStyleProfileWillGuide(userStyleProfile.summaryLabel),
              );
            } else if (styleProfile.shouldInject) {
              emit(
                currentJob,
                s.runLogStyleProfileGenerated(styleProfile.summaryLabel),
              );
            } else if (!styleProfile.isEmpty) {
              emit(
                currentJob,
                s.runLogStyleProfileLowConfidence(styleProfile.summaryLabel),
              );
            } else {
              emit(currentJob, s.runLogStyleProfileNoSignal);
            }
          }
        } catch (error) {
          if (userStyleProfile != null) {
            bookMemory = _BookMemory.empty.copyWith(
              styleProfile: userStyleProfile,
              styleProfileConfirmed: true,
            );
            emit(
              currentJob,
              s.runLogBookMemorySkippedConfirmed(
                _linePreview(_safeErrorText(error, config)),
              ),
            );
          } else {
            emit(
              currentJob,
              s.runLogBookMemorySkipped(
                _linePreview(_safeErrorText(error, config)),
              ),
            );
          }
        }
      }

      final footnoteClassificationByChapter = <int, bool>{};
      bool isFootnoteChapter(int index) =>
          footnoteClassificationByChapter.putIfAbsent(
            index,
            () => FootnoteBatchPlanner.isStandaloneFootnoteChapter(
              selectedChapters[index],
            ),
          );

      Future<int> translateFootnoteRun(int startChapterIndex) async {
        int endChapterIndex = startChapterIndex;
        while (endChapterIndex + 1 < selectedChapters.length &&
            isFootnoteChapter(endChapterIndex + 1)) {
          endChapterIndex += 1;
        }

        final Map<int, Map<String, ExtractedBlock>> translatedByChapterIndex =
            <int, Map<String, ExtractedBlock>>{};
        final Map<int, List<ExtractedBlock>> pendingBlocksByChapter =
            <int, List<ExtractedBlock>>{};
        int runCacheHits = 0;

        for (
          int chapterIndex = startChapterIndex;
          chapterIndex <= endChapterIndex;
          chapterIndex += 1
        ) {
          throwIfCancelled();
          final InspectedChapter chapter = selectedChapters[chapterIndex];
          emit(
            currentJob.copyWith(
              currentChapter: chapter.title,
              currentBlock: null,
              completedFiles: completedFiles,
              completedBlocks: completedBlocks,
            ),
            s.runLogTranslatingChapter(
              chapterIndex + 1,
              selectedChapters.length,
              chapter.title,
            ),
          );
          final Map<String, ExtractedBlock> translatedById =
              <String, ExtractedBlock>{};
          final List<ExtractedBlock> pendingBlocks = <ExtractedBlock>[];
          int chapterCacheHits = 0;
          for (final ExtractedBlock block in chapter.blocks) {
            throwIfCancelled();
            final String? cachedTranslation = restoration.translationFor(
              chapter.path,
              block.id,
            );
            if (cachedTranslation == null || cachedTranslation.trim().isEmpty) {
              pendingBlocks.add(block);
              continue;
            }
            translatedById[block.id] = block.copyWith(
              translatedHtml: cachedTranslation,
            );
            chapterCacheHits += 1;
            runCacheHits += 1;
          }
          translatedByChapterIndex[chapterIndex] = translatedById;
          pendingBlocksByChapter[chapterIndex] = pendingBlocks;

          if (chapterCacheHits > 0) {
            final TranslationJob cachedJob = currentJob.copyWith(
              progress: completedBlocks / totalBlocks,
              currentChapter: chapter.title,
              currentBlock: null,
              completedFiles: completedFiles,
              totalFiles: selectedChapters.length,
              completedBlocks: completedBlocks,
              totalBlocks: totalBlocks,
              cachedBlocks: cachedBlocks,
              resumedBlocks: resumedBlocks,
            );
            emit(
              cachedJob,
              s.runLogReusedChapterCache(chapterCacheHits, chapter.title),
            );
          }
        }

        final int pendingCount = pendingBlocksByChapter.values.fold<int>(
          0,
          (int sum, List<ExtractedBlock> blocks) => sum + blocks.length,
        );
        if (pendingCount > 0) {
          await ensureInitialBookMemory();
          throwIfCancelled();
        }
        final List<FootnoteTranslationBatch> batches = [];
        final snapshotGroup = <int, List<ExtractedBlock>>{};
        Map<String, Object?>? groupMemory;
        String? groupIdentity;
        void flushSnapshotGroup() {
          if (snapshotGroup.isEmpty) return;
          batches.addAll(
            _footnoteBatchPlanner.plan(
              chapters: selectedChapters,
              pendingBlocksByChapter: snapshotGroup,
              footnoteClassificationByChapter: footnoteClassificationByChapter,
              chunkSize: config.chunkSize,
              bookMemory: groupMemory,
            ),
          );
          snapshotGroup.clear();
        }
        for (final index in pendingBlocksByChapter.keys.toList()..sort()) {
          final snapshot = bookMemorySnapshotFor(selectedChapters[index]);
          final identity = jsonEncode(snapshot);
          if (identity != groupIdentity) flushSnapshotGroup();
          groupIdentity = identity;
          groupMemory = snapshot;
          snapshotGroup[index] = pendingBlocksByChapter[index]!;
        }
        flushSnapshotGroup();
        emit(
          currentJob.copyWith(
            currentChapter: selectedChapters[startChapterIndex].title,
            completedFiles: completedFiles,
            completedBlocks: completedBlocks,
          ),
          s.runLogPreparedFootnoteBatches(
            batches.length,
            pendingCount,
            endChapterIndex - startChapterIndex + 1,
            runCacheHits,
          ),
        );

        Future<void> persistTranslations(
          List<FootnoteBlockReference> references,
          Map<String, String> translatedByRequestId,
        ) async {
          final Stopwatch cacheStopwatch = Stopwatch()..start();
          for (final FootnoteBlockReference reference in references) {
            throwIfCancelled();
            final String? translated =
                translatedByRequestId[reference.requestId];
            if (translated == null || translated.isEmpty) {
              throw FormatException(
                'Translated footnote ${reference.requestId} is missing before cache write.',
              );
            }
            final bool cacheable = !_isDegradedBlock(
              chapterPath: reference.chapter.path,
              blockId: reference.block.id,
            );
            if (cacheable) {
              // Count only successful writes: a swallowed cache failure
              // must not inflate the final "cache writes" report.
              if (await putValidated(
                _blockCacheKey(
                  config,
                  reference.block,
                  chapterPath: reference.chapter.path,
                  inputFingerprint: inputFingerprint,
                  contextIdentity: contextIdentity,
                  confirmedStyleProfile: userStyleProfile,
                ),
                translated,
              )) {
                cacheWriteCount += 1;
              }
            }
            translatedByChapterIndex[reference.chapterIndex]![reference
                .block
                .id] = reference.block.copyWith(
              translatedHtml: translated,
            );
            completedBlocks += 1;
            // Both throughput and the final report subtract degraded API
            // work, so count every completed reference before subtraction.
            apiTranslatedBlocks += 1;
            persistence.blockCompleted();
            currentJob = currentJob.copyWith(
              progress: completedBlocks / totalBlocks,
              currentChapter: reference.chapter.title,
              currentBlock: _linePreview(reference.block.sourceText),
              completedFiles: completedFiles,
              totalFiles: selectedChapters.length,
              completedBlocks: completedBlocks,
              totalBlocks: totalBlocks,
              apiDegradedBlocks: _apiDegradedBlocks,
              cachedBlocks: cachedBlocks,
              resumedBlocks: resumedBlocks,
            );
          }
          cacheStopwatch.stop();
          totalCacheWriteElapsed += cacheStopwatch.elapsed;
        }

        await const TranslationWorkQueue().map<FootnoteTranslationBatch, void>(
          batches,
          concurrency: concurrency,
          throwIfCancelled: throwIfCancelled,
          process: (FootnoteTranslationBatch batch, int batchIndex) async {
            final Stopwatch batchStopwatch = Stopwatch()..start();
            Duration batchApiElapsed = Duration.zero;
            int requestCount = 0;

            Future<Map<String, String>> sendFootnoteRequest(
              FootnoteTranslationBatch requestBatch,
            ) async {
              final Stopwatch requestStopwatch = Stopwatch()..start();
              try {
                return await _strategy._translateFootnoteBatch(
                  dio: dio,
                  config: config,
                  batch: requestBatch,
                  cancelToken: cancelToken,
                  onRequestAttempt: () {
                    requestCount += 1;
                    footnoteRequestCount += 1;
                  },
                  onValidated: (String id, String html) async {
                    final reference = requestBatch.references.firstWhere(
                      (r) => r.requestId == id,
                    );
                    final Stopwatch stopwatch = Stopwatch()..start();
                    if (await putValidated(
                      _blockCacheKey(
                        config,
                        reference.block,
                        chapterPath: reference.chapter.path,
                        inputFingerprint: inputFingerprint,
                        contextIdentity: contextIdentity,
                        confirmedStyleProfile: userStyleProfile,
                      ),
                      html,
                    )) {
                      cacheWriteCount += 1;
                    }
                    totalCacheWriteElapsed += stopwatch.elapsed;
                  },
                );
              } finally {
                requestStopwatch.stop();
                batchApiElapsed += requestStopwatch.elapsed;
                totalApiElapsed += requestStopwatch.elapsed;
              }
            }

            try {
              final Map<String, String> translated = await sendFootnoteRequest(
                batch,
              );
              await persistTranslations(batch.references, translated);
              await saveResumeStateBestEffort(currentJob, force: true);
            } catch (error) {
              if (error is! DioException ||
                  !TranslationApiClient.shouldFallbackBatchDioException(
                    error,
                  )) {
                rethrow;
              }
              if (batch.references.length <= 1) {
                rethrow;
              }
              await const TranslationWorkQueue()
                  .map<FootnoteBlockReference, void>(
                    batch.references,
                    concurrency: concurrency,
                    throwIfCancelled: throwIfCancelled,
                    process:
                        (FootnoteBlockReference reference, int index) async {
                          final Map<String, String> translated =
                              await sendFootnoteRequest(
                                FootnoteTranslationBatch(
                                  <FootnoteBlockReference>[reference],
                                  context: batch.context,
                                ),
                              );
                          await persistTranslations(<FootnoteBlockReference>[
                            reference,
                          ], translated);
                        },
                  );
              await saveResumeStateBestEffort(currentJob, force: true);
            }
            batchStopwatch.stop();
            footnoteBatchCount += 1;
            emit(
              currentJob,
              s.runLogFootnoteBatchPerformance(
                batchIndex + 1,
                batches.length,
                batch.references.length,
                requestCount,
                _formatDuration(batchStopwatch.elapsed),
                _formatDuration(batchApiElapsed),
              ),
            );
            emit(
              currentJob,
              s.runLogFootnoteBatchDone(
                completedBlocks,
                totalBlocks,
                batchIndex + 1,
                batches.length,
              ),
            );
          },
        );

        for (
          int chapterIndex = startChapterIndex;
          chapterIndex <= endChapterIndex;
          chapterIndex += 1
        ) {
          throwIfCancelled();
          final InspectedChapter chapter = selectedChapters[chapterIndex];
          final Map<String, ExtractedBlock> translatedById =
              translatedByChapterIndex[chapterIndex]!;
          final List<ExtractedBlock> translatedBlocks = chapter.blocks
              .map((ExtractedBlock block) => translatedById[block.id] ?? block)
              .toList();
          updatedByPath[chapter.path] = chapter.copyWith(
            blocks: translatedBlocks,
            translatedBody: _previewBodyFromBlocks(
              translatedBlocks,
              fallback: '',
            ),
          );
          completedFiles += 1;
          final TranslationJob chapterDoneJob = currentJob.copyWith(
            progress: completedBlocks / totalBlocks,
            currentChapter: chapter.title,
            currentBlock: null,
            completedFiles: completedFiles,
            totalFiles: selectedChapters.length,
            completedBlocks: completedBlocks,
            totalBlocks: totalBlocks,
            cachedBlocks: cachedBlocks,
            resumedBlocks: resumedBlocks,
          );
          emit(
            chapterDoneJob,
            s.runLogChapterCompleted(
              completedFiles,
              selectedChapters.length,
              chapter.title,
            ),
          );
          await saveResumeStateBestEffort(chapterDoneJob, force: true);
          // Footnote-run chapters are done: release their per-block source
          // strings (see _releaseChapterSourceStrings).
          selectedChapters[chapterIndex] = _releaseChapterSourceStrings(
            chapter,
          );
          updatedByPath[chapter.path] = _releaseChapterSourceStrings(
            updatedByPath[chapter.path]!,
          );
          final released = await sourceSpool.release(chapter.copyWith(
            blocks: translatedBlocks,
            translatedBody: updatedByPath[chapter.path]!.translatedBody,
          ));
          selectedChapters[chapterIndex] = released;
          updatedByPath[chapter.path] = released;
          final int? originalIndex = chapterIndexByPath[chapter.path];
          if (originalIndex != null) chapters[originalIndex] = released;
          final int? invocationIndex = invocationIndexByPath[chapter.path];
          if (invocationIndex != null) {
            invocationChapters[invocationIndex] = released;
          }
          try {
            onChapterSourcesReleased?.call(chapter.path);
          } catch (error) {
            // A UI-side chapter-sources-released listener must never abort a
            // translation run. Log the failure and keep the pipeline going.
            AppLogger.warn(
              'Chapter-sources-released callback failed (${error.runtimeType}); continuing.',
              tag: 'translate',
            );
          }
          translatedByChapterIndex.remove(chapterIndex);
          pendingBlocksByChapter.remove(chapterIndex);
          restoration.translationsByChapter.remove(chapter.path);
        }
        return endChapterIndex;
      }

      try {
        for (
          int chapterIndex = 0;
          chapterIndex < selectedChapters.length;
          chapterIndex += 1
        ) {
          throwIfCancelled();
          final InspectedChapter chapter = selectedChapters[chapterIndex];
          if (isFootnoteChapter(chapterIndex)) {
            chapterIndex = await translateFootnoteRun(chapterIndex);
            continue;
          }
          final Stopwatch chapterStopwatch = Stopwatch()..start();
          Duration chapterApiElapsed = Duration.zero;
          Duration chapterCacheWriteElapsed = Duration.zero;
          int chapterApiBlocks = 0;
          int chapterCacheWrites = 0;
          emit(
            currentJob.copyWith(
              currentChapter: chapter.title,
              currentBlock: null,
              completedFiles: completedFiles,
              completedBlocks: completedBlocks,
            ),
            s.runLogTranslatingChapter(
              chapterIndex + 1,
              selectedChapters.length,
              chapter.title,
            ),
          );

          final Map<String, ExtractedBlock> translatedById =
              <String, ExtractedBlock>{};
          int chapterCacheHits = 0;
          final List<ExtractedBlock> pendingBlocks = <ExtractedBlock>[];
          for (final ExtractedBlock block in chapter.blocks) {
            throwIfCancelled();
            final String? cachedTranslation = restoration.translationFor(
              chapter.path,
              block.id,
            );
            if (cachedTranslation == null || cachedTranslation.trim().isEmpty) {
              pendingBlocks.add(block);
              continue;
            }
            translatedById[block.id] = block.copyWith(
              translatedHtml: cachedTranslation,
            );
            chapterCacheHits += 1;
          }

          if (chapterCacheHits > 0) {
            final TranslationJob cachedJob = currentJob.copyWith(
              progress: completedBlocks / totalBlocks,
              currentChapter: chapter.title,
              currentBlock: null,
              completedFiles: completedFiles,
              totalFiles: selectedChapters.length,
              completedBlocks: completedBlocks,
              totalBlocks: totalBlocks,
              cachedBlocks: cachedBlocks,
              resumedBlocks: resumedBlocks,
            );
            emit(
              cachedJob,
              s.runLogReusedChapterCache(chapterCacheHits, chapter.title),
            );
          }

          if (pendingBlocks.isNotEmpty) {
            await ensureInitialBookMemory();
            throwIfCancelled();
          }

          final List<TranslationBlockBatch> batches = _batchPlanner.plan(
            pendingBlocks: pendingBlocks,
            chunkSize: config.chunkSize,
            chapterBlocks: chapter.blocks,
            chapterTitle: chapter.title,
            // Positional snapshot: a retranslated earlier chapter must not
            // see rolling memory that already contains later chapters.
            bookMemory: bookMemorySnapshotFor(chapter),
          );
          emit(
            currentJob.copyWith(
              currentChapter: chapter.title,
              completedFiles: completedFiles,
              completedBlocks: completedBlocks,
            ),
            s.runLogPreparedBatches(batches.length, chapter.title),
          );

          await const TranslationWorkQueue().map<TranslationBlockBatch, void>(
            batches,
            concurrency: concurrency,
            throwIfCancelled: throwIfCancelled,
            process: (TranslationBlockBatch batch, int batchIndex) async {
              final int batchNumber = batchIndex + 1;
              final Stopwatch apiStopwatch = Stopwatch()..start();
              final List<String> translated = await _strategy
                  .translateBlockBatch(
                    dio: dio,
                    config: config,
                    batch: batch,
                    chapterPath: chapter.path,
                    cancelToken: cancelToken,
                    onValidated: (String id, String html) async {
                      final block = batch.blocks.firstWhere((b) => b.id == id);
                      final Stopwatch stopwatch = Stopwatch()..start();
                      if (await putValidated(
                        _blockCacheKey(
                          config,
                          block,
                          chapterPath: chapter.path,
                          inputFingerprint: inputFingerprint,
                          contextIdentity: contextIdentity,
                          confirmedStyleProfile: userStyleProfile,
                        ),
                        html,
                      )) {
                        chapterCacheWrites += 1;
                        cacheWriteCount += 1;
                      }
                      chapterCacheWriteElapsed += stopwatch.elapsed;
                      totalCacheWriteElapsed += stopwatch.elapsed;
                    },
                  );
              apiStopwatch.stop();
              // Persist paid responses before reporting completion,
              // including when another worker has already failed.
              // Degraded marks for this batch's own blocks are all
              // recorded by now, so the cacheable check is complete.
              final Stopwatch cacheWriteStopwatch = Stopwatch()..start();
              final List<int> cacheableIndexes = <int>[
                for (int index = 0; index < batch.blocks.length; index += 1)
                  if (!_isDegradedBlock(
                    chapterPath: chapter.path,
                    blockId: batch.blocks[index].id,
                  ))
                    index,
              ];
              final List<bool> cacheWriteResults =
                  await Future.wait<bool>(<Future<bool>>[
                    for (final int index in cacheableIndexes)
                      putValidated(
                        _blockCacheKey(
                          config,
                          batch.blocks[index],
                          chapterPath: chapter.path,
                          inputFingerprint: inputFingerprint,
                          contextIdentity: contextIdentity,
                          confirmedStyleProfile: userStyleProfile,
                        ),
                        translated[index],
                      ),
                  ]);
              cacheWriteStopwatch.stop();
              // Count only the writes that actually succeeded: a
              // swallowed cache failure must not inflate the final
              // "cache writes" report.
              final int succeededCacheWrites = cacheWriteResults
                  .where((bool ok) => ok)
                  .length;
              // Each compound assignment below executes synchronously
              // (no await between read and write), so concurrent
              // window closures cannot interleave mid-update.
              chapterCacheWriteElapsed += cacheWriteStopwatch.elapsed;
              totalCacheWriteElapsed += cacheWriteStopwatch.elapsed;
              chapterCacheWrites += succeededCacheWrites;
              cacheWriteCount += succeededCacheWrites;
              final _TimedBatchResult timedBatch = _TimedBatchResult(
                batch: batch,
                translatedBlocks: translated,
                batchNumber: batchNumber,
                elapsed: apiStopwatch.elapsed,
              );
              throwIfCancelled();
              final List<String> translatedBatch = timedBatch.translatedBlocks;
              chapterApiElapsed += timedBatch.elapsed;
              totalApiElapsed += timedBatch.elapsed;
              chapterApiBlocks += batch.blocks.length;
              apiTranslatedBlocks += batch.blocks.length;
              emit(
                currentJob.copyWith(
                  currentChapter: chapter.title,
                  completedFiles: completedFiles,
                  completedBlocks: completedBlocks,
                ),
                s.runLogBatchPerformance(
                  timedBatch.batchNumber,
                  batches.length,
                  chapter.title,
                  batch.blocks.length,
                  _formatDuration(timedBatch.elapsed),
                ),
              );

              for (int index = 0; index < batch.blocks.length; index += 1) {
                throwIfCancelled();
                final ExtractedBlock sourceBlock = batch.blocks[index];
                final ExtractedBlock translatedBlock = sourceBlock.copyWith(
                  translatedHtml: translatedBatch[index],
                );
                translatedById[sourceBlock.id] = translatedBlock;
                completedBlocks += 1;
                persistence.blockCompleted();
                final TranslationJob nextJob = currentJob.copyWith(
                  progress: completedBlocks / totalBlocks,
                  currentChapter: chapter.title,
                  currentBlock: _linePreview(sourceBlock.sourceText),
                  completedFiles: completedFiles,
                  totalFiles: selectedChapters.length,
                  completedBlocks: completedBlocks,
                  totalBlocks: totalBlocks,
                  apiDegradedBlocks: _apiDegradedBlocks,
                  cachedBlocks: cachedBlocks,
                  resumedBlocks: resumedBlocks,
                );
                currentJob = nextJob;
                await saveResumeStateBestEffort(nextJob);
              }
              emit(
                currentJob,
                s.runLogBatchDone(
                  completedBlocks,
                  totalBlocks,
                  timedBatch.batchNumber,
                  batches.length,
                  chapter.title,
                ),
              );
            },
          );

          completedFiles += 1;
          chapterStopwatch.stop();
          final List<ExtractedBlock> translatedBlocks = chapter.blocks
              .map((ExtractedBlock block) => translatedById[block.id] ?? block)
              .toList();
          updatedByPath[chapter.path] = chapter.copyWith(
            blocks: translatedBlocks,
            translatedBody: _previewBodyFromBlocks(
              translatedBlocks,
              fallback: '',
            ),
          );
          final TranslationJob chapterDoneJob = currentJob.copyWith(
            progress: completedBlocks / totalBlocks,
            currentChapter: chapter.title,
            currentBlock: null,
            completedFiles: completedFiles,
            totalFiles: selectedChapters.length,
            completedBlocks: completedBlocks,
            totalBlocks: totalBlocks,
            cachedBlocks: cachedBlocks,
            resumedBlocks: resumedBlocks,
          );
          emit(
            chapterDoneJob,
            s.runLogChapterCompleted(
              completedFiles,
              selectedChapters.length,
              chapter.title,
            ),
          );
          emit(
            chapterDoneJob,
            s.runLogChapterPerformance(
              chapterIndex + 1,
              selectedChapters.length,
              _formatDuration(chapterStopwatch.elapsed),
              _formatDuration(chapterApiElapsed),
              chapterApiBlocks,
              _formatDuration(chapterCacheWriteElapsed),
              chapterCacheWrites,
              _formatBlocksPerMinute(
                chapterApiBlocks,
                chapterStopwatch.elapsed,
              ),
            ),
          );
          throwIfCancelled();
          final bool futurePendingBlocks = restoration
              .hasPendingBlocksFromChapter(chapterIndex + 1);
          if (futurePendingBlocks) {
            await ensureInitialBookMemory();
            if (!memoryChapters.contains(chapter.path)) {
            try {
              final Stopwatch memoryStopwatch = Stopwatch()..start();
              bookMemory = await trackMemoryRequests(
                () => _memory.updateBookMemoryAfterChapter(
                  dio: dio,
                  config: config,
                  currentMemory: _BookMemory.fromJson(
                    bookMemorySnapshotFor(chapter) ?? <String, Object?>{},
                    trustedLocks: true,
                  ),
                  chapter: updatedByPath[chapter.path]!,
                  degradedBlockIds: _degradedBlocks,
                  cancelToken: cancelToken,
                ),
              );
              memoryStopwatch.stop();
              memoryChapters.add(chapter.path);
              // Resolve user locks before recording so the timeline entry
              // carries them (previously achieved by recording after the
              // persist, which applied the locks inside persistBookMemory).
              bookMemory =
                  bookMemory!.withLockedGlossary(config.lockedGlossary);
              // Record BEFORE persist (A-2): no persist happens after the run
              // ends, so persisting first would leave the checkpoint lagging
              // one chapter behind after a cancellation.
              await _recordAndPersistChapterMemory(
                record: () => recordMemoryTimeline(chapter.path, bookMemory!),
                persist: persistBookMemory,
              );
              emit(
                chapterDoneJob,
                s.runLogBookMemoryUpdated(
                  chapter.title,
                  _formatDuration(memoryStopwatch.elapsed),
                ),
              );
            } catch (error) {
              emit(
                chapterDoneJob,
                s.runLogBookMemoryChapterSkipped(
                  chapter.title,
                  _linePreview(_safeErrorText(error, config)),
                ),
              );
            }
            }
          } else {
            emit(
              chapterDoneJob,
              s.runLogBookMemoryChapterSkippedNoNeed(chapter.title),
            );
          }
          throwIfCancelled();
          await saveResumeStateBestEffort(chapterDoneJob, force: true);
          // This chapter is fully translated and cached: release its
          // per-block source strings (see _releaseChapterSourceStrings).
          selectedChapters[chapterIndex] = _releaseChapterSourceStrings(
            chapter,
          );
          updatedByPath[chapter.path] = _releaseChapterSourceStrings(
            updatedByPath[chapter.path]!,
          );
          final released = await sourceSpool.release(chapter.copyWith(
            blocks: translatedBlocks,
            translatedBody: updatedByPath[chapter.path]!.translatedBody,
          ));
          selectedChapters[chapterIndex] = released;
          updatedByPath[chapter.path] = released;
          final int? originalIndex = chapterIndexByPath[chapter.path];
          if (originalIndex != null) chapters[originalIndex] = released;
          final int? invocationIndex = invocationIndexByPath[chapter.path];
          if (invocationIndex != null) {
            invocationChapters[invocationIndex] = released;
          }
          try {
            onChapterSourcesReleased?.call(chapter.path);
          } catch (error) {
            // A UI-side chapter-sources-released listener must never abort a
            // translation run. Log the failure and keep the pipeline going.
            AppLogger.warn(
              'Chapter-sources-released callback failed (${error.runtimeType}); continuing.',
              tag: 'translate',
            );
          }
          restoration.translationsByChapter.remove(chapter.path);
        }
      } catch (error) {
        final bool cancelled =
            error is TranslationCancelledException || _isCancelError(error);
        // The final checkpoint is best-effort: a locked jobs/<jobKey>.json
        // (Windows antivirus/OneDrive) must not mask the original
        // translation error that brought us here.
        try {
          await _cacheStore.saveJobState(
            JobResumeState(
              jobKey: jobKey,
              inputFingerprint: inputFingerprint,
              inputPath: currentJob.inputPath,
              outputPath: currentJob.outputPath,
              status: cancelled ? 'cancelled' : 'failed',
              completedFiles: completedFiles,
              totalFiles: selectedChapters.length,
              completedBlocks: completedBlocks,
              totalBlocks: totalBlocks,
              cachedBlocks: cachedBlocks,
              resumedBlocks: resumedBlocks,
              currentChapter: currentJob.currentChapter ?? '',
              updatedAtIso8601: DateTime.now().toIso8601String(),
            ),
          );
        } catch (checkpointError) {
          AppLogger.warn(
            'Final checkpoint save failed (${checkpointError.runtimeType}); '
            'rethrowing the original error.',
            tag: 'translate',
          );
        }
        if (cancelled) {
          throw const TranslationCancelledException();
        }
        rethrow;
      }

      throwIfCancelled();
      emit(
        currentJob.copyWith(
          progress: 0.98,
          currentChapter: s.runProgressRepacking,
          currentBlock: null,
          completedFiles: completedFiles,
          totalFiles: selectedChapters.length,
          completedBlocks: completedBlocks,
          totalBlocks: totalBlocks,
          cachedBlocks: cachedBlocks,
          resumedBlocks: resumedBlocks,
        ),
        s.runLogRepacking,
      );

      final List<InspectedChapter> updatedChapters = chapters
          .map(
            (InspectedChapter chapter) =>
                updatedByPath[chapter.path] ?? chapter,
          )
          .toList();
      // Repack needs the original document skeleton. Reload only that string;
      // block sources remain released. Retry on the next invocation restores
      // from the inspected EPUB; within this invocation the spool is exact.
      for (int index = 0; index < updatedChapters.length; index++) {
        throwIfCancelled();
        final restored = await sourceSpool.restore(
          updatedChapters[index],
          blocks: false,
          isCancelled: () =>
              cancelToken.isCancelled || (isCancelled?.call() ?? false),
        );
        updatedChapters[index] = restored;
      }
      final int degradedBlockCount = _degradedBlocks.length;
      if (degradedBlockCount > 0) {
        // Scoped keys use \u0000 as the separator; render it readably.
        final String degradedBlockSample = _degradedBlocks
            .take(20)
            .map(
              (String key) =>
                  '${key.replaceAll('\u0000', ':')}${_run.degradedReasons[key] == null ? '' : ' (${_run.degradedReasons[key]})'}',
            )
            .join(',');
        emit(
          currentJob.copyWith(
            currentChapter: s.runProgressRepacking,
            currentBlock: null,
            degradedBlockCount: degradedBlockCount,
          ),
          s.runLogDegradedBlocks(degradedBlockCount, degradedBlockSample),
        );
      }
      final Stopwatch repackStopwatch = Stopwatch()..start();
      throwIfCancelled();
      // Translate the book's metadata title (one lightweight call) so the
      // finished EPUB's dc:title / NCX docTitle show the target language.
      // Fail-safe: null keeps the original title.
      String? translatedTitle;
      bool titleTranslationFailed = false;
      if (dioReady) {
        final String? originalTitle = await EpubIsolateWorker.readBookTitle(
          inputPath,
          expectedSourceFingerprint: sourceIdentityForChapters(
            chapters,
          )?.sha256,
        );
        if (originalTitle != null) {
          try {
            translatedTitle = await _translateBookTitle(
              dio: dio,
              config: config,
              originalTitle: originalTitle,
              cancelToken: cancelToken,
            );
          } catch (error) {
            if (error is TranslationCancelledException ||
                _isCancelError(error)) {
              rethrow;
            }
            throwIfCancelled();
            titleTranslationFailed = true;
            // Log only the error category, never HTTP payloads, credentials or
            // request headers embedded in a transport exception.
            AppLogger.warn(
              'Book title translation failed (${error.runtimeType}); kept original title.',
              tag: 'translate',
            );
            emit(currentJob, s.runLogBookTitleTranslationFailed);
          }
        }
      }
      await _repacker.writeTranslatedEpub(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        config: config,
        chapters: updatedChapters,
        cancelToken: cancelToken,
        isCancelled: isCancelled,
        degradedBlockIds: _degradedBlocks,
        translatedTitle: translatedTitle,
        onProgress: (done, total) {
          if (done % 20 != 0 && done != total) return;
          emit(
            currentJob.copyWith(
              currentChapter: '${s.runProgressRepacking} ($done/$total)',
              currentBlock: null,
            ),
            s.runLogRepacking,
          );
        },
      );
      repackStopwatch.stop();

      final bool allBlocksDegraded =
          totalBlocks > 0 && degradedBlockCount >= totalBlocks;
      final bool hasWarnings = degradedBlockCount > 0 || titleTranslationFailed;
      final TranslationJobStatus terminalStatus = allBlocksDegraded
          ? TranslationJobStatus.failed
          : hasWarnings
          ? TranslationJobStatus.completedWithWarnings
          : TranslationJobStatus.completed;
      final TranslationJob terminalJob = currentJob.copyWith(
        status: terminalStatus,
        phase: TranslationJobPhase.translation,
        progress: 1,
        currentChapter: allBlocksDegraded
            ? s.runProgressTranslationFailed
            : hasWarnings
            ? s.runProgressEpubReadyWithWarnings
            : s.runProgressEpubReady,
        currentBlock: null,
        completedFiles: completedFiles,
        totalFiles: selectedChapters.length,
        completedBlocks: completedBlocks,
        totalBlocks: totalBlocks,
        apiDegradedBlocks: _apiDegradedBlocks,
        cachedBlocks: cachedBlocks,
        resumedBlocks: resumedBlocks,
        degradedBlockCount: degradedBlockCount,
        errorMessage: allBlocksDegraded ? s.runErrorAllBlocksDegraded : null,
      );
      translationStopwatch.stop();
      // The EPUB file is committed from here on. Capture the terminal result
      // now so a late error or cancellation below still reports the finished
      // output instead of an aborted translation.
      committedResult = TranslationRunResult(
        job: terminalJob,
        chapters: updatedChapters,
      );
      emit(
        terminalJob,
        allBlocksDegraded
            ? s.runLogRunFailedAllDegraded
            : hasWarnings
            ? s.runLogRunCompletedWithWarnings(outputFilePath)
            : s.runLogRunComplete(outputFilePath),
      );
      emit(
        terminalJob,
        s.runLogRepackPerformance(_formatDuration(repackStopwatch.elapsed)),
      );
      // Degraded blocks kept their source text (they were billed but not
      // translated), so they must not be counted as "translated" blocks in
      // the performance report.
      final int genuinelyTranslatedBlocks =
          (apiTranslatedBlocks - _apiDegradedBlocks).clamp(
            0,
            apiTranslatedBlocks,
          );
      emit(
        terminalJob,
        s.runLogFinalPerformance(
          _formatDuration(translationStopwatch.elapsed),
          genuinelyTranslatedBlocks,
          _formatBlocksPerMinute(
            genuinelyTranslatedBlocks,
            translationStopwatch.elapsed,
          ),
          _formatDuration(totalApiElapsed),
          _formatDuration(totalMemoryElapsed),
          memoryRequestCount,
          _formatDuration(totalCacheWriteElapsed),
          cacheWriteCount,
          footnoteBatchCount,
          footnoteRequestCount,
        ),
      );
      try {
        await _cacheStore.saveJobState(
          _resumeStateFromJob(
            jobKey: jobKey,
            inputFingerprint: inputFingerprint,
            job: terminalJob,
            status: terminalStatus.name,
          ),
        );
      } catch (error) {
        // The EPUB is already committed; checkpoint metadata is best effort.
        emit(
          terminalJob,
          s.runLogFinalCheckpointFailed('${error.runtimeType}', outputFilePath),
        );
      }
      return committedResult;
    } catch (error) {
      final TranslationRunResult? done = committedResult;
      if (done != null) {
        // The translated EPUB is already committed to disk. A late error
        // (progress callback, checkpoint save) or a cancellation that
        // arrived after the commit must not reframe the finished output as
        // an aborted translation.
        AppLogger.warn(
          'Ignoring late ${error.runtimeType} after the translated EPUB was '
          'committed; reporting the completed run.',
          tag: 'translate',
        );
        return done;
      }
      if (error is TranslationCancelledException) {
        rethrow;
      }
      if (_isCancelError(error)) {
        throw const TranslationCancelledException();
      }
      rethrow;
    } finally {
      await sourceSpool.dispose();
      if (dioReady) {
        dio.close(force: true);
      }
    }
  }

  Future<TranslationRunResult> _repackZeroBlockSelection({
    required String jobId,
    required String inputPath,
    required String outputFilePath,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    required int selectedChapterCount,
    required CancelToken cancelToken,
    required TranslationStyleProfile? confirmedStyleProfile,
    required TranslationProgressCallback? onProgress,
    required TranslationCancellationCheck? isCancelled,
  }) async {
    void throwIfCancelled() {
      if (cancelToken.isCancelled || (isCancelled?.call() ?? false)) {
        throw const TranslationCancelledException();
      }
    }

    final TranslationJob repackingJob = TranslationJob(
      id: jobId,
      inputPath: inputPath,
      outputPath: outputFilePath,
      status: TranslationJobStatus.running,
      phase: TranslationJobPhase.translation,
      progress: 0.98,
      currentChapter: 'Repacking EPUB',
      completedFiles: 0,
      totalFiles: selectedChapterCount,
      completedBlocks: 0,
      totalBlocks: 0,
      styleProfile: confirmedStyleProfile ?? TranslationStyleProfile.empty,
      styleProfileConfirmed:
          !config.styleProfileEnabled || confirmedStyleProfile != null,
      styleProfileEnabled: config.styleProfileEnabled,
    );
    const String repackingLog =
        'No translatable text blocks were selected. Repacking the EPUB without API requests.';
    // A UI-side progress listener must never abort the repack: swallow
    // callback errors the same way the main path's emit() does.
    try {
      onProgress?.call(repackingJob, repackingLog);
    } catch (error) {
      AppLogger.warn(
        'Progress callback failed (${error.runtimeType}); continuing.',
        tag: 'translate',
      );
    }
    AppLogger.debug(repackingLog, tag: 'translate');
    throwIfCancelled();
    await _repacker.writeTranslatedEpub(
      inputPath: inputPath,
      outputFilePath: outputFilePath,
      config: config,
      chapters: chapters,
      cancelToken: cancelToken,
      isCancelled: isCancelled,
      onProgress: (done, total) {
        if (done % 20 != 0 && done != total) return;
        try {
          onProgress?.call(
            repackingJob.copyWith(
              currentChapter: 'Repacking EPUB ($done/$total)',
            ),
            repackingLog,
          );
        } catch (error) {
          AppLogger.warn(
            'Progress callback failed (${error.runtimeType}); continuing.',
            tag: 'translate',
          );
        }
      },
    );

    final TranslationJob completedJob = repackingJob.copyWith(
      status: TranslationJobStatus.completed,
      progress: 1,
      currentChapter: 'EPUB ready',
      completedFiles: selectedChapterCount,
    );
    final String completedLog =
        'Translation complete. Wrote EPUB with no translatable text blocks to $outputFilePath';
    try {
      onProgress?.call(completedJob, completedLog);
    } catch (error) {
      AppLogger.warn(
        'Progress callback failed (${error.runtimeType}); continuing.',
        tag: 'translate',
      );
    }
    AppLogger.debug(completedLog, tag: 'translate');
    return TranslationRunResult(job: completedJob, chapters: chapters);
  }

  /// Drops the per-block source HTML/text of a finished chapter to release
  /// memory. The chapter's translations are already in the block cache and
  /// staged for repack; repack only needs [InspectedChapter.originalHtml]
  /// plus each block's translated HTML (see `renderTranslatedChapter`), and
  /// nothing later in the run reads source strings again (cache restoration
  /// ran upfront; pending-block checks only read block ids).
  static InspectedChapter _releaseChapterSourceStrings(
    InspectedChapter chapter,
  ) {
    return chapter.copyWith(
      blocks: <ExtractedBlock>[
        for (final ExtractedBlock block in chapter.blocks)
          block.copyWith(sourceHtml: '', sourceText: ''),
      ],
    );
  }

  static String _lockAndValidateTranslatedBlock({
    required TranslationConfig config,
    required ExtractedBlock block,
    required String translatedHtml,
    Map<String, int>? instrumentation,
    bool rejectEmptyResponse = false,
    void Function(String html)? onLocked,
  }) {
    final replyDom = _cleanResponseDom(
      translatedHtml,
      sourceText: block.sourceText,
      instrumentation: instrumentation,
      rejectEmptyResponse: rejectEmptyResponse,
    );
    return _lockAndValidateTranslatedBlockDom(
      config: config,
      block: block,
      replyDom: replyDom,
      instrumentation: instrumentation,
      onLocked: onLocked,
    );
  }

  /// Single-parse entry: [replyDom] is the already-parsed model reply (see
  /// _cleanResponseDom), so the reply is never parsed twice for one block.
  static String _lockAndValidateTranslatedBlockDom({
    required TranslationConfig config,
    required ExtractedBlock block,
    required _ResponseHtml replyDom,
    Map<String, int>? instrumentation,
    void Function(String html)? onLocked,
  }) {
    final sourceDom = _ResponseHtml.parse(block.sourceHtml, instrumentation);
    final locked = _lockResponseDom(sourceDom, replyDom);
    final html = locked.html;
    // Single-block quality retries/degrades must retain the usable locked
    // response even when validation below rejects residual source text.
    onLocked?.call(html);
    _validateTranslatedBlockQuality(
      config: config,
      block: block,
      sourceDom: sourceDom,
      translatedDom: locked,
    );
    return html;
  }

  static String _lockHtmlStructure({
    required String sourceHtml,
    required String translatedHtml,
    Map<String, int>? instrumentation,
  }) {
    final sourceDom = _ResponseHtml.parse(sourceHtml, instrumentation);
    final replyDom = _cleanResponseDom(
      translatedHtml,
      sourceText: sourceDom.plainText,
      instrumentation: instrumentation,
    );
    return _lockResponseDom(sourceDom, replyDom).html;
  }

  static _ResponseHtml _lockResponseDom(
    _ResponseHtml sourceDom,
    _ResponseHtml replyDom,
  ) {
    _validateNonemptyDoms(sourceDom, replyDom);
    // Anchor normalization and protected restoration mutate the working reply.
    // Keep the model's original DOM for language alignment, without reparsing.
    final modelDom = _ResponseHtml(
      replyDom.fragment.clone(true),
      replyDom.instrumentation,
    );
    final locked = _lockHtmlStructureCore(
      sourceDom: sourceDom,
      translatedDom: replyDom,
    );
    final source = sourceDom.root;
    final model = modelDom.root;
    final result = locked.root;
    if (source == null || model == null || result == null) return locked;
    late final textAlignment = _ResponseTextAlignment(
      modelDom.facts,
      locked.facts,
    );
    void preserve(dom.Element original, dom.Element reply, dom.Element output) {
      if (original.localName != reply.localName ||
          original.localName != output.localName ||
          EpubHtmlExtractor.nonTextAncestors.contains(original.localName)) {
        return;
      }
      // Only carry language metadata on an unambiguously aligned subtree.
      // Source IDs, links and all other attributes remain source-owned.
      if (!original.attributes.containsKey('lang') &&
          !original.attributes.containsKey('xml:lang') &&
          (reply.attributes.containsKey('lang') ||
              reply.attributes.containsKey('xml:lang')) &&
          textAlignment.matches(reply, output)) {
        final language =
            reply.attributes['lang'] ?? reply.attributes['xml:lang'];
        final xmlLanguage = reply.attributes['xml:lang'];
        if (language != null &&
            RegExp(
              r'^[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*$',
            ).hasMatch(language) &&
            (xmlLanguage == null || xmlLanguage == language)) {
          output.attributes['lang'] = language;
          output.attributes['xml:lang'] = language;
        }
      }
      if (original.children.length != reply.children.length ||
          original.children.length != output.children.length) {
        return;
      }
      for (var i = 0; i < original.children.length; i++) {
        preserve(original.children[i], reply.children[i], output.children[i]);
      }
    }

    preserve(source, model, result);
    return locked;
  }

  /// Apply the strategy's wrapper rules using the same DOM that structure
  /// handling will consume. Its string cleaner parses both markup and plain
  /// text separately, so calling it here would hide two additional parses.
  static _ResponseHtml _cleanResponseDom(
    String response, {
    required String sourceText,
    Map<String, int>? instrumentation,
    bool rejectEmptyResponse = false,
  }) {
    String value = response.trim();
    final fence = RegExp(
      r'^```(?:html|xhtml)?\s*\n([\s\S]*?)\n```$',
      caseSensitive: false,
    ).firstMatch(value);
    if (fence != null) value = fence.group(1)!.trim();
    if (rejectEmptyResponse && value.isEmpty) {
      throw const FormatException(
        'The translation API returned an empty block.',
      );
    }
    _responseCount(instrumentation, 'replyParses');
    final reply = _ResponseHtml.parse(value, instrumentation);
    final hasMarkup = reply.fragment.nodes.any((node) => node is dom.Element);
    final hasOutsideText = reply.fragment.nodes.any(
      (node) => node is dom.Text && node.data.trim().isNotEmpty,
    );
    if (value.contains('```') ||
        _EpubTranslationStrategy._hasTranslationExplanationPrefix(value) ||
        (hasMarkup && hasOutsideText) ||
        _EpubTranslationStrategy._hasTranslationExplanationPrefix(
          reply.plainText,
        ) ||
        _EpubTranslationStrategy._hasMarkdownWrapper(value) ||
        _EpubTranslationStrategy._hasUnexpectedJsonWrapper(
          sourceText: sourceText,
          translatedText: value,
        )) {
      throw const TranslationParseException(
        'HTML translation contains wrapper content.',
      );
    }
    return reply;
  }

  static _ResponseHtml _lockHtmlStructureCore({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    final _NormalizedAnchorHtml normalizedTranslation =
        _normalizeProtectedAnchorMarkers(
          sourceDom: sourceDom,
          translatedDom: translatedDom,
        );
    if (normalizedTranslation.hasOverflow &&
        normalizedTranslation.root != null &&
        _elementSkeletonMatches(sourceDom.root!, normalizedTranslation.root!) &&
        _overflowTextFitsSourceSlots(
          sourceDom: sourceDom,
          translatedDom: translatedDom,
          trustedOverflowTexts: normalizedTranslation.trustedOverflowTexts,
        )) {
      translatedDom.invalidate();
      return translatedDom;
    }
    if (_domStructureMatches(sourceDom, translatedDom)) {
      final _ResponseHtml? restored = _restoreProtectedTexts(
        sourceDom: sourceDom,
        translatedDom: translatedDom,
      );
      if (restored != null) {
        return restored;
      }
    }
    // Models sometimes fold small-caps authored spans (e.g.
    // <span class="smallcaps">EES</span>) into plain text
    // ("REES DAVIES"). That changes the element skeleton, so the normal
    // structure-matching path above fails and the rebuild path misplaces
    // text. Flatten those spans on the source side; if the flattened source
    // skeleton now matches the translation, restore text into it and return.
    if (sourceDom.html.contains('smallcaps')) {
      final _ResponseHtml? flattenedRestored = _restoreWithFlattenedSmallcaps(
        sourceDom: sourceDom,
        translatedDom: translatedDom,
      );
      if (flattenedRestored != null) {
        return flattenedRestored;
      }
    }
    final dom.Element? sourceRoot = sourceDom.root;
    if (sourceRoot == null) {
      return translatedDom;
    }
    final dom.Element rebuiltRoot = sourceRoot.clone(true);
    final rebuilt = _ResponseHtml.fromRoot(
      rebuiltRoot,
      sourceDom.instrumentation,
    );
    final List<_HtmlTextSlot> sourceSlots = rebuilt.slots;
    if (sourceSlots.isEmpty) {
      return rebuilt;
    }

    final List<_HtmlTextSlot> translatedSlots = translatedDom.slots;
    // P2-#7: effective protection is positional, not tag-based. A response
    // protected slot keeps its protected status only when the source has a
    // protected slot with the same (protecting tag, ordinal within that
    // tag); a protected-kind element the model introduced (an extra <code>,
    // a moved marker, ...) holds real translation text and must not be
    // dropped as protected content. 性能-#42: decided once per slot in a
    // single pass and cached — the old code walked up the ancestor chain
    // once per filter pass.
    final Map<String, int> sourceProtectedCounts =
        _protectedSlotCountsByTag(rebuilt, sourceSlots);
    final Map<dom.Text, bool> effectiveProtectedByNode =
        Map<dom.Text, bool>.identity();
    final Map<dom.Element, bool> effectiveProtectedByElement =
        Map<dom.Element, bool>.identity();
    final Map<dom.Text, int> writableIndexByNode =
        Map<dom.Text, int>.identity();
    final List<String> writableTranslatedTexts = <String>[];
    int protectedTranslatedCount = 0;
    final Map<String, int> seenProtectedByTag = <String, int>{};
    for (final _HtmlTextSlot slot in translatedSlots) {
      if (!slot.protected) {
        if (slot.text.isNotEmpty) {
          writableIndexByNode[slot.node] = writableTranslatedTexts.length;
          writableTranslatedTexts.add(slot.text);
        }
        continue;
      }
      final String tag = _nearestProtectingTag(translatedDom, slot.node) ?? '';
      final int ordinal = seenProtectedByTag[tag] ?? 0;
      seenProtectedByTag[tag] = ordinal + 1;
      final bool effective =
          tag == 'script' || tag == 'style' ||
          ordinal < (sourceProtectedCounts[tag] ?? 0);
      effectiveProtectedByNode[slot.node] = effective;
      dom.Node? ancestor = slot.node.parentNode;
      while (ancestor is dom.Element) {
        if (translatedDom.isProtected(ancestor)) {
          effectiveProtectedByElement[ancestor] = effective;
          break;
        }
        ancestor = ancestor.parentNode;
      }
      if (slot.text.isEmpty) {
        continue;
      }
      if (effective) {
        protectedTranslatedCount++;
      } else {
        writableIndexByNode[slot.node] = writableTranslatedTexts.length;
        writableTranslatedTexts.add(slot.text);
      }
    }
    // Whitespace-only protected-kind wrappers have no slots. Resolve them
    // using the same source-counterpart fallback before collecting gaps.
    for (final element in translatedDom.fragment.querySelectorAll('*')) {
      if (translatedDom.isProtected(element)) {
        effectiveProtectedByElement.putIfAbsent(
          element,
          () => element.localName == 'script' ||
              element.localName == 'style' ||
              (sourceProtectedCounts[element.localName] ?? 0) > 0,
        );
      }
    }
    // Positional mapping must pair unprotected slots with unprotected
    // slots: protected slots (footnote markers, page breaks, code) keep
    // their source text, so consuming translation texts across the
    // protected boundary would silently drop real translation text and
    // duplicate marker text whenever the model moves a marker to another
    // position. Fall back to the plain-text path when the protected counts
    // do not line up either.
    final List<_HtmlTextSlot> writableSourceSlots = sourceSlots
        .where((_HtmlTextSlot slot) => !slot.protected)
        .toList(growable: false);
    final int protectedSourceCount =
        sourceSlots.length - writableSourceSlots.length;

    if (writableTranslatedTexts.length == writableSourceSlots.length &&
        protectedTranslatedCount == protectedSourceCount) {
      // P2-#6: standalone whitespace-only text nodes never become slots, so
      // writing slot texts alone would drop them and glue words the model
      // separated with standalone whitespace. Fold each into the adjacent
      // slot text so the written text sequence keeps the response's word
      // separation.
      final Map<dom.Text, int> writableSourceIndexByNode =
          Map<dom.Text, int>.identity();
      for (int index = 0; index < writableSourceSlots.length; index += 1) {
        writableSourceIndexByNode[writableSourceSlots[index].node] = index;
      }
      final List<String> finalTexts = _withStandaloneWhitespace(
        translatedDom,
        writableTranslatedTexts,
        writableIndexByNode,
        rebuilt,
        writableSourceIndexByNode,
        effectiveProtectedByElement,
      );
      for (int index = 0; index < writableSourceSlots.length; index += 1) {
        writableSourceSlots[index].text = finalTexts[index];
      }
      rebuilt.invalidate();
      return rebuilt;
    }

    // P2-#13: rebuild the plain text from every non-protected text node,
    // including whitespace-only ones that never become slots, so words the
    // model separated with standalone whitespace do not glue together.
    // Protected source slots retain their text; including genuinely
    // protected response text here would duplicate it in the first writable
    // source slot.
    final String translatedPlainText = _unprotectedResponseText(
      translatedDom,
      effectiveProtectedByNode,
      effectiveProtectedByElement,
    );
    bool wroteMainText = false;
    final List<({_HtmlTextSlot slot, String sourceText})> emptiedSlots =
        <({_HtmlTextSlot slot, String sourceText})>[];
    for (final _HtmlTextSlot slot in sourceSlots) {
      if (slot.protected) {
        continue;
      }
      if (!wroteMainText) {
        slot.text = translatedPlainText;
        wroteMainText = true;
      } else {
        final String sourceText = slot.text;
        slot.text = '';
        emptiedSlots.add((slot: slot, sourceText: sourceText));
      }
    }
    _removeEmptiedInlineEmphasis(emptiedSlots);
    rebuilt.invalidate();
    return rebuilt;
  }

  /// If [sourceDom] contains `<span class="smallcaps">` nodes that the
  /// translation folded into a single plain text run, return a version of the
  /// source with those spans flattened so the skeletons match and the
  /// translation text can be restored positionally. Returns null when the
  /// flattened source still does not align with the translation.
  static _ResponseHtml? _restoreWithFlattenedSmallcaps({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    final dom.Element? sourceRoot = sourceDom.root;
    final dom.Element? translatedRoot = translatedDom.root;
    if (sourceRoot == null || translatedRoot == null) {
      return null;
    }
    // Flatten smallcaps spans in a clone of the source root.
    final dom.Element flattened = sourceRoot.clone(true);
    bool changed = false;
    bool retainedSemanticSpan = false;
    for (final dom.Element span
        in flattened.querySelectorAll('span').toList(growable: false)) {
      final String cls = span.className.toLowerCase();
      if (!cls.split(RegExp(r'\s+')).contains('smallcaps')) {
        continue;
      }
      if (_spanHasSemanticAttributes(span)) {
        span.classes.removeWhere(_isSmallCapsClass);
        changed = true;
        retainedSemanticSpan = true;
        continue;
      }
      final List<dom.Node> children = span.nodes.toList(growable: false);
      for (final dom.Node child in children) {
        span.parentNode?.insertBefore(child.clone(true), span);
      }
      span.remove();
      changed = true;
    }
    if (!changed) {
      return null;
    }
    // Unwrapping spans leaves adjacent Text nodes. The former serialize/parse
    // round-trip merged these; do that directly so positional matching retains
    // the same text-slot boundaries without another parse.
    _mergeAdjacentTextNodes(flattened);
    final flattenedDom = _ResponseHtml.fromRoot(
      flattened,
      sourceDom.instrumentation,
    );
    if (!_domStructureMatches(flattenedDom, translatedDom)) {
      if (!retainedSemanticSpan) return null;
      return _lockHtmlStructureCore(
        sourceDom: flattenedDom,
        translatedDom: translatedDom,
      );
    }
    final _ResponseHtml? restored = _restoreProtectedTexts(
      sourceDom: flattenedDom,
      translatedDom: translatedDom,
    );
    if (restored == null) {
      return null;
    }
    // The translation folded the small-caps spans into plain uppercase text.
    // Return the restored translation inside the flattened source skeleton.
    // (The authored small-caps spans are not re-introduced here; the content
    // and structure are correct, which is what downstream validation needs.)
    return restored;
  }

  static void _mergeAdjacentTextNodes(dom.Node parent) {
    dom.Text? previous;
    for (final node in parent.nodes.toList(growable: false)) {
      if (node is dom.Text) {
        if (previous == null) {
          previous = node;
        } else {
          previous.data += node.data;
          node.remove();
        }
      } else {
        previous = null;
        _mergeAdjacentTextNodes(node);
      }
    }
  }

  /// After rebuilding the source skeleton, inline emphasis wrappers whose
  /// source text is an audited foreign term and that were emptied (for example
  /// `<i class="calibre3">agri deserti,</i>` when the model folded the whole
  /// translation into the first text slot) are removed. Keeping them would
  /// make the residual checker treat the emptied node as an untranslated
  /// audited term and reject a perfectly valid translation. Ordinary empty
  /// emphasis wrappers are preserved so source skeletons stay stable.
  static void _removeEmptiedInlineEmphasis(
    List<({_HtmlTextSlot slot, String sourceText})> emptiedSlots,
  ) {
    final Set<dom.Element> candidates = <dom.Element>{};
    for (final ({_HtmlTextSlot slot, String sourceText}) entry
        in emptiedSlots) {
      if (!TranslationQuality.isAuditedForeignTermNodeText(
        entry.sourceText.trim(),
      )) {
        continue;
      }
      final dom.Node? parent = entry.slot.node.parentNode;
      if (parent is dom.Element &&
          (parent.localName == 'i' || parent.localName == 'em')) {
        candidates.add(parent);
      }
    }
    for (final dom.Element element in candidates) {
      if (element.children.isNotEmpty || element.text.trim().isNotEmpty) {
        continue;
      }
      element.remove();
    }
  }

  static bool _overflowTextFitsSourceSlots({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
    required List<dom.Text> trustedOverflowTexts,
  }) {
    final int sourceTextSlots = sourceDom.slots
        .where((_HtmlTextSlot slot) => !slot.protected)
        .length;
    final List<_HtmlTextSlot> untrustedTranslatedSlots = translatedDom.slots
        .where(
          (_HtmlTextSlot slot) =>
              !slot.protected && !trustedOverflowTexts.contains(slot.node),
        )
        .toList(growable: false);
    if (untrustedTranslatedSlots.length <= sourceTextSlots) {
      return true;
    }
    if (sourceTextSlots != 0) {
      return false;
    }
    for (final _HtmlTextSlot slot in untrustedTranslatedSlots) {
      slot.text = '';
    }
    return true;
  }

  static _ResponseHtml? _restoreProtectedTexts({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    final dom.Element? sourceRoot = sourceDom.root;
    final dom.Element? translatedRoot = translatedDom.root;
    if (sourceRoot == null || translatedRoot == null) {
      return translatedDom;
    }

    final List<_HtmlTextSlot> sourceSlots = sourceDom.slots;
    final List<_HtmlTextSlot> translatedSlots = translatedDom.slots;
    if (sourceSlots.length != translatedSlots.length) {
      return null;
    }

    for (int index = 0; index < sourceSlots.length; index += 1) {
      if (sourceSlots[index].protected) {
        translatedSlots[index].text = sourceSlots[index].text;
      }
    }
    translatedDom.invalidate();
    return translatedDom;
  }

  static bool _elementSkeletonMatches(
    dom.Element source,
    dom.Element translated, {
    Iterable<dom.Node> ignoredTranslatedNodes = const <dom.Node>[],
  }) {
    if (source.localName != translated.localName ||
        !_attributesMatch(source, translated)) {
      return false;
    }
    final List<dom.Element> sourceChildren = source.children.toList(
      growable: false,
    );
    final List<dom.Element> translatedChildren = translated.children.toList(
      growable: true,
    )..removeWhere(ignoredTranslatedNodes.contains);
    if (sourceChildren.length != translatedChildren.length) {
      return false;
    }
    for (int index = 0; index < sourceChildren.length; index += 1) {
      if (!_elementSkeletonMatches(
        sourceChildren[index],
        translatedChildren[index],
        ignoredTranslatedNodes: ignoredTranslatedNodes,
      )) {
        return false;
      }
    }
    return true;
  }

  static _NormalizedAnchorHtml _normalizeProtectedAnchorMarkers({
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    final dom.Element? sourceRoot = sourceDom.root;
    final dom.Element? translatedRoot = translatedDom.root;
    if (sourceRoot == null || translatedRoot == null) {
      return const _NormalizedAnchorHtml();
    }
    final List<String> overflowTexts = <String>[];
    final List<dom.Text> trustedOverflowTexts = <dom.Text>[];
    _normalizePairedProtectedAnchors(
      sourceRoot,
      translatedRoot,
      overflowTexts,
      trustedOverflowTexts,
      sourceDom,
    );
    translatedDom.invalidate();
    return _NormalizedAnchorHtml(
      root: translatedRoot,
      hasOverflow: overflowTexts.isNotEmpty,
      trustedOverflowTexts: trustedOverflowTexts,
    );
  }

  static void _normalizePairedProtectedAnchors(
    dom.Element source,
    dom.Element translated,
    List<String> overflowTexts,
    List<dom.Text> trustedOverflowTexts,
    _ResponseHtml sourceDom,
  ) {
    if (source.localName != translated.localName ||
        !_attributesMatch(source, translated)) {
      return;
    }

    if (!EpubHtmlExtractor.nonTextAncestors.contains(source.localName) &&
        sourceDom.isProtected(source) &&
        _isProtectedMarkerText(sourceDom.textOf(source))) {
      _normalizeProtectedAnchor(
        source: source,
        translated: translated,
        sourceMarker: sourceDom.textOf(source).trim(),
        overflowTexts: overflowTexts,
        trustedOverflowTexts: trustedOverflowTexts,
      );
      return;
    }

    final List<dom.Element> sourceChildren = source.children.toList(
      growable: false,
    );
    final List<dom.Element> translatedChildren = translated.children.toList(
      growable: false,
    );
    if (sourceChildren.length != translatedChildren.length) {
      return;
    }
    for (int index = 0; index < sourceChildren.length; index += 1) {
      _normalizePairedProtectedAnchors(
        sourceChildren[index],
        translatedChildren[index],
        overflowTexts,
        trustedOverflowTexts,
        sourceDom,
      );
    }
  }

  static void _normalizeProtectedAnchor({
    required dom.Element source,
    required dom.Element translated,
    required String sourceMarker,
    required List<String> overflowTexts,
    required List<dom.Text> trustedOverflowTexts,
  }) {
    final dom.Text? markerText = _firstNonWhitespaceTextDescendant(translated);
    if (markerText == null) {
      _removeAdjacentMarker(
        source: source,
        translated: translated,
        marker: sourceMarker,
      );
      return;
    }

    final List<int>? markerRange = _markerRangeAtTextStart(
      markerText.data,
      sourceMarker,
    );
    if (markerRange == null) {
      return;
    }
    final String overflowText = _overflowTextAfterMarker(
      anchor: translated,
      markerText: markerText,
      markerEnd: markerRange[1],
    );
    final dom.Node? parent = translated.parentNode;
    if (parent == null) {
      return;
    }
    final int anchorIndex = parent.nodes.indexOf(translated);
    if (anchorIndex < 0) {
      return;
    }
    final dom.Element restoredAnchor = source.clone(true);
    parent.nodes.removeAt(anchorIndex);
    parent.nodes.insert(anchorIndex, restoredAnchor);
    if (overflowText.isNotEmpty) {
      final dom.Text? insertedOverflow = _placeOverflowTextAfter(
        parent: parent,
        anchorIndex: anchorIndex,
        overflowText: overflowText,
      );
      overflowTexts.add(overflowText);
      if (insertedOverflow != null) {
        trustedOverflowTexts.add(insertedOverflow);
      }
    }
  }

  static String _overflowTextAfterMarker({
    required dom.Element anchor,
    required dom.Text markerText,
    required int markerEnd,
  }) {
    String overflow = markerText.data.substring(markerEnd).trimLeft();

    dom.Node branch = markerText;
    while (true) {
      final dom.Node? parent = branch.parentNode;
      if (parent == null) {
        return overflow;
      }
      final int index = parent.nodes.indexOf(branch);
      for (
        int siblingIndex = index + 1;
        siblingIndex < parent.nodes.length;
        siblingIndex += 1
      ) {
        overflow += _safeOverflowText(parent.nodes[siblingIndex]);
      }
      if (parent == anchor) {
        return overflow;
      }
      branch = parent;
    }
  }

  static String _safeOverflowText(dom.Node node) {
    if (node is dom.Text) {
      return node.data;
    }
    if (node is! dom.Element) {
      return '';
    }
    const Set<String> unsafeTags = <String>{
      'script',
      'style',
      'iframe',
      'object',
      'embed',
      'img',
    };
    if (unsafeTags.contains(node.localName)) {
      return '';
    }
    return node.nodes.map(_safeOverflowText).join();
  }

  static dom.Text? _placeOverflowTextAfter({
    required dom.Node parent,
    required int anchorIndex,
    required String overflowText,
  }) {
    final int nextIndex = anchorIndex + 1;
    if (nextIndex < parent.nodes.length &&
        parent.nodes[nextIndex] is dom.Text) {
      final dom.Text nextText = parent.nodes[nextIndex] as dom.Text;
      nextText.data = _joinOverflowText(overflowText, nextText.data);
      return null;
    }
    final dom.Text inserted = dom.Text(overflowText);
    parent.nodes.insert(nextIndex, inserted);
    return inserted;
  }

  static String _joinOverflowText(String overflow, String followingText) {
    if (overflow.isEmpty || followingText.isEmpty) {
      return '$overflow$followingText';
    }
    final bool needsSeparator =
        RegExp(r'[A-Za-z0-9]$').hasMatch(overflow) &&
        RegExp(r'^[A-Za-z0-9]').hasMatch(followingText);
    return needsSeparator
        ? '$overflow $followingText'
        : '$overflow$followingText';
  }

  static dom.Text? _firstNonWhitespaceTextDescendant(dom.Node node) {
    if (node is dom.Text) {
      return node.data.trim().isEmpty ? null : node;
    }
    for (final dom.Node child in node.nodes) {
      final dom.Text? text = _firstNonWhitespaceTextDescendant(child);
      if (text != null) {
        return text;
      }
    }
    return null;
  }

  static void _removeAdjacentMarker({
    required dom.Element source,
    required dom.Element translated,
    required String marker,
  }) {
    final dom.Text? translatedPrevious = _adjacentText(
      translated,
      before: true,
    );
    final dom.Text? sourcePrevious = _adjacentText(source, before: true);
    if (translatedPrevious != null &&
        !_textEndsWithMarker(sourcePrevious?.data ?? '', marker) &&
        _textEndsWithMarker(translatedPrevious.data, marker) &&
        _removeMarkerAtTextEnd(translatedPrevious, marker)) {
      return;
    }

    final dom.Text? translatedNext = _adjacentText(translated, before: false);
    final dom.Text? sourceNext = _adjacentText(source, before: false);
    if (translatedNext != null &&
        !_textStartsWithMarker(sourceNext?.data ?? '', marker) &&
        _textStartsWithMarker(translatedNext.data, marker)) {
      _removeMarkerAtTextStart(translatedNext, marker);
    }
  }

  static dom.Text? _adjacentText(dom.Element element, {required bool before}) {
    final dom.Node? parent = element.parentNode;
    if (parent == null) {
      return null;
    }
    final int index = parent.nodes.indexOf(element);
    final int adjacentIndex = before ? index - 1 : index + 1;
    if (index < 0 ||
        adjacentIndex < 0 ||
        adjacentIndex >= parent.nodes.length) {
      return null;
    }
    final dom.Node adjacent = parent.nodes[adjacentIndex];
    return adjacent is dom.Text ? adjacent : null;
  }

  static bool _textEndsWithMarker(String value, String marker) {
    int end = value.length;
    while (end > 0 && value[end - 1].trim().isEmpty) {
      end -= 1;
    }
    final int start = end - marker.length;
    return start >= 0 && value.substring(start, end) == marker;
  }

  static bool _textStartsWithMarker(String value, String marker) {
    int start = 0;
    while (start < value.length && value[start].trim().isEmpty) {
      start += 1;
    }
    final int end = start + marker.length;
    return end <= value.length && value.substring(start, end) == marker;
  }

  static bool _removeMarkerAtTextEnd(dom.Text textNode, String marker) {
    final String value = textNode.data;
    int end = value.length;
    while (end > 0 && value[end - 1].trim().isEmpty) {
      end -= 1;
    }
    final int start = end - marker.length;
    if (start >= 0 && value.substring(start, end) == marker) {
      textNode.data = value.substring(0, start) + value.substring(end);
      return true;
    }
    return false;
  }

  static bool _removeMarkerAtTextStart(dom.Text textNode, String marker) {
    final String value = textNode.data;
    int start = 0;
    while (start < value.length && value[start].trim().isEmpty) {
      start += 1;
    }
    final int end = start + marker.length;
    if (end <= value.length && value.substring(start, end) == marker) {
      textNode.data = value.substring(0, start) + value.substring(end);
      return true;
    }
    return false;
  }

  static List<int>? _markerRangeAtTextStart(String value, String marker) {
    int start = 0;
    while (start < value.length && value[start].trim().isEmpty) {
      start += 1;
    }
    final int end = start + marker.length;
    if (end <= value.length && value.substring(start, end) == marker) {
      return <int>[start, end];
    }
    return null;
  }

  static bool _htmlStructureMatches(String sourceHtml, String translatedHtml) {
    return _domStructureMatches(
      _ResponseHtml.parse(sourceHtml),
      _ResponseHtml.parse(translatedHtml),
    );
  }

  static bool _domStructureMatches(
    _ResponseHtml sourceDom,
    _ResponseHtml translatedDom,
  ) {
    final dom.Element? sourceRoot = sourceDom.root;
    final dom.Element? translatedRoot = translatedDom.root;
    if (sourceRoot == null || translatedRoot == null) {
      return false;
    }
    return _elementStructureMatches(sourceRoot, translatedRoot);
  }

  static dom.Element? _fragmentRoot(dom.DocumentFragment fragment) {
    final List<dom.Node> nodes = fragment.nodes
        .where((dom.Node node) => !_isIgnorableStructureNode(node))
        .toList(growable: false);
    if (nodes.length != 1 || nodes.single is! dom.Element) {
      return null;
    }
    return nodes.single as dom.Element;
  }

  static bool _elementStructureMatches(
    dom.Element source,
    dom.Element translated,
  ) {
    if (source.localName != translated.localName) {
      return false;
    }
    if (!_attributesMatch(source, translated)) {
      return false;
    }

    final List<dom.Node> sourceNodes = _meaningfulStructureNodes(source);
    final List<dom.Node> translatedNodes = _meaningfulStructureNodes(
      translated,
    );
    if (sourceNodes.length != translatedNodes.length) {
      return false;
    }
    for (int index = 0; index < sourceNodes.length; index += 1) {
      final dom.Node sourceNode = sourceNodes[index];
      final dom.Node translatedNode = translatedNodes[index];
      if (sourceNode is dom.Text && translatedNode is dom.Text) {
        continue;
      }
      if (sourceNode is dom.Element && translatedNode is dom.Element) {
        if (!_elementStructureMatches(sourceNode, translatedNode)) {
          return false;
        }
        continue;
      }
      return false;
    }
    return true;
  }

  static bool _attributesMatch(dom.Element source, dom.Element translated) {
    if (source.attributes.length != translated.attributes.length) {
      return false;
    }
    for (final MapEntry<Object, String> entry in source.attributes.entries) {
      if (translated.attributes[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  static List<dom.Node> _meaningfulStructureNodes(dom.Element element) {
    return element.nodes
        .where((dom.Node node) => !_isIgnorableStructureNode(node))
        .toList(growable: false);
  }

  static bool _isIgnorableStructureNode(dom.Node node) {
    return node is dom.Text && node.data.trim().isEmpty;
  }

  static void _collectTextSlots(
    dom.Node node,
    List<_HtmlTextSlot> slots, {
    required bool protected,
    required _ResponseNodeFacts facts,
  }) {
    if (node is dom.Text) {
      if (node.data.trim().isNotEmpty) {
        slots.add(_HtmlTextSlot(node: node, protected: protected));
      }
      return;
    }
    if (node is! dom.Element) {
      return;
    }
    final bool childProtected = protected || facts.isProtected(node);
    for (final dom.Node child in node.nodes) {
      _collectTextSlots(child, slots, protected: childProtected, facts: facts);
    }
  }

  /// P2-#7: per-tag counts of protected source slots. A response protected
  /// slot is effectively protected only when the source has a protected
  /// slot with the same (protecting tag, ordinal within that tag): the
  /// identity of protected content is positional, not a tag-name set.
  static Map<String, int> _protectedSlotCountsByTag(
    _ResponseHtml dom,
    List<_HtmlTextSlot> slots,
  ) {
    final Map<String, int> counts = <String, int>{};
    for (final _HtmlTextSlot slot in slots) {
      if (!slot.protected) {
        continue;
      }
      final String tag = _nearestProtectingTag(dom, slot.node) ?? '';
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
    return counts;
  }

  /// Tag of the nearest ancestor that protects [slotNode]'s text, or null
  /// when none does. Callers only ask for protected slots, which always
  /// have a protecting ancestor by construction.
  static String? _nearestProtectingTag(
    _ResponseHtml document,
    dom.Text slotNode,
  ) {
    dom.Node? ancestor = slotNode.parentNode;
    while (ancestor is dom.Element) {
      if (document.isProtected(ancestor)) {
        return ancestor.localName;
      }
      ancestor = ancestor.parentNode;
    }
    return null;
  }

  /// Walks [document] in document order and reports each standalone
  /// whitespace-only text node (which never becomes a slot) via [onGap],
  /// keyed by the index of the preceding writable slot ([writableIndexByNode]
  /// maps each writable slot's text node to its index; -1 when the
  /// whitespace leads). Whitespace inside protected subtrees is skipped,
  /// mirroring the slot walk.
  static void _collectStandaloneWhitespaceGaps(
    _ResponseHtml document,
    Map<dom.Text, int> writableIndexByNode,
    void Function(int precedingSlot, String data) onGap, [
    Map<dom.Element, bool>? effectiveProtection,
  ]) {
    int lastWritable = -1;
    void visit(dom.Node node, bool protected) {
      if (node is dom.Text) {
        if (node.data.trim().isEmpty) {
          if (!protected) {
            onGap(lastWritable, node.data);
          }
          return;
        }
        final int? writableIndex = writableIndexByNode[node];
        if (writableIndex != null) {
          lastWritable = writableIndex;
        }
        return;
      }
      if (node is! dom.Element) {
        return;
      }
      if (node.localName == 'script' || node.localName == 'style') return;
      final bool childProtected =
          protected ||
          (effectiveProtection?[node] ?? document.isProtected(node));
      for (final dom.Node child in node.nodes) {
        visit(child, childProtected);
      }
    }
    for (final dom.Node node in document.fragment.nodes) {
      visit(node, false);
    }
  }

  /// P2-#6: folds standalone whitespace-only text nodes (which never become
  /// slots) into the adjacent writable slot texts, in document order. Each
  /// whitespace node is appended to the preceding writable slot's text (or
  /// prepended to the first slot's text when it leads), so the written text
  /// sequence keeps the response's word separation instead of gluing words.
  /// [writableIndexByNode] maps each writable slot's text node to its index
  /// in [writableTexts].
  ///
  /// P2-#6 regression: [sourceDom] is the rebuilt (source-clone) DOM whose
  /// own standalone whitespace nodes survive the write (they never become
  /// slots), and [writableSourceIndexByNode] maps its writable slots to
  /// their indices. The writable slot sequences are positionally aligned
  /// (the branch precondition), so a response gap is skipped when the
  /// source already has whitespace at the same gap position — folding it
  /// as well would double the whitespace in the output.
  static List<String> _withStandaloneWhitespace(
    _ResponseHtml translatedDom,
    List<String> writableTexts,
    Map<dom.Text, int> writableIndexByNode,
    _ResponseHtml sourceDom,
    Map<dom.Text, int> writableSourceIndexByNode,
    Map<dom.Element, bool> effectiveProtection,
  ) {
    final List<({int precedingSlot, String data})> gaps =
        <({int precedingSlot, String data})>[];
    _collectStandaloneWhitespaceGaps(
      translatedDom,
      writableIndexByNode,
      (int precedingSlot, String data) =>
          gaps.add((precedingSlot: precedingSlot, data: data)),
      effectiveProtection,
    );
    if (gaps.isEmpty) {
      return writableTexts;
    }
    final Set<int> sourceWhitespaceSlots = <int>{};
    _collectStandaloneWhitespaceGaps(
      sourceDom,
      writableSourceIndexByNode,
      (int precedingSlot, String _) =>
          sourceWhitespaceSlots.add(precedingSlot),
    );
    final List<String> result = List<String>.from(writableTexts);
    for (final gap in gaps) {
      if (result.isEmpty) {
        break;
      }
      if (sourceWhitespaceSlots.contains(gap.precedingSlot)) {
        continue;
      }
      if (gap.precedingSlot >= 0 && gap.precedingSlot < result.length) {
        result[gap.precedingSlot] = result[gap.precedingSlot] + gap.data;
      } else {
        result[0] = gap.data + result[0];
      }
    }
    return result;
  }

  /// Plain text of the translated DOM for the merge fallback: the data of
  /// every text node except effectively-protected ones, including
  /// whitespace-only nodes that never become slots, so words the model
  /// separated with standalone whitespace do not glue together (P2-#13).
  /// P2-#7: [effectiveProtectedByNode] carries the per-slot identity
  /// decision — a protected-kind element the model introduced has no
  /// source counterpart, so its text is real translation content and is
  /// kept; only genuinely-protected text is excluded (protected source
  /// slots retain their text, and including it here would duplicate it in
  /// the first writable source slot).
  static String _unprotectedResponseText(
    _ResponseHtml translatedDom,
    Map<dom.Text, bool> effectiveProtectedByNode,
    Map<dom.Element, bool> effectiveProtection,
  ) {
    final StringBuffer buffer = StringBuffer();
    void visit(dom.Node node, bool protected) {
      if (node is dom.Text) {
        if (!(effectiveProtectedByNode[node] ?? protected)) {
          buffer.write(node.data);
        }
        return;
      }
      if (node is! dom.Element) {
        return;
      }
      if (node.localName == 'script' || node.localName == 'style') return;
      final bool childProtected =
          protected ||
          (effectiveProtection[node] ?? translatedDom.isProtected(node));
      for (final dom.Node child in node.nodes) {
        visit(child, childProtected);
      }
    }
    for (final dom.Node node in translatedDom.fragment.nodes) {
      visit(node, false);
    }
    return buffer.toString();
  }

  static bool _isProtectedTextElement(dom.Element element, {String? text}) {
    final String tag = element.localName ?? '';
    if (EpubHtmlExtractor.nonTextAncestors.contains(tag)) return true;
    final Set<String> roles = _roleTokens(element);
    final Set<String> epubTypes = _epubTypes(element);
    // Ordinary wrappers cannot protect text; do not read their descendants.
    if (tag != 'a' &&
        !roles.contains('doc-noteref') &&
        !epubTypes.contains('noteref') &&
        !roles.contains('doc-pagebreak') &&
        !epubTypes.contains('pagebreak')) {
      return false;
    }
    final String value = text ?? element.text;
    final bool protectedMarkerText = _isProtectedMarkerText(value);

    if ((roles.contains('doc-noteref') || epubTypes.contains('noteref')) &&
        protectedMarkerText) {
      return true;
    }
    if (roles.contains('doc-pagebreak') || epubTypes.contains('pagebreak')) {
      return _isProtectedPagebreakText(value);
    }
    final String href = element.attributes['href'] ?? '';
    if (tag != 'a') {
      return false;
    }
    final String id = element.attributes['id']?.toLowerCase() ?? '';
    if (protectedMarkerText &&
        (roles.contains('doc-backlink') || id.startsWith('footnote_ref_'))) {
      return true;
    }
    if (protectedMarkerText &&
        _isCrossFileHref(href) &&
        _containsFootnoteMarkerClass(element)) {
      return true;
    }
    return href.startsWith('#') && protectedMarkerText;
  }

  static bool _isCrossFileHref(String href) {
    final int fragmentIndex = href.indexOf('#');
    return fragmentIndex > 0 && fragmentIndex < href.length - 1;
  }

  static bool _containsFootnoteMarkerClass(dom.Element element) {
    return ProtectedAnchorTextSlots.hasFootnoteMarkerClass(element);
  }

  static Set<String> _epubTypes(dom.Element element) {
    return EpubSemantics.typesOf(element);
  }

  static Set<String> _roleTokens(dom.Element element) {
    return (element.attributes['role']?.toLowerCase() ?? '')
        .split(RegExp(r'\s+'))
        .where((String role) => role.isNotEmpty)
        .toSet();
  }

  static bool _isProtectedPagebreakText(String value) {
    final String compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty || compact.length > 12) {
      return false;
    }
    return _isProtectedMarkerText(value) ||
        RegExp(r'^[0-9]+$').hasMatch(compact) ||
        RegExp(r'^[ivxlcdmIVXLCDM]+$').hasMatch(compact);
  }

  static bool _isProtectedMarkerText(String value) {
    final String compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty || compact.length > 10) {
      return false;
    }
    if (compact == '＊' || _chineseNumberMarkerToAscii.containsKey(compact)) {
      return true;
    }
    return RegExp(r'^[\[\(（【].+[\]\)）】]$').hasMatch(compact) ||
        RegExp(r'^[0-9]+[.)]?$').hasMatch(compact) ||
        RegExp(r'^[*†‡§¶]+$').hasMatch(compact) ||
        compact == '↩';
  }

  static const Map<String, String> _chineseNumberMarkerToAscii =
      <String, String>{
        '零': '0',
        '一': '1',
        '二': '2',
        '三': '3',
        '四': '4',
        '五': '5',
        '六': '6',
        '七': '7',
        '八': '8',
        '九': '9',
        '十': '10',
        '十一': '11',
      };

  /// Test-visible detector used by individual protected-slot translation.
  @visibleForTesting
  static bool slotTranslationHasWrapperTag(String text) =>
      _EpubTranslationStrategy._slotWrapperTagPattern.hasMatch(text);

  static String idiomaticTranslationInstructionForTest() {
    return EpubChapterTranslator()._strategy._idiomaticTranslationInstruction();
  }

  /// Whether [text] already appears to be in the target language's script.
  /// Used to skip translating book titles that need no translation.
  @visibleForTesting
  static bool titleAlreadyInTargetLanguage(String text, String targetLanguage) {
    final String normalized = normalizeTargetLanguage(targetLanguage);
    final letters = text.replaceAll(
      RegExp(r'[\s\d\p{P}\p{S}]', unicode: true),
      '',
    );
    if (normalized == 'ja') {
      return RegExp(r'[\u3040-\u30ff]').hasMatch(letters) &&
          RegExp(r'^[\u3040-\u30ff\u3400-\u9fff]+$').hasMatch(letters);
    }
    if (normalized == 'ko') {
      return RegExp(r'^[\uac00-\ud7a3]+$').hasMatch(letters);
    }
    // Han characters alone cannot distinguish Chinese variants or a Japanese
    // kanji-only title. Ask the translator rather than guessing, including
    // simplified/traditional conversion and mixed-script titles.
    return false;
  }

  static String cleanBookTitleForTest(
    String raw, {
    bool checkHtmlTags = true,
  }) => _cleanBookTitle(raw, checkHtmlTags: checkHtmlTags);

  /// P2-#21 / 性能-#37: per-slot context summary. [slotIndex]/[slotTexts]
  /// locate the slot's own occurrence when texts repeat; [normalizedBlockText]
  /// is the cached normalized block text.
  @visibleForTesting
  static String blockContextSummaryForTest(
    ExtractedBlock block, {
    String? slotText,
    int? slotIndex,
    List<String>? slotTexts,
    List<String>? normalizedSlotTexts,
    String? normalizedBlockText,
  }) =>
      _EpubTranslationStrategy._blockContextSummary(
        block,
        slotText: slotText,
        slotIndex: slotIndex,
        slotTexts: slotTexts,
        normalizedSlotTexts: normalizedSlotTexts,
        normalizedBlockText: normalizedBlockText,
      );

  /// P2-#17: extracts the single block text from a retry request payload,
  /// or null when the payload is not a recognized single-block fallback.
  @visibleForTesting
  static String? singleBlockTextForTest(Map<String, dynamic> data) =>
      _TranslationRequestBudget._singleBlockText(data);

  /// 性能-#40: bounded preview body for [blocks].
  @visibleForTesting
  String previewBodyFromBlocksForTest(
    List<ExtractedBlock> blocks, {
    required String fallback,
  }) =>
      _previewBodyFromBlocks(blocks, fallback: fallback);

  /// 性能-#40: plain text from [html], truncated to [maxChars] when given.
  @visibleForTesting
  String? plainTextFromHtmlForTest(String? html, {int? maxChars}) =>
      _plainTextFromHtml(html, maxChars: maxChars);

  static String _cleanBookTitle(String raw, {bool checkHtmlTags = true}) {
    String value = raw.trim();
    // Peel nested presentation wrappers without changing the title itself.
    while (true) {
      final String previous = value;
      final fence = RegExp(
        r'^```[^\r\n`]*\r?\n([\s\S]*?)\r?\n```$',
      ).firstMatch(value);
      if (fence != null) value = fence.group(1)!.trim();
      value = value
          .replaceFirst(
            RegExp(
              r'^(?:(?:好的|当然|可以|没问题)[，,。.!！\s]*)?(?:(?:以下|下面)是)?(?:译文|翻译(?:结果|内容)?)(?:如下)?\s*[:：]',
            ),
            '',
          )
          .replaceFirst(
            RegExp(
              r"^(?:(?:sure|certainly|of course|okay|ok)[,!.]?\s*)?(?:here(?:'s| is)\s+)?(?:the\s+)?(?:translation(?: result)?|translated (?:text|html(?: fragment)?))(?:\s+is)?\s*[:：]",
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      value = value
          .replaceFirst(RegExp(r'^(?:#{1,6}|>|[-+*]|\d+[.)])\s+'), '')
          .trim();
      for (final String marker in <String>['**', '__', '~~', '*', '_']) {
        if (value.length >= marker.length * 2 &&
            value.startsWith(marker) &&
            value.endsWith(marker)) {
          value = value
              .substring(marker.length, value.length - marker.length)
              .trim();
          break;
        }
      }
      for (final pair in <(String, String)>[
        ('"', '"'),
        ("'", "'"),
        ('「', '」'),
        ('『', '』'),
        ('“', '”'),
        ('‘', '’'),
        ('＂', '＂'),
        ('«', '»'),
      ]) {
        if (value.length >= 2 &&
            value.startsWith(pair.$1) &&
            value.endsWith(pair.$2)) {
          value = value.substring(1, value.length - 1).trim();
          break;
        }
      }
      if (value == previous) break;
    }
    if (value.isEmpty) {
      throw const FormatException('Empty translated book title');
    }
    // A paired presentation tag is still a wrapper, even when literal angle
    // brackets (such as a generic type parameter) are allowed in XML text.
    // P2-#15: the relaxed path must still reject HTML comments and markup
    // that does not span the whole title (for example "<b>中文书名</b>：副标题"
    // or an unclosed "<b>"); only a lone literal such as "<T>" stays allowed.
    if (!checkHtmlTags &&
        (RegExp(
              r'^<([A-Za-z][\w:-]*)\b[^>]*>[\s\S]*</\1\s*>$',
              caseSensitive: false,
            ).hasMatch(value) ||
            _EpubTranslationStrategy._slotHtmlCommentPattern.hasMatch(value) ||
            _hasNonLiteralTag(value))) {
      throw const TranslationParseException(
        'Translated book title contains an HTML wrapper.',
      );
    }
    _EpubTranslationStrategy._validateIndividualSlotTranslation(
      sourceText: value,
      translatedText: value,
      checkHtmlTags: checkHtmlTags,
    );
    return value;
  }

  /// P2-#15: whether [value] contains tag-shaped markup other than a lone
  /// single-letter literal like `<T>` (no attributes and no closing tag,
  /// plausibly a generic type parameter). P2-#8: the literal must not be a
  /// real HTML element — `<B>`/`<I>` (or their lowercase forms) are genuine
  /// HTML tags and stay rejected, unlike `<t>`. Catches unclosed tags
  /// (`<b>中文书名`) and embedded markup (`<b>中文书名</b>：副标题`) that the
  /// full-wrapper check misses. A `<` not abutting a letter (as in `a < b`)
  /// is plain text, not a tag.
  static bool _hasNonLiteralTag(String value) {
    final RegExp tagPattern = RegExp(r'<(/?)([A-Za-z][\w:-]*)(\s[^<>]*)?/?>');
    for (final RegExpMatch match in tagPattern.allMatches(value)) {
      final RegExpMatch? literal =
          RegExp(r'^<([A-Za-z])>$').firstMatch(match.group(0)!);
      if (literal != null &&
          !_singleLetterHtmlElements.contains(
            literal.group(1)!.toLowerCase(),
          )) {
        continue;
      }
      return true;
    }
    return false;
  }

  /// Single-letter HTML element names. A lone `<b>`/`<i>`/... is markup,
  /// never a literal, so the P2-#15 literal whitelist must not admit it
  /// (P2-#8).
  static const Set<String> _singleLetterHtmlElements = <String>{
    'a',
    'b',
    'i',
    'p',
    'q',
    's',
    'u',
  };

  /// Translates the book's metadata title with a single lightweight API call.
  /// Returns null when translation is unnecessary. Failures are handled by the
  /// caller as a non-fatal warning, keeping the original title in the repacker.
  Future<String?> _translateBookTitle({
    required Dio dio,
    required TranslationConfig config,
    required String originalTitle,
    CancelToken? cancelToken,
  }) async {
    if (titleAlreadyInTargetLanguage(originalTitle, config.targetLanguage)) {
      return null;
    }
    final Map<String, dynamic> requestData = <String, dynamic>{
      'model': config.model,
      'temperature': 0.2,
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content':
              'Translate the book title into ${config.targetLanguage}. Return only the translated title, with no explanation, quotes, or formatting.${_apiClient.lockedGlossaryInstruction(config)}',
        },
        <String, String>{'role': 'user', 'content': originalTitle},
      ],
    };
    final Response<dynamic> response = await _postChatCompletions(
      dio: dio,
      data: requestData,
      cancelToken: cancelToken,
    );
    final String translated = _cleanBookTitle(
      _apiClient.extractMessageContent(response.data),
      checkHtmlTags: false,
    );
    if (translated == originalTitle.trim()) {
      return null;
    }
    return translated;
  }

  String _linePreview(String value) {
    final String collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= 72) {
      return collapsed;
    }
    return '${collapsed.substring(0, 69)}...';
  }

  String _safeErrorText(Object error, TranslationConfig config) {
    return SensitiveText.redact(
      error.toString(),
      configuredApiKey: config.apiKey,
    );
  }

  static void _validateTranslatedBlockQuality({
    required TranslationConfig config,
    required ExtractedBlock block,
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) {
    _validateNonemptyDoms(sourceDom, translatedDom);
    if (!config.residualQualityCheck) {
      return;
    }
    // A bibliography / endnote / index entry conventionally keeps reference
    // fields (author, journal, volume/issue/year, publisher, page numbers,
    // index terms) in the original language. Detect such entries by their
    // source markup class (for example `endnotes1`, `indexmain`) or epub:type
    // (for example `index-term`, `index-locator`) rather than the block root
    // tag, because the extractor may split a `<li>` into its inner `<a>` /
    // `<i>` / `<span>` nodes while still exposing the surrounding class in
    // `sourceHtml`.
    final bool isBibliographicEntry = RegExp(
      r'class="[^"]*(?:endnote|bibliograph|reference|index)[^"]*"'
      r'|epub:type="[^"]*index[^"]*"',
      caseSensitive: false,
    ).hasMatch(block.sourceHtml);
    // A pure cross-reference / citation-metadata endnote (for example
    // `Ibid.` or `Fiorentini and Peltzman, op. cit., p. 15.`) has no
    // natural-language sentence to translate; keeping it verbatim is the
    // correct behaviour. Skip the residual check for these so they are not
    // mistaken for untranslated prose.
    if (isBibliographicEntry &&
        TranslationQuality.isPureCitationMetadata(block.sourceText)) {
      return;
    }
    final TranslationResidualFinding? finding =
        TranslationQuality.findSuspiciousFragmentResidual(
          sourceFragment: sourceDom.fragment,
          translatedFragment: translatedDom.fragment,
          targetLanguage: config.targetLanguage,
          allowRetainedAuthorSignature: block.isAuthorSignature,
          allowBibliographicRetention: isBibliographicEntry,
          lockedGlossary: config.lockedGlossary,
        );
    _responseCount(translatedDom.instrumentation, 'qualityDomChecks');
    if (finding == null) {
      return;
    }

    throw FormatException(finding.messageForBlock(block.id));
  }

  static String _truncateUtf16(String value, int limit) {
    if (value.length <= limit) return value;
    // Do not leave a dangling high surrogate at the truncation boundary.
    int end = limit;
    if (end > 0 &&
        value.codeUnitAt(end - 1) >= 0xd800 &&
        value.codeUnitAt(end - 1) <= 0xdbff) {
      end -= 1;
    }
    return value.substring(0, end);
  }

  /// Keep valid JSON and prioritize terminology over rolling summaries.
  /// Each section has its own serialized budget, so fallback requests remain
  /// small even when the original batch exceeded the provider's window.
  static Map<String, String> _fallbackContextMessage(
    TranslationBatchContext context,
  ) {
    Object? bounded(Object? value, int budget) {
      if (value is String) {
        String text = _truncateUtf16(value, budget);
        while (jsonEncode(text).length > budget && text.isNotEmpty) {
          text = _truncateUtf16(text, text.length ~/ 2);
        }
        return text;
      }
      if (value is List) {
        final List<Object?> result = <Object?>[];
        for (final Object? item in value) {
          final int remaining = budget - jsonEncode(result).length - 1;
          if (remaining < 32) break;
          final Object? clipped = bounded(item, remaining);
          if (jsonEncode(<Object?>[...result, clipped]).length > budget) break;
          result.add(clipped);
        }
        return result;
      }
      if (value is Map) {
        final Map<String, Object?> result = <String, Object?>{};
        for (final MapEntry<dynamic, dynamic> entry in value.entries) {
          final String key = entry.key.toString();
          final int remaining =
              budget - jsonEncode(result).length - jsonEncode(key).length - 2;
          if (remaining < 32) break;
          final Object? clipped = bounded(entry.value, remaining);
          if (jsonEncode(<String, Object?>{...result, key: clipped}).length >
              budget) {
            break;
          }
          result[key] = clipped;
        }
        return result;
      }
      return value;
    }

    final Map<String, Object?> memory =
        context.bookMemory ?? const <String, Object?>{};
    return <String, String>{
      'role': 'system',
      'content':
          'Read-only reference context follows. Use it for terminology, '
          'continuity, and pronouns. Do not translate or return this context; '
          'translate only the HTML fragment or text in the user message.\n'
          '${jsonEncode(<String, Object?>{
            'chapterTitle': bounded(context.chapterTitle, 512),
            'before': bounded(context.before.map((s) => s.toJson()).toList(), 2048),
            'after': bounded(context.after.map((s) => s.toJson()).toList(), 2048),
            'bookMemory': <String, Object?>{if (memory.containsKey('glossary')) 'glossary': bounded(memory['glossary'], 8192), if (memory.containsKey('bookSummary')) 'bookSummary': bounded(memory['bookSummary'], 1024), if (memory.containsKey('recentChapters')) 'recentChapters': bounded(memory['recentChapters'], 2048), if (memory.containsKey('styleGuide')) 'styleGuide': bounded(memory['styleGuide'], 512)},
          })}',
    };
  }

  String _outputFilePath({
    required String inputPath,
    required String outputDirectory,
    required String suffix,
  }) {
    final String safeSuffix = TranslationApiClient.sanitizeOutputSuffix(suffix);
    final String baseName = path.basenameWithoutExtension(inputPath);
    String candidate = path.join(
      outputDirectory,
      outputFileNameForTest(baseName, safeSuffix),
    );
    // Never overwrite the source EPUB even if sanitization collapses the name.
    if (_sameFilesystemPath(candidate, inputPath)) {
      candidate = path.join(
        outputDirectory,
        outputFileNameForTest(baseName, '${safeSuffix}_out'),
      );
    }
    return candidate;
  }

  /// Reserve room for the repack temporary suffix. Windows counts UTF-16
  /// units; POSIX filesystems count UTF-8 bytes per component.
  @visibleForTesting
  static String outputFileNameForTest(
    String baseName,
    String suffix, {
    bool? windows,
  }) {
    final bool useUtf16 = windows ?? Platform.isWindows;
    int size(String value) =>
        useUtf16 ? value.length : utf8.encode(value).length;
    String truncate(String value, int budget) {
      if (useUtf16) return _truncateUtf16(value, budget);
      final result = StringBuffer();
      int used = 0;
      for (final rune in value.runes) {
        final character = String.fromCharCode(rune);
        final bytes = utf8.encode(character).length;
        if (used + bytes > budget) break;
        result.write(character);
        used += bytes;
      }
      return result.toString();
    }

    const int limit = 255 - 26; // .recovery. + 16-digit microsecond timestamp
    final String name = '$baseName$suffix.epub';
    if (size(name) <= limit) return name;
    final String hash = sha256
        .convert(utf8.encode(name))
        .toString()
        .substring(0, 12);
    final String tail = '${truncate(suffix, 64)}_$hash.epub';
    return '${truncate(baseName, limit - size(tail))}$tail';
  }

  @visibleForTesting
  static Future<void> validateOutputDirectory(
    String directory,
    UiLanguage language,
  ) async {
    final bool chinese = language == UiLanguage.chinese;
    if (await FileSystemEntity.type(directory) !=
        FileSystemEntityType.directory) {
      throw StateError(
        chinese
            ? '输出目录不存在或不是目录：$directory'
            : 'Output directory does not exist or is not a directory: $directory',
      );
    }
    File? probe;
    try {
      // Probe the directory itself: Windows ACLs distinguish creating files
      // from creating subdirectories (which can also inherit different ACLs).
      final candidate = File(
        path.join(
          directory,
          '.epub-write-probe-${DateTime.now().microsecondsSinceEpoch}-'
          '${Random.secure().nextInt(1 << 32)}',
        ),
      );
      await candidate.create(exclusive: true);
      probe = candidate;
      await probe.writeAsBytes([0], flush: true);
      await probe.delete();
      probe = null;
    } on FileSystemException catch (error) {
      throw StateError(
        chinese
            ? '无法写入输出目录：$directory（$error）'
            : 'Output directory is not writable: $directory ($error)',
      );
    } finally {
      if (probe != null && await probe.exists()) {
        try {
          await probe.delete();
        } on FileSystemException {
          // Preserve the original write failure if cleanup also fails.
        }
      }
    }
  }

  /// Longest write-path form the app ever produces for [outputFilePath]:
  /// `<output>.recovery.<16 digits>` kept by the lock-conflict recovery path
  /// (+26), which also covers the shorter `.tmp.<16 digits>` (+21) repack
  /// form and the `.bak.<16 digits>` (+21) backup form. All three suffixes
  /// use [DateTime.microsecondsSinceEpoch] (16 digits). Dart's
  /// [String.length] counts UTF-16 code units, which is what Windows
  /// MAX_PATH (260) counts.
  ///
  /// Visible for testing.
  @visibleForTesting
  static bool outputPathExceedsWindowsMaxPath(String outputFilePath) {
    // MAX_PATH (260) counts the terminating NUL, so 259 is the longest
    // usable path; a final path of exactly 260 already overflows.
    return outputFilePath.length + 26 >= 260;
  }

  /// Throws [WindowsLongPathException] when the longest write path the
  /// commit produces would exceed Windows MAX_PATH (260) while the system
  /// long-path policy is off. Runs before any paid API work. Fails open
  /// when the policy cannot be determined (null): blocking on a guess would
  /// be worse than the registry read failing silently.
  ///
  /// [longPathsEnabledReader] is a test seam for the (slow, PowerShell-based)
  /// registry read.
  ///
  /// Visible for testing.
  @visibleForTesting
  static Future<void> throwIfOutputPathTooLongForWindows(
    String outputFilePath, {
    Future<bool?> Function()? longPathsEnabledReader,
  }) async {
    final String fileName = path.windows.basename(outputFilePath);
    if (fileName.length + 26 > 255) {
      throw FileSystemException(
        'Output filename plus temporary suffix exceeds 255 UTF-16 code units.',
        outputFilePath,
      );
    }
    if (!outputPathExceedsWindowsMaxPath(outputFilePath)) {
      return;
    }
    final bool? enabled =
        await (longPathsEnabledReader ??
            NativePlatformBridge.windowsLongPathsEnabled)();
    if (enabled == false) {
      throw WindowsLongPathException(outputFilePath);
    }
  }

  /// Classifies a pre-run exclusive-create probe failure: a real sharing/lock
  /// violation (Windows osError 32/33) is reported as "locked" (close the
  /// reader); anything else (e.g. ERROR_ACCESS_DENIED = 5 on a read-only
  /// file, or a Unix EACCES/EROFS) is an access problem and must not be
  /// misreported as "locked".
  ///
  /// Visible for testing.
  @visibleForTesting
  static String preRunProbeErrorMessage(
    FileSystemException error,
    AppStrings strings,
    String outputFilePath,
  ) {
    return EpubIsolateWorker.isFileLockError(error)
        ? strings.outputFileLocked(outputFilePath)
        : strings.outputFileNotWritable(outputFilePath);
  }

  static bool _sameFilesystemPath(String left, String right) {
    final String a = _normalizeInputPathForCache(left);
    final String b = _normalizeInputPathForCache(right);
    if (a.isEmpty || b.isEmpty) {
      return false;
    }
    return a == b;
  }

  /// Canonical path used in fingerprints so Windows casing/separators match.
  static String _normalizeInputPathForCache(String inputPath) {
    final String trimmed = inputPath.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    String normalized = path.normalize(trimmed);
    try {
      normalized = path.normalize(File(trimmed).absolute.path);
    } catch (_) {
      // Keep the best-effort normalize above.
    }
    if (Platform.isWindows) {
      return normalized.toLowerCase();
    }
    return normalized;
  }

  Future<String> _inputFingerprint(
    String inputPath, {
    String? expectedSourceFingerprint,
    required CancelToken cancelToken,
  }) async {
    // Read as a stream: context changes elsewhere in the book must invalidate
    // block translations even when the file size and timestamp are unchanged.
    final Digest contentHash = await cancellableFingerprint(
      File(inputPath).openRead(),
      cancelToken: cancelToken,
      throwIfCancelled: _run.throwIfCancelled,
    );
    checkEpubSourceHash(contentHash.toString(), expectedSourceFingerprint);
    final String normalizedPath = _normalizeInputPathForCache(inputPath);
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              _cacheSchemaVersion,
              qualityCacheSchemaVersion,
              normalizedPath,
              contentHash.toString(),
            ].join('|'),
          ),
        )
        .toString();
  }

  String _jobKey({
    required String inputFingerprint,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
  }) {
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              _cacheSchemaVersion,
              qualityCacheSchemaVersion,
              config.chunkSize,
              inputFingerprint,
              _apiClient.normalizedBaseUrl(config.apiBaseUrl),
              config.model.trim(),
              config.targetLanguage.trim(),
              config.bilingual,
              config.lockedGlossary.trim(),
              config.residualQualityCheck,
              config.styleProfileEnabled,
              _styleProfileCacheValue(confirmedStyleProfile),
              chapters
                  .map((InspectedChapter chapter) => chapter.path)
                  .join('|'),
            ].join('|'),
          ),
        )
        .toString();
  }

  String _blockCacheKey(
    TranslationConfig config,
    ExtractedBlock block, {
    required String chapterPath,
    required String inputFingerprint,
    String contextIdentity = '',
    TranslationStyleProfile? confirmedStyleProfile,
  }) {
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              _cacheSchemaVersion,
              qualityCacheSchemaVersion,
              _apiClient.normalizedBaseUrl(config.apiBaseUrl),
              config.model.trim(),
              config.targetLanguage.trim(),
              config.lockedGlossary.trim(),
              config.chunkSize,
              config.residualQualityCheck,
              config.styleProfileEnabled,
              _styleProfileCacheValue(confirmedStyleProfile),
              inputFingerprint,
              chapterPath,
              if (contextIdentity.isNotEmpty)
                'selection-context-v1:$contextIdentity',
              // Block ids are positional within a chapter (e.g. "p-3"), so
              // two blocks with identical source HTML at different positions
              // get different keys. Neighbor context feeds the prompt for
              // each position, so sharing a key across positions would reuse
              // a translation that was shaped by the wrong context. Old
              // entries keyed without the id hash differently and are simply
              // never hit again.
              block.id,
              block.sourceHtml,
              // Earlier alias-marked footnotes were translated as prose.
              // Invalidate only those cache entries, retaining ordinary text.
              if (RegExp(
                r'\b(?!epub:)[\w-]+:type\s*=',
              ).hasMatch(block.sourceHtml))
                'epub-type-alias-protection-v1',
              // Old cell caches may contain model-owned layout or links.
              // Invalidate just these blocks, retaining ordinary paid text.
              if (block.tagName == 'td' || block.tagName == 'th')
                'table-cell-structure-v2',
              if (block.tagName == 'caption') 'table-caption-structure-v2',
              if (RegExp(
                r'<(?:pre|code|var|kbd|samp|svg|math|script|style)(?=[\s/>])',
                caseSensitive: false,
              ).hasMatch(block.sourceHtml))
                'non-prose-text-v2',
              if (block.isAuthorSignature) 'author-signature-v1',
            ].join('|'),
          ),
        )
        .toString();
  }

  static String _styleProfileCacheValue(
    TranslationStyleProfile? confirmedStyleProfile,
  ) {
    if (confirmedStyleProfile == null) {
      return 'none';
    }
    return jsonEncode(confirmedStyleProfile.toJson());
  }

  static InspectedChapter _prepareChapterForTarget(
    InspectedChapter chapter, {
    required String targetLanguage,
  }) {
    if (!_isCjkTargetLanguage(targetLanguage)) {
      return chapter;
    }
    return chapter.copyWith(
      blocks: chapter.blocks
          .map(
            (ExtractedBlock block) => block.copyWith(
              sourceHtml: _prepareBlockHtmlForTarget(
                sourceHtml: block.sourceHtml,
                targetLanguage: targetLanguage,
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  static String _prepareBlockHtmlForTarget({
    required String sourceHtml,
    required String targetLanguage,
  }) {
    if (!_isCjkTargetLanguage(targetLanguage) ||
        (!sourceHtml.toLowerCase().contains('dropcap') &&
            !sourceHtml.toLowerCase().contains('small'))) {
      return sourceHtml;
    }
    final dom.DocumentFragment fragment = XhtmlHtmlCompatibility.parseFragment(
      sourceHtml,
    );
    bool changed = false;
    final List<dom.Element> spans = fragment
        .querySelectorAll('span[class]')
        .toList(growable: false);
    for (final dom.Element span in spans) {
      if (_isInsideFootnoteMarkerAnchor(span) ||
          const EpubHtmlExtractor().isInsideSkippedAncestor(span)) {
        continue;
      }
      final bool isDropCap = span.classes.any(
        (String className) => className.toLowerCase().startsWith('dropcap'),
      );
      final bool isUppercaseSmallCaps =
          span.classes.any(_isSmallCapsClass) &&
          _isUppercaseLatinRun(span.text);
      if (!isDropCap && !isUppercaseSmallCaps) {
        continue;
      }
      if (_spanHasSemanticAttributes(span)) {
        span.classes.removeWhere(
          (token) =>
              token.toLowerCase().startsWith('dropcap') ||
              _isSmallCapsClass(token),
        );
      } else {
        _unwrapElement(span);
      }
      changed = true;
    }
    return changed ? fragment.outerHtml : sourceHtml;
  }

  static bool _isInsideFootnoteMarkerAnchor(dom.Element element) {
    dom.Node? current = element;
    while (current is dom.Element) {
      if (current.localName == 'a' && _containsFootnoteMarkerClass(current)) {
        return true;
      }
      current = current.parentNode;
    }
    return false;
  }

  static bool _isCjkTargetLanguage(String targetLanguage) {
    return const {
      'zh',
      'ja',
      'ko',
    }.contains(normalizeTargetLanguage(targetLanguage));
  }

  static void _validateNonemptyDoms(
    _ResponseHtml sourceDom,
    _ResponseHtml translatedDom,
  ) {
    bool hasBody(_ResponseHtml html) => html.slots.any(
      (slot) => !slot.protected && slot.text.trim().isNotEmpty,
    );
    if (hasBody(sourceDom) && !hasBody(translatedDom)) {
      throw const TranslationParseException(
        'Translated block has empty body text for a nonempty source.',
      );
    }

    // A-P1-1: reject a translation that carries no linguistic content for a
    // long source (e.g. the API returned only punctuation for a full
    // paragraph). Only obvious body loss is rejected: any translated word
    // passes, so legitimate short translations (titles) and tiny
    // translations in existing tests are unaffected.
    if (_linguisticBodyLength(sourceDom) >= 200 &&
        _linguisticBodyLength(translatedDom) == 0) {
      throw const TranslationParseException(
        'Translated block has no linguistic content for a long source.',
      );
    }
  }

  /// Matches every rune that is not a letter or number, used to measure how
  /// much linguistic content a translated body actually carries.
  static final RegExp _nonLinguisticChars = RegExp(
    r'[^\p{L}\p{N}]',
    unicode: true,
  );

  /// Counts letters/digits across scripts in the non-protected slots,
  /// ignoring whitespace and punctuation.
  static int _linguisticBodyLength(_ResponseHtml html) {
    var length = 0;
    for (final slot in html.slots) {
      if (slot.protected) continue;
      length += slot.text.replaceAll(_nonLinguisticChars, '').runes.length;
    }
    return length;
  }

  /// Canonical language identity for local script and prompt rules.
  static String normalizeTargetLanguage(String language) {
    final String value = language.trim().toLowerCase();
    final String base = value.split(RegExp('[-_]')).first;
    if (base == 'zh' ||
        value.contains('chinese') ||
        RegExp('中文|汉语|漢語').hasMatch(value)) {
      return 'zh';
    }
    if (base == 'ja' ||
        value.contains('japanese') ||
        RegExp('日语|日語|日本語').hasMatch(value)) {
      return 'ja';
    }
    if (base == 'ko' ||
        value.contains('korean') ||
        RegExp('韩语|韓語|한국어').hasMatch(value)) {
      return 'ko';
    }
    return base;
  }

  static bool _spanHasSemanticAttributes(dom.Element span) =>
      span.attributes.keys.any((key) => key != 'class' && key != 'style');

  static bool _isSmallCapsClass(String className) {
    final String normalized = className.toLowerCase();
    return normalized == 'small' ||
        normalized == 'small-caps' ||
        normalized == 'smallcaps';
  }

  static bool _isUppercaseLatinRun(String value) {
    final String letters = value.replaceAll(RegExp('[^A-Za-z]'), '');
    return letters.isNotEmpty && letters == letters.toUpperCase();
  }

  static void _unwrapElement(dom.Element element) {
    final dom.Node? parent = element.parentNode;
    if (parent == null) {
      return;
    }
    final int index = parent.nodes.indexOf(element);
    if (index < 0) {
      return;
    }
    final List<dom.Node> children = element.nodes.toList(growable: false);
    for (final dom.Node child in children) {
      child.remove();
    }
    element.remove();
    parent.nodes.insertAll(index, children);
  }

  JobResumeState _resumeStateFromJob({
    required String jobKey,
    required String inputFingerprint,
    required TranslationJob job,
    String? status,
  }) {
    return JobResumeState(
      jobKey: jobKey,
      inputFingerprint: inputFingerprint,
      inputPath: job.inputPath,
      outputPath: job.outputPath,
      status: status ?? job.status.name,
      completedFiles: job.completedFiles,
      totalFiles: job.totalFiles,
      completedBlocks: job.completedBlocks,
      totalBlocks: job.totalBlocks,
      cachedBlocks: job.cachedBlocks,
      resumedBlocks: job.resumedBlocks,
      currentChapter: job.currentChapter ?? '',
      updatedAtIso8601: DateTime.now().toIso8601String(),
    );
  }

  /// 性能-#40: the translated-body preview is only a UI snippet. Bound it
  /// by characters (not just block count) so a giant block does not pay
  /// for a full HTML parse and whitespace normalization.
  static const int _previewBodyMaxChars = 4000;

  /// Generous HTML-to-text size headroom when truncating a block's HTML
  /// before parsing it for the preview.
  static const int _previewHtmlHeadroomFactor = 8;

  String _previewBodyFromBlocks(
    List<ExtractedBlock> blocks, {
    required String fallback,
  }) {
    final StringBuffer preview = StringBuffer();
    int keptBlocks = 0;
    int remaining = _previewBodyMaxChars;
    for (final ExtractedBlock block in blocks) {
      if (keptBlocks >= 12 || remaining <= 0) {
        break;
      }
      final String? text = _plainTextFromHtml(
        block.translatedHtml,
        maxChars: remaining,
      );
      final String trimmed = text?.trim() ?? '';
      if (trimmed.isEmpty) {
        continue;
      }
      if (keptBlocks > 0) {
        preview.write('\n\n');
      }
      preview.write(trimmed);
      keptBlocks++;
      remaining -= trimmed.length;
    }
    if (keptBlocks == 0) {
      return fallback;
    }
    return preview.toString();
  }

  String? _plainTextFromHtml(String? html, {int? maxChars}) {
    if (html == null || html.trim().isEmpty) {
      return null;
    }
    // 性能-#40: for a bounded preview, truncate a giant block's HTML before
    // parsing so the parse and the whitespace normalization below stay
    // proportional to the preview size, not the block size.
    final String boundedHtml =
        maxChars == null || html.length <= maxChars * _previewHtmlHeadroomFactor
        ? html
        : html.substring(0, maxChars * _previewHtmlHeadroomFactor);
    final dom.DocumentFragment fragment = XhtmlHtmlCompatibility.parseFragment(
      boundedHtml,
    );
    String text = (fragment.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (maxChars != null && text.length > maxChars) {
      text = text.substring(0, maxChars).trimRight();
    }
    return text;
  }

  String _formatDuration(Duration duration) {
    final int milliseconds = duration.inMilliseconds;
    if (milliseconds < 1000) {
      return '${milliseconds}ms';
    }
    if (milliseconds < 60000) {
      return '${(milliseconds / 1000).toStringAsFixed(2)}s';
    }
    final int minutes = duration.inMinutes;
    final int seconds = duration.inSeconds.remainder(60);
    return '${minutes}m ${seconds}s';
  }

  String _formatBlocksPerMinute(int blockCount, Duration elapsed) {
    if (blockCount <= 0 || elapsed.inMilliseconds <= 0) {
      return '0.0';
    }
    final double minutes =
        elapsed.inMilliseconds / Duration.millisecondsPerMinute;
    return (blockCount / minutes).toStringAsFixed(1);
  }
}

/// Mutable selection state for
/// [EpubChapterTranslator.selectMemorySnapshotForTest] (性能-#38).
@visibleForTesting
class MemorySnapshotCursor {
  int index = 0;
  Object? winner;
  int lastPosition = -1;
}

/// A response-local DOM. Clones and rebuilt skeletons stay in DOM form;
/// serialization is deferred until the response leaves structure handling.
class _ResponseHtml {
  _ResponseHtml(this.fragment, [this.instrumentation]);

  factory _ResponseHtml.parse(
    String html, [
    Map<String, int>? instrumentation,
  ]) {
    _responseCount(instrumentation, 'parses');
    return _ResponseHtml(
      XhtmlHtmlCompatibility.parseFragment(html),
      instrumentation,
    );
  }

  factory _ResponseHtml.fromRoot(
    dom.Element root,
    Map<String, int>? instrumentation,
  ) => _ResponseHtml(dom.DocumentFragment()..append(root), instrumentation);

  final dom.DocumentFragment fragment;
  final Map<String, int>? instrumentation;
  _ResponseNodeFacts? _facts;
  List<_HtmlTextSlot>? _slots;

  dom.Element? get root => EpubChapterTranslator._fragmentRoot(fragment);
  String get html => root?.outerHtml ?? fragment.outerHtml.trim();
  _ResponseNodeFacts get facts =>
      _facts ??= _ResponseNodeFacts(fragment, instrumentation);
  String get plainText => facts.fullText;
  String textOf(dom.Element node) => facts.textOf(node);
  bool isProtected(dom.Element node) => facts.isProtected(node);

  List<_HtmlTextSlot> get slots => _slots ??= () {
    final slots = <_HtmlTextSlot>[];
    for (final node in fragment.nodes) {
      EpubChapterTranslator._collectTextSlots(
        node,
        slots,
        protected: false,
        facts: facts,
      );
    }
    return slots;
  }();

  // All text/structure mutations must invalidate before the next read.
  void invalidate() {
    _facts = null;
    _slots = null;
  }
}

void _responseCount(Map<String, int>? counts, String key) {
  if (counts != null) counts[key] = (counts[key] ?? 0) + 1;
}

/// One linear text index per immutable DOM phase. Marker classification needs
/// at most 12 non-whitespace characters, so summaries are capped at 13. This
/// avoids concatenating every ancestor's entire descendant text in deep trees.
class _ResponseNodeFacts {
  _ResponseNodeFacts(dom.Node root, [this.instrumentation]) {
    _index(root);
    fullText = _buffer.toString();
  }

  final Map<String, int>? instrumentation;
  final _buffer = StringBuffer();
  final _ranges = Map<dom.Node, (int, int)>.identity();
  final _compact = Map<dom.Node, String>.identity();
  final _protected = Map<dom.Element, bool>.identity();
  final _texts = <(int, int), String>{};
  late final String fullText;

  void _index(dom.Node node) {
    _responseCount(instrumentation, 'indexedNodes');
    final start = _buffer.length;
    String compact = '';
    if (node is dom.Text) {
      _buffer.write(node.data);
      compact = node.data.replaceAll(RegExp(r'\s+'), '');
      if (compact.length > 13) compact = compact.substring(0, 13);
    } else {
      for (final child in node.nodes) {
        _index(child);
        if (compact.length < 13) {
          compact += _compact[child]!;
          if (compact.length > 13) compact = compact.substring(0, 13);
        }
      }
    }
    _ranges[node] = (start, _buffer.length);
    _compact[node] = compact;
  }

  String textOf(dom.Node node) {
    final range = _ranges[node]!;
    return _texts.putIfAbsent(range, () {
      _responseCount(instrumentation, 'textMaterializations');
      return fullText.substring(range.$1, range.$2);
    });
  }

  bool isProtected(dom.Element node) => _protected.putIfAbsent(node, () {
    _responseCount(instrumentation, 'protectionChecks');
    return EpubChapterTranslator._isProtectedTextElement(
      node,
      text: _compact[node]!,
    );
  });
}

/// Compare aligned subtree ranges in O(1) after one linear mismatch index.
/// This also covers a lang attribute on every level of a nested reply. When
/// rebuilding shifts text boundaries, fall back to cached exact text rather
/// than using a probabilistic hash for a semantic alignment decision.
class _ResponseTextAlignment {
  _ResponseTextAlignment(this.reply, this.output) {
    final length = min(reply.fullText.length, output.fullText.length);
    var lastMismatch = -1;
    _lastMismatch = List<int>.generate(length, (index) {
      _responseCount(reply.instrumentation, 'alignmentCharacters');
      if (reply.fullText.codeUnitAt(index) !=
          output.fullText.codeUnitAt(index)) {
        lastMismatch = index;
      }
      return lastMismatch;
    });
  }

  final _ResponseNodeFacts reply;
  final _ResponseNodeFacts output;
  late final List<int> _lastMismatch;

  bool matches(dom.Element replyNode, dom.Element outputNode) {
    final a = reply._ranges[replyNode]!;
    final b = output._ranges[outputNode]!;
    if (a == b) {
      return a.$1 == a.$2 || _lastMismatch[a.$2 - 1] < a.$1;
    }
    if (a.$2 - a.$1 != b.$2 - b.$1) return false;
    return reply.textOf(replyNode) == output.textOf(outputNode);
  }
}

class _NormalizedAnchorHtml {
  const _NormalizedAnchorHtml({
    this.root,
    this.hasOverflow = false,
    this.trustedOverflowTexts = const <dom.Text>[],
  });

  final dom.Element? root;
  final bool hasOverflow;
  final List<dom.Text> trustedOverflowTexts;
}

class _HtmlTextSlot {
  const _HtmlTextSlot({required this.node, required this.protected});

  final dom.Text node;
  final bool protected;

  String get text => node.data;

  set text(String value) {
    node.data = value;
  }
}

class _TimedBatchResult {
  const _TimedBatchResult({
    required this.batch,
    required this.translatedBlocks,
    required this.batchNumber,
    required this.elapsed,
  });

  final TranslationBlockBatch batch;
  final List<String> translatedBlocks;
  final int batchNumber;
  final Duration elapsed;
}
