import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:path/path.dart' as path;

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/io/atomic_file_writer.dart';
import '../../../../shared/logging/app_logger.dart';
import '../../../../shared/platform/native_platform_bridge.dart';
import '../../../../shared/security/sensitive_text.dart';
import '../../../../shared/text/unicode_prefix.dart';
import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/job_resume_state.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/models/translation_job.dart';
import '../../domain/models/translation_run_result.dart';
import '../../domain/models/translation_style_profile.dart';
import '../../domain/repositories/translation_repository.dart';
import '../translation_cache_store.dart';
import '../translation_quality.dart';
import '../translation_response_guard.dart';
import '../cache_restoration_scanner.dart';
import '../epub_isolate_worker.dart';
import 'epub_repacker.dart';
import 'epub_html_extractor.dart';
import 'chapter_source_restorer.dart';
import 'chapter_source_spool.dart';
import 'epub_source_guard.dart';
import 'xhtml_html_compatibility.dart';
import 'footnote_batch_planner.dart';
import 'protected_anchor_text_slots.dart';
import 'epub_semantics.dart';
import 'book_source_index.dart';
import 'book_consistency_repair.dart';
import 'epub_xml_characters.dart';
import 'translation_api_client.dart';
import 'translation_artifact_cache.dart';
import 'translation_consistency_checker.dart';
import 'review_text_patch.dart';
import 'review_evidence_validator.dart';
import 'semantic_source_analysis.dart';
import 'cancellable_fingerprint.dart';
import 'translation_batch_planner.dart';
import 'translation_progress_persistence.dart';
import 'translation_run_context.dart';
import 'translation_work_queue.dart';

part 'epub_book_memory.dart';
part 'epub_translation_strategy.dart';
part 'epub_semantic_reviewer.dart';
part 'epub_semantic_grounding.dart';
part 'epub_response_dom_locker.dart';
part 'epub_translator_paths.dart';
part 'epub_token_saving_strategy.dart';
part 'epub_chapter_memory_batch.dart';

/// Orchestrates cache, book-memory, batch planning, and API translation.
///
/// ZIP inspect/repack live in [EpubInspector] / [EpubRepacker]. HTTP details in
/// [TranslationApiClient]; batch sizing/context in [TranslationBatchPlanner].
class EpubChapterTranslator {
  /// Revalidate a user-selected suggestion before creating a reviewed EPUB.
  static String validateReviewSuggestion({
    required TranslationConfig config,
    required ExtractedBlock block,
    required String translatedHtml,
  }) => _lockAndValidateTranslatedBlock(
    config: config,
    block: block,
    translatedHtml: translatedHtml,
  );
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
  TranslationConfig? _rateLimitConfig;
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
    bool retainedPartialTranslation = false,
  }) {
    _run.markDegraded(
      chapterPath: chapterPath,
      blockId: blockId,
      apiCounted: apiCounted,
      reason: reason,
      retainedPartialTranslation: retainedPartialTranslation,
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
  _AdaptiveBodyBudget? _adaptiveBodyBudget;
  _AdaptiveBodyBudget _bodyBudget(TranslationConfig config) {
    final current = _adaptiveBodyBudget;
    if (current != null && identical(current.config, config)) return current;
    return _adaptiveBodyBudget = _AdaptiveBodyBudget(config);
  }

  final TranslationBatchPlanner _batchPlanner;
  final FootnoteBatchPlanner _footnoteBatchPlanner;
  late final _EpubBookMemory _memory = _EpubBookMemory(this);
  late final TranslationArtifactCache _artifactCache = TranslationArtifactCache(
    _cacheStore,
  );
  late final _EpubSemanticReviewer _semanticReviewer = _EpubSemanticReviewer(
    this,
  );
  ({String identity, TranslationApiMetrics usage})? _pendingStyleUsage;

  String _styleUsageIdentity(
    TranslationConfig config,
    List<InspectedChapter> chapters,
  ) => TranslationArtifactCache.key(config, 'style-usage', [
    for (final c in chapters)
      if (c.includeInTranslation) [c.path, c.sourceIdentity?.sha256],
  ]);
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
      } catch (error) {
        if (TranslationApiClient.isRateLimitError(error)) {
          final config = _rateLimitConfig ?? TranslationConfig.defaults();
          _run.requests.deferFor(
            _apiClient.sharedRateLimitDelayOverride ??
                TranslationApiClient.retryDelayForError(config, error, 1),
          );
        }
        rethrow;
      } finally {
        if (stopwatch != null) {
          stopwatch.stop();
          onMemoryAttempt!(stopwatch.elapsed);
        }
      }
    }, throwIfCancelled: _run.throwIfCancelled);
  }

  static final Object _memoryAttemptKey = Object();
  static const String _cacheSchemaVersion = 'v17-structure-repair';

  // Quality rules version input/job/block identities as well as checkpoints.
  static const String qualityCacheSchemaVersion =
      'v30-verified-partial-corrections';

  static int htmlBudgetTokensForTest(String html) =>
      _TranslationRequestBudget.estimateTokens(html);

  static ({int fixedTokens, int payloadTokens, int totalTokens})
  requestBudgetForTest(Map<String, dynamic> data) =>
      _TranslationRequestBudget.forRequest(data);

  /// Test-only merge. The [memory] JSON stands in for the in-memory
  /// [_BookMemory] (locks already resolved, e.g. from a checkpoint), so its
  /// locks are trusted; the [chapter] JSON stands in for a model reply, so
  /// model-declared locks are distrusted unless [trustedChapterLocks] is set.
  static Map<String, Object?> mergeBookMemoryForTest(
    Map<String, Object?> memory,
    Map<String, Object?> chapter, {
    bool trustedMemoryLocks = true,
    bool trustedChapterLocks = false,
  }) => _BookMemory.fromJson(memory, trustedLocks: trustedMemoryLocks)
      .mergeChapter(
        _ChapterMemory.fromJson(chapter, trustedLocks: trustedChapterLocks),
      )
      .toJson();

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
  static Future<
    Future<void> Function(
      List<({String path, Map<String, Object?> memory})> timeline,
    )
  >
  bookMemoryCheckpointWriterForTest({
    required TranslationCacheStore cacheStore,
    required String jobKey,
    required int chunkSize,
    bool resume = false,
  }) async {
    final checkpoint = _BookMemoryCheckpoint(cacheStore, jobKey, chunkSize);
    if (resume) await checkpoint.load();
    return (List<({String path, Map<String, Object?> memory})> timeline) =>
        checkpoint.save(
          timeline.isEmpty
              ? _BookMemory.fromJson({})
              : _BookMemory.fromJson(timeline.last.memory, trustedLocks: true),
          completedChapterPaths: timeline.map((entry) => entry.path).toSet(),
          timeline: [
            for (final entry in timeline)
              (
                path: entry.path,
                memory: _BookMemory.fromJson(entry.memory, trustedLocks: true),
              ),
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
          memory: _BookMemory.fromJson(
            entry.memory,
            trustedLocks: trustedLocks,
          ),
        ),
    ],
    schema: schema,
  );

  static Future<Map<String, Object?>?> loadBookMemoryCheckpointForTest({
    required TranslationCacheStore cacheStore,
    required String jobKey,
    required int chunkSize,
  }) async => (await _BookMemoryCheckpoint(
    cacheStore,
    jobKey,
    chunkSize,
  ).load())?.memory.toJson();

  static Future<List<Map<String, Object?>>> loadBookMemoryTimelineForTest({
    required TranslationCacheStore cacheStore,
    required String jobKey,
    required int chunkSize,
  }) async => [
    for (final entry
        in (await _BookMemoryCheckpoint(
              cacheStore,
              jobKey,
              chunkSize,
            ).load())?.timeline ??
            const [])
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
  }) => position != null && position > maxRecordedPosition;

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
    InspectedChapter chapter,
    Directory directory,
  ) => ChapterSourceSpool(directory: directory).release(chapter);

  static Future<InspectedChapter> restoreChapterSourcesForTest(
    InspectedChapter chapter,
    Directory directory, {
    bool Function()? isCancelled,
  }) => ChapterSourceSpool(
    directory: directory,
  ).restore(chapter, isCancelled: isCancelled);

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
      useCache: false,
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
      await validateInspectedSource(
        chapters,
        cancelToken: cancelToken,
        throwIfCancelled: run.throwIfCancelled,
      );
      run.throwIfCancelled();
      dio = _apiClient.buildDio(config);
      final profile = await _invocation(run)._memory.generateStyleProfile(
        dio: dio,
        config: config,
        chapters: chapters,
        cancelToken: run.cancelToken,
        throwIfCancelled: run.throwIfCancelled,
      );
      final identity = _styleUsageIdentity(config, chapters);
      final usage = TranslationApiMetrics()..add(_apiClient.metricsFor(dio));
      final previous = _pendingStyleUsage;
      if (previous != null && previous.identity == identity) {
        usage.add(previous.usage);
      }
      _pendingStyleUsage = (identity: identity, usage: usage);
      return profile;
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
        useCache: false,
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
    final styleUsage = _pendingStyleUsage;
    _pendingStyleUsage = null;
    if (styleUsage != null &&
        styleUsage.identity == _styleUsageIdentity(config, chapters)) {
      run.styleMetrics.add(styleUsage.usage);
    }
    invocation._rateLimitConfig = config;
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
    TranslationJob? lastProgressJob;
    final sourceSpool = ChapterSourceSpool();
    final cacheSpool = CacheRestorationSpool();
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
        await validateInspectedSource(
          chapters,
          inputPath: inputPath,
          cancelToken: cancelToken,
          throwIfCancelled: _run.throwIfCancelled,
        );
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
      _run.cacheSourceIdentity = inputFingerprint;
      JobResumeState? previousState;
      bool unreadableResumeState = false;
      final memoryCheckpoint = _BookMemoryCheckpoint(
        _cacheStore,
        jobKey,
        config.chunkSize,
      );
      final restoredMemory = await memoryCheckpoint.load();
      try {
        previousState = await _cacheStore.loadJobState(jobKey);
        if (previousState != null && restoredMemory == null) {
          AppLogger.warn(
            'Checkpoint has no compatible chunkSize/schema memory identity; discarding progress metadata.',
            tag: 'translate',
          );
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
        job = job.copyWith(
          apiUsage: dioReady
              ? (TranslationApiMetrics()
                      ..add(_apiClient.metricsFor(dio))
                      ..add(_run.styleMetrics))
                    .toJson()
              : const {},
          elapsedMilliseconds: translationStopwatch.elapsedMilliseconds,
          reviewSuggestionCount: _run.semanticCorrections.length,
          unreviewedBlockCount: _run.semanticUnreviewed.length,
          consistencyWarningCount: _run.consistencyFindings.length,
        );
        currentJob = job;
        lastProgressJob = job;
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

      _run.sourceHints = BookSourceIndex.build(
        selectedChapters,
        trackMemorySignals: config.tokenSavingMode,
      );
      if (config.semanticQualityCheck) {
        for (final chapter in selectedChapters) {
          final seen = <String>{};
          for (var index = 0; index < chapter.blocks.length; index++) {
            final block = chapter.blocks[index];
            _run.semanticEvidence.add(
              block.sourceText,
              before: index > 0 ? chapter.blocks[index - 1].sourceText : '',
              after: index + 1 < chapter.blocks.length
                  ? chapter.blocks[index + 1].sourceText
                  : '',
            );
            // Audit a bounded sample of distinct substantial paragraphs, even
            // without a deterministic risk flag. Repeated boilerplate is free.
            if (seen.length < 4096 &&
                block.sourceText.length >= 120 &&
                seen.add(block.sourceText) &&
                seen.length % 8 == 0) {
              _run.semanticAuditSamples.add(
                EpubRepacker.degradedKeyForBlock(
                  chapterPath: chapter.path,
                  blockId: block.id,
                ),
              );
            }
          }
        }
      }
      emit(
        currentJob,
        s.runLogRestoringCache(selectedChapters.length, totalBlocks),
      );
      throwIfCancelled();

      _BookMemory? bookMemory = userStyleProfile == null
          ? null
          : _BookMemory.empty.copyWith(
              styleProfile: userStyleProfile,
              styleProfileConfirmed: true,
            );
      bool initialBookMemoryAttempted = false;
      _BookMemory? initialMemoryForRun = restoredMemory?.initialMemory;
      final chapterMemoryBatch = _ChapterMemoryBatch(
        config.tokenSavingMode
            ? restoredMemory?.pendingChapters ?? const []
            : const [],
      );
      final memoryChapters = <String>{
        ...?restoredMemory?.completedChapterPaths,
      };
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
        AppLogger.info(
          'Restored book memory; skipping initial API generation.',
          tag: 'book-memory',
        );
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

      final snapshots = Expando<Map<String, Object?>>();
      Map<String, Object?> serializeSnapshot(_BookMemory memory) =>
          snapshots[memory] ??= memory.toJson();

      Map<String, Object?>? snapshotFallback() {
        final initial = initialMemoryForRun;
        if (config.tokenSavingMode && initial != null) {
          return serializeSnapshot(initial);
        }
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
          serialize: (Object memory) => config.tokenSavingMode
              ? serializeSnapshot(memory as _BookMemory)
              : (memory as _BookMemory).toJson(),
          fallback: snapshotFallback,
        );
      }

      final contextIds = Expando<String>();
      String cacheContextForChapter(InspectedChapter chapter) {
        if (!config.tokenSavingMode) return contextIdentity;
        final snapshot = bookMemorySnapshotFor(chapter);
        if (snapshot == null) return '$contextIdentity:unavailable';
        return contextIds[snapshot] ??=
            '$contextIdentity:${sha256.convert(utf8.encode(jsonEncode(snapshot)))}';
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
        if (config.tokenSavingMode) initialMemoryForRun ??= bookMemory;
        try {
          await memoryCheckpoint.save(
            bookMemory!,
            completedChapterPaths: memoryChapters,
            timeline: memoryTimeline,
            initialMemory: config.tokenSavingMode ? initialMemoryForRun : null,
            pendingChapters: config.tokenSavingMode
                ? chapterMemoryBatch.chapters
                : const [],
          );
        } catch (error) {
          AppLogger.warn(
            'Book memory checkpoint save failed (${error.runtimeType}).',
            tag: 'book-memory',
          );
        }
      }

      final CacheRestorationResult restoration =
          await CacheRestorationScanner(
            readTranslation: _cacheStore.getBlockTranslation,
            configuredApiKey: config.apiKey,
          ).scan(
            chapters: selectedChapters,
            persistChapter: cacheSpool.save,
            acceptCached: (chapter, block, html) async {
              // Recheck this narrow guard on old cache entries without
              // invalidating an otherwise reusable whole-book cache.
              if (TranslationResponseGuard.isNonTranslationReply(
                sourceText: block.sourceText,
                translatedText: _ResponseHtml.parse(html).plainText,
              )) {
                return false;
              }
              return !config.semanticQualityCheck ||
                  await _semanticReviewer.restore(
                    config,
                    chapter.path,
                    block,
                    html,
                  );
            },
            cacheKeyFor: (InspectedChapter chapter, ExtractedBlock block) =>
                _blockCacheKey(
                  config,
                  block,
                  chapterPath: chapter.path,
                  inputFingerprint: inputFingerprint,
                  contextIdentity: cacheContextForChapter(chapter),
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
              includeStyleProfile: userStyleProfile == null,
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
          throwIfCancelled();
          if (config.autoApplyVerifiedCorrections) {
            try {
              final recovered = await _memory.completeEntityMemory(
                dio: dio,
                config: config,
                memory: _BookMemory.empty,
                cancelToken: cancelToken,
              );
              bookMemory = userStyleProfile == null
                  ? recovered
                  : recovered.copyWith(
                      styleProfile: userStyleProfile,
                      styleProfileConfirmed: true,
                    );
              await persistBookMemory();
              if (recovered.glossary.isNotEmpty) {
                emit(
                  currentJob,
                  config.uiLanguage == UiLanguage.chinese
                      ? '书籍摘要生成失败，已通过独立请求恢复专名表。'
                      : 'Book summary failed; recovered the entity glossary separately.',
                );
                return;
              }
            } catch (_) {
              throwIfCancelled();
            }
          }
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
          if (config.tokenSavingMode && initialMemoryForRun == null) {
            bookMemory ??= _BookMemory.empty;
            await persistBookMemory();
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
          await cacheSpool.loadChapter(restoration, chapter.path);
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
                  contextIdentity: cacheContextForChapter(reference.chapter),
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
                        contextIdentity: cacheContextForChapter(
                          reference.chapter,
                        ),
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
          final released = await sourceSpool.release(
            chapter.copyWith(
              blocks: translatedBlocks,
              translatedBody: updatedByPath[chapter.path]!.translatedBody,
            ),
          );
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

      Future<void> translateSingleChapter(int chapterIndex) async {
        throwIfCancelled();
        final InspectedChapter chapter = selectedChapters[chapterIndex];
        final Stopwatch chapterStopwatch = Stopwatch()..start();
        Duration chapterApiElapsed = Duration.zero;
        Duration chapterCacheWriteElapsed = Duration.zero;
        int chapterApiBlocks = 0;
        int chapterCacheWrites = 0;
        await cacheSpool.loadChapter(restoration, chapter.path);
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

        final String chapterCacheContext = cacheContextForChapter(chapter);
        final int chunkSize = config.tokenSavingMode
            ? _bodyBudget(config).plannedChunkSize
            : config.chunkSize;
        final List<TranslationBlockBatch> batches = _batchPlanner.plan(
          pendingBlocks: pendingBlocks,
          chunkSize: chunkSize,
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
            final List<String> translated = await _strategy.translateBlockBatch(
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
                    contextIdentity: chapterCacheContext,
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
                        contextIdentity: chapterCacheContext,
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
            chapterApiBlocks += batch.blocks
                .where(
                  (block) => !_run.reusedDraftBlocks.contains(
                    EpubRepacker.degradedKeyForBlock(
                      chapterPath: chapter.path,
                      blockId: block.id,
                    ),
                  ),
                )
                .length;
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
            _formatBlocksPerMinute(chapterApiBlocks, chapterStopwatch.elapsed),
          ),
        );
        throwIfCancelled();
        final bool futurePendingBlocks = restoration
            .hasPendingBlocksFromChapter(chapterIndex + 1);
        if (config.tokenSavingMode && futurePendingBlocks) {
          await ensureInitialBookMemory();
          final int lastPending =
              selectedPositionByPath[chapterMemoryBatch.lastPath] ?? -1;
          if (chapterIndex > maxRecordedTimelinePosition &&
              chapterIndex > lastPending &&
              !memoryChapters.contains(chapter.path)) {
            final memory = bookMemory ?? _BookMemory.empty;
            final sample = _memory.chapterMemorySample(
              chapter: updatedByPath[chapter.path]!,
              currentMemory: memory,
              degradedBlockIds: _degradedBlocks,
            );
            if (sample != null) chapterMemoryBatch.add(sample);
            final samples = chapterMemoryBatch.chapters;
            final bool footnotesNext =
                chapterIndex + 1 < selectedChapters.length &&
                isFootnoteChapter(chapterIndex + 1);
            final bool lastTranslationNext =
                memoryTimeline.isEmpty &&
                !restoration.hasPendingBlocksFromChapter(chapterIndex + 2);
            if (samples.isNotEmpty &&
                (chapterMemoryBatch.shouldUpdate ||
                    footnotesNext ||
                    lastTranslationNext)) {
              final clock = Stopwatch()..start();
              try {
                bookMemory = await trackMemoryRequests(
                  () => _memory.updateBookMemoryBatch(
                    dio: dio,
                    config: config,
                    currentMemory: memory,
                    chapters: samples,
                    cancelToken: cancelToken,
                  ),
                );
                throwIfCancelled();
                memoryChapters.addAll(samples.map((sample) => sample.path));
                bookMemory = bookMemory!.withLockedGlossary(
                  config.lockedGlossary,
                );
                recordMemoryTimeline(chapter.path, bookMemory!);
                emit(
                  chapterDoneJob,
                  s.runLogBookMemoryUpdated(
                    chapter.title,
                    _formatDuration(clock.elapsed),
                  ),
                );
              } catch (error) {
                throwIfCancelled();
                emit(
                  chapterDoneJob,
                  s.runLogBookMemoryChapterSkipped(
                    chapter.title,
                    _linePreview(_safeErrorText(error, config)),
                  ),
                );
              }
              chapterMemoryBatch.clear();
            }
            await persistBookMemory();
          }
        } else if (futurePendingBlocks) {
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
              bookMemory = bookMemory!.withLockedGlossary(
                config.lockedGlossary,
              );
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
        selectedChapters[chapterIndex] = _releaseChapterSourceStrings(chapter);
        updatedByPath[chapter.path] = _releaseChapterSourceStrings(
          updatedByPath[chapter.path]!,
        );
        final released = await sourceSpool.release(
          chapter.copyWith(
            blocks: translatedBlocks,
            translatedBody: updatedByPath[chapter.path]!.translatedBody,
          ),
        );
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

      bool isIndependentOfSequentialMemory(int index) {
        if (index < 0 ||
            index >= selectedChapters.length ||
            isFootnoteChapter(index)) {
          return false;
        }
        final InspectedChapter candidate = selectedChapters[index];
        return (config.tokenSavingMode &&
                index <= maxRecordedTimelinePosition) ||
            memoryChapters.contains(candidate.path) ||
            !restoration.hasPendingBlocksFromChapter(index + 1);
      }

      try {
        for (
          int chapterIndex = 0;
          chapterIndex < selectedChapters.length;
          chapterIndex += 1
        ) {
          throwIfCancelled();
          if (isFootnoteChapter(chapterIndex)) {
            chapterIndex = await translateFootnoteRun(chapterIndex);
            continue;
          }
          if (concurrency > 1 &&
              isIndependentOfSequentialMemory(chapterIndex)) {
            final List<int> parallelGroup = <int>[chapterIndex];
            while (parallelGroup.length < concurrency &&
                chapterIndex + parallelGroup.length < selectedChapters.length &&
                isIndependentOfSequentialMemory(
                  chapterIndex + parallelGroup.length,
                )) {
              parallelGroup.add(chapterIndex + parallelGroup.length);
            }
            if (parallelGroup.length >= 2) {
              final bool anyPending = parallelGroup.any((int idx) {
                final InspectedChapter candidate = selectedChapters[idx];
                final Map<String, String>? cached =
                    restoration.translationsByChapter[candidate.path];
                return candidate.blocks.any(
                  (ExtractedBlock block) =>
                      cached == null || !cached.containsKey(block.id),
                );
              });
              if (anyPending) {
                await ensureInitialBookMemory();
              }
              await const TranslationWorkQueue().map<int, void>(
                parallelGroup,
                concurrency: concurrency,
                throwIfCancelled: throwIfCancelled,
                process: (int idx, _) => translateSingleChapter(idx),
              );
              chapterIndex += parallelGroup.length - 1;
              continue;
            }
          }
          await translateSingleChapter(chapterIndex);
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

      List<InspectedChapter> updatedChapters = chapters
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
      final relationshipRepair =
          BookRelationshipConsistency.repairUnqualifiedCousins(
            chapters: updatedChapters,
            config: config,
            glossary: bookMemory?.glossary ?? const <Map<String, String>>[],
            sourceHints: _run.sourceHints,
          );
      updatedChapters = relationshipRepair.chapters;
      for (final correction in relationshipRepair.corrections) {
        _run.automaticCorrections['book-consistency\u0000${correction.chapterPath}\u0000${correction.blockId}'] =
            correction.toJson();
      }
      if (relationshipRepair.corrections.isNotEmpty) {
        AppLogger.warn(
          'Canonicalized ${relationshipRepair.corrections.length} '
          'unsupported kinship variants.',
          tag: 'book-consistency',
        );
      }
      final int degradedBlockCount = _degradedBlocks.length;
      final degradedDetails = [
        for (final key in _degradedBlocks)
          {
            'block': key.replaceAll('\u0000', ':'),
            'reason': _run.degradedReasons[key]!,
            'fallback': _run.degradedFallbacks[key]!,
          },
      ];
      if (degradedBlockCount > 0) {
        // Scoped keys use \u0000 as the separator; render it readably.
        final String degradedBlockSample = _degradedBlocks
            .take(20)
            .map(
              (String key) =>
                  '${key.replaceAll('\u0000', ':')} '
                  '(${_run.degradedReasons[key]}; '
                  '${_run.degradedFallbacks[key] == 'partialTranslation' ? (s.isChinese ? '保留待复核译文' : 'partial translation retained; needs review') : (s.isChinese ? '保留原文' : 'source retained')})',
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
            final translatedBodyTitle =
                BookTitleConsistency.translatedBodyTitle(
                  metadataTitle: originalTitle,
                  chapters: updatedChapters,
                  sourceHints: _run.sourceHints,
                );
            translatedTitle = await _translateBookTitle(
              dio: dio,
              config: config,
              originalTitle: originalTitle,
              translatedBodyTitle: translatedBodyTitle,
              inputFingerprint: inputFingerprint,
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
      final reviewSnapshots = <String, Object?>{};
      final sourceLanguages = config.semanticQualityCheck
          ? await EpubIsolateWorker.readBookLanguages(
              inputPath,
              expectedSourceFingerprint: sourceIdentityForChapters(
                chapters,
              )?.sha256,
            )
          : null;
      await _repacker.writeTranslatedEpub(
        reviewSnapshots: reviewSnapshots,
        reviewChapterPaths: {
          if (config.semanticQualityCheck)
            ...selectedChapters.map((c) => c.path),
          ..._degradedBlocks.map((key) => key.split('\u0000').first),
        },
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
      for (final detail in degradedDetails) {
        final scoped = _degradedBlocks.firstWhere(
          (key) => key.replaceAll('\u0000', ':') == detail['block'],
        );
        final parts = scoped.split('\u0000');
        final snapshot = reviewSnapshots[parts.first];
        final states = snapshot is Map ? snapshot['finalDegradedBlocks'] : null;
        detail['processingFallback'] = detail['fallback']!;
        detail['finalContentState'] = states is Map
            ? states[parts.last]?.toString() ?? 'unknown'
            : 'unknown';
      }

      final bool allBlocksDegraded =
          totalBlocks > 0 && degradedBlockCount >= totalBlocks;
      final bool hasWarnings =
          degradedBlockCount > 0 ||
          titleTranslationFailed ||
          _run.semanticUnreviewed.isNotEmpty ||
          _run.semanticCorrections.isNotEmpty ||
          _run.consistencyFindings.isNotEmpty;
      final TranslationJobStatus terminalStatus = allBlocksDegraded
          ? TranslationJobStatus.failed
          : hasWarnings
          ? TranslationJobStatus.completedWithWarnings
          : TranslationJobStatus.completed;
      final apiUsage =
          (TranslationApiMetrics()
                ..add(_apiClient.metricsFor(dio))
                ..add(_run.styleMetrics))
              .toJson();
      TranslationJob terminalJob = currentJob.copyWith(
        apiUsage: apiUsage,
        elapsedMilliseconds: translationStopwatch.elapsedMilliseconds,
        qualityReportPath: null,
        reviewSuggestionCount: _run.semanticCorrections.length,
        consistencyWarningCount: _run.consistencyFindings.length,
        unreviewedBlockCount: _run.semanticUnreviewed.length,
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
      final degradedByChapter = _countBlocksByChapter(_degradedBlocks);
      final reviewWarningsByChapter = _countBlocksByChapter({
        ..._run.semanticUnreviewed,
        ..._run.consistencyFindings.keys,
        for (final item in _run.semanticCorrections)
          if (item case {'chapter': final String path, 'id': final String id})
            EpubRepacker.degradedKeyForBlock(chapterPath: path, blockId: id),
      });
      for (var index = 0; index < updatedChapters.length; index++) {
        final chapter = updatedChapters[index];
        updatedChapters[index] = chapter.copyWith(
          originalHtml:
              chapter.sourceIdentity != null && chapter.includeInTranslation
              ? ''
              : chapter.originalHtml,
          degradedBlockCount: degradedByChapter[chapter.path] ?? 0,
          reviewWarningBlockCount: reviewWarningsByChapter[chapter.path] ?? 0,
        );
      }
      committedResult = TranslationRunResult(
        job: terminalJob,
        chapters: updatedChapters,
        apiUsage: apiUsage,
        qualityReportPath: null,
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
      final usage = committedResult.apiUsage;
      try {
        final diagnostics = File('$outputFilePath.diagnostics.json');
        // A successful retry can overwrite the same EPUB. Clear old warning
        // records too, so its sidecar cannot describe the previous run.
        if (degradedDetails.isNotEmpty || await diagnostics.exists()) {
          await writeFileAtomically(
            diagnostics,
            const JsonEncoder.withIndent(
              '  ',
            ).convert({'version': 2, 'degradedBlocks': degradedDetails}),
          );
        }
      } catch (error) {
        AppLogger.warn(
          'Translation diagnostics write failed (${error.runtimeType}).',
          tag: 'translate',
        );
      }
      emit(
        terminalJob,
        s.isChinese
            ? 'API 全流程统计：${usage['requests']} 次请求，${_apiRequestBreakdown(usage)}；输入 ${usage['promptTokens']} / 输出 ${usage['completionTokens']} tokens；累计请求耗时 ${usage['elapsedMs']}ms（含风格、记忆、正文、复核、书名及重试）。'
            : 'API totals: ${jsonEncode(usage)} (style, memory, body, review, title and retries).',
      );
      if (config.semanticQualityCheck) {
        try {
          await writeFileAtomically(
            File('$outputFilePath.quality.json'),
            const JsonEncoder.withIndent('  ').convert({
              'version': 2,
              'outputPath': outputFilePath,
              'reviewScope': config.semanticReviewScope.name,
              'reservedTokens': _run.semanticReservedTokens,
              'tokenLimit': config.maxSemanticReviewTokens,
              'reviewedBlocks': _run.semanticReviewed.length,
              'skippedLowRiskBlocks': _run.semanticSkipped.length,
              'findings': [
                for (final e in _run.consistencyFindings.entries)
                  {'block': e.key.replaceAll('\u0000', ':'), 'checks': e.value},
              ],
              'rendering': {
                'completeSnapshot': true,
                'bilingual': config.bilingual,
                'targetLanguage': config.targetLanguage,
                'sourceLanguages': sourceLanguages,
                'lockedGlossary': config.lockedGlossary,
                'residualQualityCheck': config.residualQualityCheck,
                'chapters': reviewSnapshots,
              },
              'complete':
                  _run.semanticUnreviewed.isEmpty && _degradedBlocks.isEmpty,
              'degradedBlocks': _degradedBlocks
                  .map((id) => id.replaceAll('\u0000', ':'))
                  .toList(),
              'degradedDetails': degradedDetails,
              'requests': _run.semanticRequests,
              'requestLimit': config.maxSemanticReviewRequests,
              'corrections': _run.semanticCorrections,
              'automaticCorrections': _run.automaticCorrections.values.toList(),
              'meaningAssessments': _run.meaningAssessments.values.toList(),
              'autoApplyVerifiedCorrections':
                  config.autoApplyVerifiedCorrections,
              'missingEntityTerms': config.autoApplyVerifiedCorrections
                  ? _memory.missingEntityTerms(bookMemory ?? _BookMemory.empty)
                  : const <String>[],
              'auditSampleBlocks': _run.semanticAuditSamples.length,
              'draftReusedBlocks': _run.reusedDraftBlocks.length,
              'unreviewedReasons': {
                for (final e in _run.semanticUnreviewedReasons.entries)
                  e.key.replaceAll('\u0000', ':'): e.value,
              },
              'unreviewedDetails': {
                for (final e in _run.semanticFailureDetails.entries)
                  if (_run.semanticUnreviewed.contains(e.key))
                    e.key.replaceAll('\u0000', ':'): e.value,
              },
              'unreviewed': _run.semanticUnreviewed
                  .map((id) => id.replaceAll('\u0000', ':'))
                  .toList(),
              'apiUsage': usage,
            }),
          );
          terminalJob = terminalJob.copyWith(
            qualityReportPath: '$outputFilePath.quality.json',
          );
          committedResult = TranslationRunResult(
            job: terminalJob,
            chapters: updatedChapters,
            apiUsage: apiUsage,
            qualityReportPath: '$outputFilePath.quality.json',
          );
          emit(
            terminalJob,
            s.isChinese
                ? '语义复核：${_run.semanticRequests} 次请求，${_run.semanticCorrections.length} 条待确认建议，${_run.semanticUnreviewed.length} 个文本块未完成复核。报告：$outputFilePath.quality.json'
                : 'Semantic review: ${_run.semanticRequests} requests, ${_run.semanticCorrections.length} suggestions awaiting approval, ${_run.semanticUnreviewed.length} unreviewed blocks. Report: $outputFilePath.quality.json',
          );
        } catch (error) {
          emit(
            terminalJob,
            s.isChinese
                ? '译本已保存，但复核报告无法写入；本次复核报告不可用。'
                : 'The EPUB was saved, but the review report could not be written and is unavailable for this run.',
          );
          AppLogger.warn(
            'Quality report write failed (${error.runtimeType}).',
            tag: 'translate',
          );
        }
      }
      // Degraded blocks kept their source text (they were billed but not
      // translated), so they must not be counted as "translated" blocks in
      // the performance report.
      final int genuinelyTranslatedBlocks =
          (apiTranslatedBlocks -
                  _apiDegradedBlocks -
                  _run.reusedDraftBlocks.length)
              .clamp(0, apiTranslatedBlocks);
      if (_run.reusedDraftBlocks.isNotEmpty) {
        emit(
          terminalJob,
          s.isChinese
              ? '复用已有草稿 ${_run.reusedDraftBlocks.length} 块；这些块仅补做复核，不计为新翻译。'
              : 'Reused ${_run.reusedDraftBlocks.length} existing drafts for review; excluded from newly translated blocks.',
        );
      }
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
      return committedResult!;
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
      if (dioReady && lastProgressJob != null) {
        try {
          onProgress?.call(
            lastProgressJob!.copyWith(
              apiUsage:
                  (TranslationApiMetrics()
                        ..add(_apiClient.metricsFor(dio))
                        ..add(_run.styleMetrics))
                      .toJson(),
            ),
            config.uiLanguage == UiLanguage.chinese
                ? '任务已中断；已完成请求计入用量统计。'
                : 'Run interrupted; completed requests are included in usage.',
          );
        } catch (_) {
          /* Preserve the original interruption. */
        }
      }
      if (error is TranslationCancelledException) {
        rethrow;
      }
      if (_isCancelError(error)) {
        throw const TranslationCancelledException();
      }
      rethrow;
    } finally {
      await cacheSpool.dispose();
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
    void Function(String html, String text)? onLocked,
  }) => _EpubResponseDomLocker._lockAndValidateTranslatedBlock(
    config: config,
    block: block,
    translatedHtml: translatedHtml,
    instrumentation: instrumentation,
    rejectEmptyResponse: rejectEmptyResponse,
    onLocked: onLocked,
  );

  static String _lockAndValidateTranslatedBlockDom({
    required TranslationConfig config,
    required ExtractedBlock block,
    required _ResponseHtml replyDom,
    Map<String, int>? instrumentation,
    void Function(String html, String text)? onLocked,
  }) => _EpubResponseDomLocker._lockAndValidateTranslatedBlockDom(
    config: config,
    block: block,
    replyDom: replyDom,
    instrumentation: instrumentation,
    onLocked: onLocked,
  );

  static String _lockHtmlStructure({
    required String sourceHtml,
    required String translatedHtml,
    Map<String, int>? instrumentation,
  }) => _EpubResponseDomLocker._lockHtmlStructure(
    sourceHtml: sourceHtml,
    translatedHtml: translatedHtml,
    instrumentation: instrumentation,
  );

  static _ResponseHtml _cleanResponseDom(
    String response, {
    required String sourceText,
    Map<String, int>? instrumentation,
    bool rejectEmptyResponse = false,
  }) => _EpubResponseDomLocker._cleanResponseDom(
    response,
    sourceText: sourceText,
    instrumentation: instrumentation,
    rejectEmptyResponse: rejectEmptyResponse,
  );

  static void _validateTranslatedBlockQuality({
    required TranslationConfig config,
    required ExtractedBlock block,
    required _ResponseHtml sourceDom,
    required _ResponseHtml translatedDom,
  }) => _EpubResponseDomLocker._validateTranslatedBlockQuality(
    config: config,
    block: block,
    sourceDom: sourceDom,
    translatedDom: translatedDom,
  );

  static bool _htmlStructureMatches(String sourceHtml, String translatedHtml) =>
      _EpubResponseDomLocker._htmlStructureMatches(sourceHtml, translatedHtml);

  /// Test-visible detector used by individual protected-slot translation.
  @visibleForTesting
  static bool slotTranslationHasWrapperTag(String text) =>
      _EpubTranslationStrategy._slotWrapperTagPattern.hasMatch(text);

  static InspectedChapter _prepareChapterForTarget(
    InspectedChapter chapter, {
    required String targetLanguage,
  }) => _EpubResponseDomLocker._prepareChapterForTarget(
    chapter,
    targetLanguage: targetLanguage,
  );

  static String _prepareBlockHtmlForTarget({
    required String sourceHtml,
    required String targetLanguage,
  }) => _EpubResponseDomLocker._prepareBlockHtmlForTarget(
    sourceHtml: sourceHtml,
    targetLanguage: targetLanguage,
  );

  static String normalizeTargetLanguage(String language) =>
      _EpubResponseDomLocker.normalizeTargetLanguage(language);

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
  }) => _EpubTranslationStrategy._blockContextSummary(
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
  }) => _previewBodyFromBlocks(blocks, fallback: fallback);

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
      final RegExpMatch? literal = RegExp(
        r'^<([A-Za-z])>$',
      ).firstMatch(match.group(0)!);
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
    String? translatedBodyTitle,
    String inputFingerprint = '',
    CancelToken? cancelToken,
  }) async {
    if (titleAlreadyInTargetLanguage(originalTitle, config.targetLanguage)) {
      return null;
    }
    if (translatedBodyTitle != null && translatedBodyTitle.trim().isNotEmpty) {
      final clean = _cleanBookTitle(translatedBodyTitle, checkHtmlTags: false);
      validateEpubXmlCharacters(clean);
      if (clean != originalTitle.trim()) return clean;
    }
    final key = TranslationArtifactCache.key(config, 'book-title-v3', [
      inputFingerprint,
      originalTitle,
    ]);
    final cached = await _artifactCache.read(key);
    if (cached?['title'] case final String title) {
      try {
        final clean = _cleanBookTitle(title, checkHtmlTags: false);
        validateEpubXmlCharacters(clean);
        return clean == originalTitle.trim() ? null : clean;
      } on FormatException {
        /* A corrupt semantic value is a cache miss. */
      }
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
    validateEpubXmlCharacters(translated);
    await _artifactCache.write(key, {'title': translated});
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

  static String _apiRequestBreakdown(Map<String, Object> usage) {
    const labels = {
      'styleProfile': '风格',
      'initialBookMemory': '初始记忆',
      'chapterMemory': '章节记忆',
      'chapterMemoryBatch': '批量章节记忆',
      'bodyRepair': '正文补译',
      'translation': '正文',
      'semanticReview': '语义复核',
      'semanticSourceAnalysis': '原文释义',
      'semanticDraftAnalysis': '独立译文释义',
      'semanticEquivalence': '含义等价核对',
      'semanticReviewRepair': '有限审校修复',
      'semanticVerification': '修正验证',
      'bookTitle': '书名',
      'probe': '连接测试',
    };
    final byKind = usage['byKind'] as Map;
    return byKind.isEmpty
        ? '全部缓存命中'
        : byKind.entries
              .map((e) => '${labels[e.key] ?? e.key} ${e.value} 次')
              .join('，');
  }

  String _safeErrorText(Object error, TranslationConfig config) {
    return SensitiveText.redact(
      error.toString(),
      configuredApiKey: config.apiKey,
    );
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
  }) => _EpubTranslatorPaths.outputFilePath(
    inputPath: inputPath,
    outputDirectory: outputDirectory,
    suffix: suffix,
  );

  static const int outputPathSuffixBudget =
      _EpubTranslatorPaths.outputPathSuffixBudget;

  @visibleForTesting
  static String outputFileNameForTest(
    String baseName,
    String suffix, {
    bool? windows,
  }) => outputFileName(baseName, suffix, windows: windows);

  static String outputFileName(
    String baseName,
    String suffix, {
    bool? windows,
  }) => _EpubTranslatorPaths.outputFileName(baseName, suffix, windows: windows);

  @visibleForTesting
  static Future<void> validateOutputDirectory(
    String directory,
    UiLanguage language,
  ) => _EpubTranslatorPaths.validateOutputDirectory(directory, language);

  @visibleForTesting
  static bool outputPathExceedsWindowsMaxPath(String outputFilePath) =>
      _EpubTranslatorPaths.outputPathExceedsWindowsMaxPath(outputFilePath);

  static Future<void> throwIfOutputPathTooLongForWindows(
    String outputFilePath, {
    Future<bool?> Function()? longPathsEnabledReader,
  }) => _EpubTranslatorPaths.throwIfOutputPathTooLongForWindows(
    outputFilePath,
    longPathsEnabledReader: longPathsEnabledReader,
  );

  @visibleForTesting
  static String preRunProbeErrorMessage(
    FileSystemException error,
    AppStrings strings,
    String outputFilePath,
  ) => _EpubTranslatorPaths.preRunProbeErrorMessage(
    error,
    strings,
    outputFilePath,
  );

  static String _normalizeInputPathForCache(String inputPath) =>
      _EpubTranslatorPaths._normalizeInputPathForCache(inputPath);

  Future<String> _inputFingerprint(
    String inputPath, {
    String? expectedSourceFingerprint,
    required CancelToken cancelToken,
  }) => _EpubTranslatorPaths.inputFingerprint(
    inputPath,
    expectedSourceFingerprint: expectedSourceFingerprint,
    cancelToken: cancelToken,
    throwIfCancelled: _run.throwIfCancelled,
  );

  String _jobKey({
    required String inputFingerprint,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
  }) => _EpubTranslatorPaths.jobKey(
    apiClient: _apiClient,
    inputFingerprint: inputFingerprint,
    config: config,
    chapters: chapters,
    confirmedStyleProfile: confirmedStyleProfile,
  );

  String _blockCacheKey(
    TranslationConfig config,
    ExtractedBlock block, {
    required String chapterPath,
    required String inputFingerprint,
    String contextIdentity = '',
    TranslationStyleProfile? confirmedStyleProfile,
  }) => _EpubTranslatorPaths.blockCacheKey(
    _apiClient,
    config,
    block,
    chapterPath: chapterPath,
    inputFingerprint: inputFingerprint,
    contextIdentity: contextIdentity,
    confirmedStyleProfile: confirmedStyleProfile,
  );

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

  static Map<String, int> _countBlocksByChapter(Iterable<String> scopedKeys) {
    final counts = <String, int>{};
    for (final key in scopedKeys) {
      final separator = key.indexOf('\u0000');
      if (separator < 0) continue;
      final chapterPath = key.substring(0, separator);
      counts.update(chapterPath, (count) => count + 1, ifAbsent: () => 1);
    }
    return counts;
  }

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
      final String? text;
      try {
        text = _plainTextFromHtml(block.translatedHtml, maxChars: remaining);
      } on FormatException {
        // A UI excerpt must not abort a completed chapter. Full translation
        // and export retain their independent XML/structure validation.
        continue;
      }
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
        : unicodeSafePrefix(html, maxChars * _previewHtmlHeadroomFactor);
    final dom.DocumentFragment fragment = XhtmlHtmlCompatibility.parseFragment(
      boundedHtml,
    );
    String text = (fragment.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (maxChars != null && text.length > maxChars) {
      text = unicodeSafePrefix(text, maxChars).trimRight();
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
