import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;

import '../../../../shared/logging/app_logger.dart';
import '../../../../shared/security/sensitive_text.dart';
import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/job_resume_state.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/models/translation_job.dart';
import '../../domain/models/translation_run_result.dart';
import '../../domain/repositories/translation_repository.dart';
import '../translation_cache_store.dart';
import '../translation_quality.dart';
import 'epub_repacker.dart';
import 'translation_api_client.dart';
import 'translation_batch_planner.dart';

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
  }) : _cacheStore = cacheStore ?? TranslationCacheStore(),
       _repacker = repacker ?? EpubRepacker(),
       _apiClient = apiClient ?? const TranslationApiClient(),
       _batchPlanner = batchPlanner ?? const TranslationBatchPlanner();

  final TranslationCacheStore _cacheStore;
  final EpubRepacker _repacker;
  final TranslationApiClient _apiClient;
  final TranslationBatchPlanner _batchPlanner;

  static const String _cacheSchemaVersion = 'v6-glossary-and-path-keys';
  static const int _initialMemoryFrontMatterLimit = 2;
  static const int _initialMemoryContentLimit = 2;
  static const int _memoryChapterTextLimit = 2400;
  static const int _memoryListLimit = 8;
  static const int _memoryGlossaryLimit = 32;
  static const int _recentChapterMemoryLimit = 2;

  static bool shouldFallbackBatchDioExceptionForTest(DioException error) {
    return TranslationApiClient.shouldFallbackBatchDioException(error);
  }

  static String sanitizeOutputSuffixForTest(String suffix) {
    return TranslationApiClient.sanitizeOutputSuffix(suffix);
  }

  static String blockCacheKeyForTest({
    required TranslationConfig config,
    required ExtractedBlock block,
    required String chapterPath,
  }) {
    return EpubChapterTranslator()._blockCacheKey(
      config,
      block,
      chapterPath: chapterPath,
    );
  }

  static String jobKeyForTest({
    required String inputFingerprint,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
  }) {
    return EpubChapterTranslator()._jobKey(
      inputFingerprint: inputFingerprint,
      config: config,
      chapters: chapters,
    );
  }

  static String normalizeInputPathForCacheForTest(String inputPath) {
    return _normalizeInputPathForCache(inputPath);
  }

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
  }) {
    return _lockHtmlStructure(
      sourceHtml: sourceHtml,
      translatedHtml: translatedHtml,
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

  Future<List<String>> translateBlockBatchForTest({
    required Dio dio,
    required TranslationConfig config,
    required List<ExtractedBlock> blocks,
    String chapterTitle = '',
    List<ExtractedBlock> contextBefore = const <ExtractedBlock>[],
    List<ExtractedBlock> contextAfter = const <ExtractedBlock>[],
    Map<String, Object?>? bookMemory,
  }) {
    return _translateBlockBatch(
      dio: dio,
      config: config,
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
    );
  }

  Future<Map<String, Object?>> generateInitialBookMemoryForTest({
    required Dio dio,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
  }) async {
    return (await _generateInitialBookMemory(
      dio: dio,
      config: config,
      chapters: chapters,
    )).toJson();
  }

  Future<Map<String, Object?>> updateBookMemoryAfterChapterForTest({
    required Dio dio,
    required TranslationConfig config,
    required Map<String, Object?> currentMemory,
    required InspectedChapter chapter,
  }) async {
    return (await _updateBookMemoryAfterChapter(
      dio: dio,
      config: config,
      currentMemory: _BookMemory.fromJson(currentMemory),
      chapter: chapter,
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
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    try {
      final List<InspectedChapter> selectedChapters = chapters
          .where((InspectedChapter chapter) => chapter.includeInTranslation)
          .toList();
      final int totalBlocks = selectedChapters.fold<int>(
        0,
        (int sum, InspectedChapter chapter) => sum + chapter.blocks.length,
      );

      if (selectedChapters.isEmpty) {
        throw const FormatException(
          'No chapters are selected. Check at least one chapter before starting translation.',
        );
      }
      if (totalBlocks == 0) {
        throw const FormatException(
          'The selected chapters do not contain any translatable text blocks yet.',
        );
      }
      if (config.apiBaseUrl.trim().isEmpty ||
          config.apiKey.trim().isEmpty ||
          config.model.trim().isEmpty) {
        throw const FormatException(
          'API base URL, API key, and model are required before translation can start.',
        );
      }

      final Dio dio = _apiClient.buildDio(config);
      final Stopwatch translationStopwatch = Stopwatch()..start();
      Duration totalApiElapsed = Duration.zero;
      Duration totalCacheWriteElapsed = Duration.zero;
      Duration totalMemoryElapsed = Duration.zero;
      int apiTranslatedBlocks = 0;
      int cacheWriteCount = 0;
      int memoryRequestCount = 0;
      DateTime lastResumeSaveAt = DateTime.now();
      int blocksSinceResumeSave = 0;

      final String jobId = DateTime.now().millisecondsSinceEpoch.toString();
      final String outputFilePath = _outputFilePath(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        suffix: config.outputSuffix,
      );
      final String inputFingerprint = await _inputFingerprint(inputPath);
      final String jobKey = _jobKey(
        inputFingerprint: inputFingerprint,
        config: config,
        chapters: selectedChapters,
      );
      final JobResumeState? previousState = await _cacheStore.loadJobState(
        jobKey,
      );
      TranslationJob currentJob = TranslationJob(
        id: jobId,
        inputPath: inputPath,
        outputPath: outputFilePath,
        status: TranslationJobStatus.running,
        phase: TranslationJobPhase.translation,
        progress: 0,
        currentChapter: 'Preparing translation run',
        completedFiles: 0,
        totalFiles: selectedChapters.length,
        completedBlocks: 0,
        totalBlocks: totalBlocks,
        cachedBlocks: 0,
        resumedBlocks: 0,
      );

      void emit(TranslationJob job, String logLine) {
        currentJob = job;
        onProgress?.call(job, logLine);
        AppLogger.debug(logLine, tag: 'translate');
      }

      void throwIfCancelled() {
        if (cancelToken.isCancelled || (isCancelled?.call() ?? false)) {
          throw const TranslationCancelledException();
        }
      }

      Future<void> saveResumeState(
        TranslationJob job, {
        bool force = false,
      }) async {
        final DateTime now = DateTime.now();
        if (!force &&
            blocksSinceResumeSave < 20 &&
            now.difference(lastResumeSaveAt) < const Duration(seconds: 10)) {
          return;
        }
        await _cacheStore.saveJobState(
          _resumeStateFromJob(
            jobKey: jobKey,
            inputFingerprint: inputFingerprint,
            job: job,
          ),
        );
        lastResumeSaveAt = now;
        blocksSinceResumeSave = 0;
      }

      if (previousState != null) {
        emit(
          currentJob,
          'Found a saved translation checkpoint from ${previousState.updatedAtIso8601}. Cached blocks will be reused before new API calls.',
        );
      }

      emit(
        currentJob,
        'Starting translation for ${selectedChapters.length} chapters and $totalBlocks extracted blocks.',
      );
      await saveResumeState(currentJob, force: true);
      throwIfCancelled();

      final Map<String, InspectedChapter> updatedByPath =
          <String, InspectedChapter>{
            for (final InspectedChapter chapter in chapters)
              chapter.path: chapter,
          };

      _BookMemory? bookMemory;
      bool initialBookMemoryAttempted = false;
      final Map<int, bool> chapterPendingCache = <int, bool>{};

      Future<void> ensureInitialBookMemory() async {
        if (initialBookMemoryAttempted) {
          return;
        }
        initialBookMemoryAttempted = true;
        throwIfCancelled();
        try {
          final Stopwatch memoryStopwatch = Stopwatch()..start();
          final _BookMemory initialMemory = await _generateInitialBookMemory(
            dio: dio,
            config: config,
            chapters: chapters,
            cancelToken: cancelToken,
          );
          bookMemory = initialMemory;
          memoryStopwatch.stop();
          totalMemoryElapsed += memoryStopwatch.elapsed;
          memoryRequestCount += 1;
          if (initialMemory.isEmpty) {
            emit(
              currentJob,
              'Book memory: no useful front matter or early chapter text was found in ${_formatDuration(memoryStopwatch.elapsed)}.',
            );
          } else {
            emit(
              currentJob,
              'Book memory: created initial summary from front matter and early chapters in ${_formatDuration(memoryStopwatch.elapsed)}.',
            );
          }
        } catch (error) {
          emit(
            currentJob,
            'Book memory: initial summary skipped (${_linePreview(_safeErrorText(error, config))}). Translation will continue without whole-book memory until a chapter summary is available.',
          );
        }
      }

      Future<bool> hasPendingBlocksInChapter(int chapterIndex) async {
        final bool? cached = chapterPendingCache[chapterIndex];
        if (cached != null) {
          return cached;
        }
        final InspectedChapter chapter = selectedChapters[chapterIndex];
        for (final ExtractedBlock block in chapter.blocks) {
          throwIfCancelled();
          final String cacheKey = _blockCacheKey(
            config,
            block,
            chapterPath: chapter.path,
          );
          final String? cachedTranslation = await _cacheStore
              .getBlockTranslation(cacheKey);
          if (cachedTranslation == null || cachedTranslation.trim().isEmpty) {
            chapterPendingCache[chapterIndex] = true;
            return true;
          }
        }
        chapterPendingCache[chapterIndex] = false;
        return false;
      }

      Future<bool> hasPendingBlocksFromChapter(int startChapterIndex) async {
        for (
          int index = startChapterIndex;
          index < selectedChapters.length;
          index += 1
        ) {
          if (await hasPendingBlocksInChapter(index)) {
            throwIfCancelled();
            return true;
          }
        }
        return false;
      }

      int completedBlocks = 0;
      int completedFiles = 0;
      int cachedBlocks = 0;
      int resumedBlocks = 0;
      final bool resumingFromCheckpoint = previousState != null;
      try {
        for (
          int chapterIndex = 0;
          chapterIndex < selectedChapters.length;
          chapterIndex += 1
        ) {
          throwIfCancelled();
          final InspectedChapter chapter = selectedChapters[chapterIndex];
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
            'Translating chapter ${chapterIndex + 1}/${selectedChapters.length}: ${chapter.title}',
          );

          final Map<String, ExtractedBlock> translatedById =
              <String, ExtractedBlock>{};
          int chapterCacheHits = 0;
          final List<ExtractedBlock> pendingBlocks = <ExtractedBlock>[];
          for (final ExtractedBlock block in chapter.blocks) {
            throwIfCancelled();
            final String cacheKey = _blockCacheKey(
              config,
              block,
              chapterPath: chapter.path,
            );
            final String? cachedTranslation = await _cacheStore
                .getBlockTranslation(cacheKey);
            if (cachedTranslation == null || cachedTranslation.trim().isEmpty) {
              pendingBlocks.add(block);
              continue;
            }
            translatedById[block.id] = block.copyWith(
              translatedHtml: cachedTranslation,
            );
            chapterCacheHits += 1;
            cachedBlocks += 1;
            if (resumingFromCheckpoint) {
              resumedBlocks += 1;
            }
            completedBlocks += 1;
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
              'Reused $chapterCacheHits cached blocks for ${chapter.title}.',
            );
            blocksSinceResumeSave += chapterCacheHits;
            await saveResumeState(cachedJob);
          }
          chapterPendingCache[chapterIndex] = pendingBlocks.isNotEmpty;

          if (pendingBlocks.isNotEmpty) {
            await ensureInitialBookMemory();
            throwIfCancelled();
          }

          final List<TranslationBlockBatch> batches = _batchPlanner.plan(
            pendingBlocks: pendingBlocks,
            chunkSize: config.chunkSize,
            chapterBlocks: chapter.blocks,
            chapterTitle: chapter.title,
            bookMemory: bookMemory?.toJson(),
          );
          emit(
            currentJob.copyWith(
              currentChapter: chapter.title,
              completedFiles: completedFiles,
              completedBlocks: completedBlocks,
            ),
            'Prepared ${batches.length} batched requests for ${chapter.title}.',
          );

          for (
            int batchStart = 0;
            batchStart < batches.length;
            batchStart += config.maxConcurrent
          ) {
            throwIfCancelled();
            final int batchEnd = min(
              batchStart + config.maxConcurrent,
              batches.length,
            );
            final List<TranslationBlockBatch> batchWindow = batches.sublist(
              batchStart,
              batchEnd,
            );
            final List<_TimedBatchResult> translatedWindow =
                await Future.wait<_TimedBatchResult>(
                  batchWindow.asMap().entries.map((entry) async {
                    final int batchNumber = batchStart + entry.key + 1;
                    final TranslationBlockBatch batch = entry.value;
                    final Stopwatch apiStopwatch = Stopwatch()..start();
                    final List<String> translated = await _translateBlockBatch(
                      dio: dio,
                      config: config,
                      batch: batch,
                      cancelToken: cancelToken,
                    );
                    apiStopwatch.stop();
                    return _TimedBatchResult(
                      batch: batch,
                      translatedBlocks: translated,
                      batchNumber: batchNumber,
                      elapsed: apiStopwatch.elapsed,
                    );
                  }),
                );
            throwIfCancelled();

            for (
              int batchIndex = 0;
              batchIndex < translatedWindow.length;
              batchIndex += 1
            ) {
              throwIfCancelled();
              final _TimedBatchResult timedBatch = translatedWindow[batchIndex];
              final TranslationBlockBatch batch = timedBatch.batch;
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
                'Performance: API batch ${timedBatch.batchNumber}/${batches.length} for ${chapter.title} (${batch.blocks.length} blocks) took ${_formatDuration(timedBatch.elapsed)}.',
              );
              final Stopwatch cacheWriteStopwatch = Stopwatch()..start();
              await Future.wait<void>(<Future<void>>[
                for (int index = 0; index < batch.blocks.length; index += 1)
                  _cacheStore.putBlockTranslation(
                    _blockCacheKey(
                      config,
                      batch.blocks[index],
                      chapterPath: chapter.path,
                    ),
                    translatedBatch[index],
                  ),
              ]);
              cacheWriteStopwatch.stop();
              chapterCacheWriteElapsed += cacheWriteStopwatch.elapsed;
              totalCacheWriteElapsed += cacheWriteStopwatch.elapsed;
              chapterCacheWrites += batch.blocks.length;
              cacheWriteCount += batch.blocks.length;

              for (int index = 0; index < batch.blocks.length; index += 1) {
                throwIfCancelled();
                final ExtractedBlock sourceBlock = batch.blocks[index];
                final ExtractedBlock translatedBlock = sourceBlock.copyWith(
                  translatedHtml: translatedBatch[index],
                );
                translatedById[sourceBlock.id] = translatedBlock;
                completedBlocks += 1;
                blocksSinceResumeSave += 1;
                final TranslationJob nextJob = currentJob.copyWith(
                  progress: completedBlocks / totalBlocks,
                  currentChapter: chapter.title,
                  currentBlock: _linePreview(sourceBlock.sourceText),
                  completedFiles: completedFiles,
                  totalFiles: selectedChapters.length,
                  completedBlocks: completedBlocks,
                  totalBlocks: totalBlocks,
                  cachedBlocks: cachedBlocks,
                  resumedBlocks: resumedBlocks,
                );
                currentJob = nextJob;
                await saveResumeState(nextJob);
              }
              emit(
                currentJob,
                'Translated $completedBlocks/$totalBlocks blocks after batch ${timedBatch.batchNumber}/${batches.length} for ${chapter.title}.',
              );
            }
          }

          completedFiles += 1;
          chapterStopwatch.stop();
          final List<ExtractedBlock> translatedBlocks = chapter.blocks
              .map((ExtractedBlock block) => translatedById[block.id] ?? block)
              .toList();
          updatedByPath[chapter.path] = chapter.copyWith(
            blocks: translatedBlocks,
            body: _previewBodyFromBlocks(
              translatedBlocks,
              fallback: chapter.body,
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
            'Completed chapter $completedFiles/${selectedChapters.length}: ${chapter.title}',
          );
          emit(
            chapterDoneJob,
            'Performance: Chapter ${chapterIndex + 1}/${selectedChapters.length} took ${_formatDuration(chapterStopwatch.elapsed)}. API time ${_formatDuration(chapterApiElapsed)} for $chapterApiBlocks new blocks; block cache writes ${_formatDuration(chapterCacheWriteElapsed)} across $chapterCacheWrites writes; throughput ${_formatBlocksPerMinute(chapterApiBlocks, chapterStopwatch.elapsed)} new blocks/min.',
          );
          throwIfCancelled();
          final bool futurePendingBlocks = await hasPendingBlocksFromChapter(
            chapterIndex + 1,
          );
          if (futurePendingBlocks) {
            await ensureInitialBookMemory();
            try {
              final Stopwatch memoryStopwatch = Stopwatch()..start();
              bookMemory = await _updateBookMemoryAfterChapter(
                dio: dio,
                config: config,
                currentMemory: bookMemory ?? _BookMemory.empty,
                chapter: updatedByPath[chapter.path]!,
                cancelToken: cancelToken,
              );
              memoryStopwatch.stop();
              totalMemoryElapsed += memoryStopwatch.elapsed;
              memoryRequestCount += 1;
              emit(
                chapterDoneJob,
                'Book memory: updated rolling summary after ${chapter.title} in ${_formatDuration(memoryStopwatch.elapsed)}.',
              );
            } catch (error) {
              emit(
                chapterDoneJob,
                'Book memory: chapter summary skipped for ${chapter.title} (${_linePreview(_safeErrorText(error, config))}).',
              );
            }
          } else {
            emit(
              chapterDoneJob,
              'Book memory: skipped chapter summary after ${chapter.title} because no later uncached blocks need it.',
            );
          }
          throwIfCancelled();
          await saveResumeState(chapterDoneJob, force: true);
        }
      } catch (error) {
        final bool cancelled =
            error is TranslationCancelledException || _isCancelError(error);
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
        if (cancelled) {
          throw const TranslationCancelledException();
        }
        rethrow;
      }

      throwIfCancelled();
      emit(
        currentJob.copyWith(
          progress: 0.98,
          currentChapter: 'Repacking EPUB',
          currentBlock: null,
          completedFiles: completedFiles,
          totalFiles: selectedChapters.length,
          completedBlocks: completedBlocks,
          totalBlocks: totalBlocks,
          cachedBlocks: cachedBlocks,
          resumedBlocks: resumedBlocks,
        ),
        'Writing translated XHTML back into the EPUB package.',
      );

      final List<InspectedChapter> updatedChapters = chapters
          .map(
            (InspectedChapter chapter) =>
                updatedByPath[chapter.path] ?? chapter,
          )
          .toList();
      final Stopwatch repackStopwatch = Stopwatch()..start();
      throwIfCancelled();
      await _repacker.writeTranslatedEpub(
        inputPath: inputPath,
        outputFilePath: outputFilePath,
        config: config,
        chapters: updatedChapters,
        cancelToken: cancelToken,
        isCancelled: isCancelled,
      );
      throwIfCancelled();
      repackStopwatch.stop();

      final TranslationJob completedJob = currentJob.copyWith(
        status: TranslationJobStatus.completed,
        progress: 1,
        currentChapter: 'EPUB ready',
        currentBlock: null,
        completedFiles: completedFiles,
        totalFiles: selectedChapters.length,
        completedBlocks: completedBlocks,
        totalBlocks: totalBlocks,
        cachedBlocks: cachedBlocks,
        resumedBlocks: resumedBlocks,
      );
      translationStopwatch.stop();
      emit(
        completedJob,
        'Translation complete. Wrote translated EPUB to $outputFilePath',
      );
      emit(
        completedJob,
        'Performance: Final EPUB repack took ${_formatDuration(repackStopwatch.elapsed)}.',
      );
      emit(
        completedJob,
        'Performance: Translation run took ${_formatDuration(translationStopwatch.elapsed)}. Translated $apiTranslatedBlocks new blocks at ${_formatBlocksPerMinute(apiTranslatedBlocks, translationStopwatch.elapsed)} blocks/min on average, excluding cache and resume hits. Total API time ${_formatDuration(totalApiElapsed)}; book memory ${_formatDuration(totalMemoryElapsed)} across $memoryRequestCount requests; block cache writes ${_formatDuration(totalCacheWriteElapsed)} across $cacheWriteCount writes.',
      );
      await _cacheStore.saveJobState(
        _resumeStateFromJob(
          jobKey: jobKey,
          inputFingerprint: inputFingerprint,
          job: completedJob,
          status: 'completed',
        ),
      );
      return TranslationRunResult(job: completedJob, chapters: updatedChapters);
    } on TranslationCancelledException {
      rethrow;
    } catch (error) {
      if (_isCancelError(error) || (isCancelled?.call() ?? false)) {
        throw const TranslationCancelledException();
      }
      rethrow;
    }
  }

  Future<String> _translateBlock({
    required Dio dio,
    required TranslationConfig config,
    required ExtractedBlock block,
    CancelToken? cancelToken,
  }) async {
    Object? lastError;
    for (int attempt = 1; ; attempt += 1) {
      try {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        final Map<String, dynamic> requestData = <String, dynamic>{
          'model': config.model,
          'temperature': 0.2,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content':
                  'You translate EPUB HTML fragments into ${config.targetLanguage}. Preserve every HTML tag, attribute, inline emphasis, entity, and link target. Translate only human-readable text nodes. Return only the translated HTML fragment with no markdown fences and no explanation.${_apiClient.lockedGlossaryInstruction(config)}',
            },
            <String, String>{'role': 'user', 'content': block.sourceHtml},
          ],
        };
        final Response<dynamic> response = await _apiClient.postChatCompletions(
          dio: dio,
          data: requestData,
          cancelToken: cancelToken,
        );

        final String cleaned = _apiClient
            .extractMessageContent(response.data)
            .trim();
        if (cleaned.isEmpty) {
          throw const FormatException(
            'The translation API returned an empty block.',
          );
        }
        final String locked = _lockTranslatedHtmlStructure(block, cleaned);
        _validateTranslatedBlockQuality(
          config: config,
          block: block,
          translatedHtml: locked,
        );
        return locked;
      } catch (error) {
        if (_isCancelError(error) || error is TranslationCancelledException) {
          throw const TranslationCancelledException();
        }
        lastError = error;
        if (attempt >=
            TranslationApiClient.maxAttemptsForError(config, error)) {
          break;
        }
        await TranslationApiClient.delayUnlessCancelled(
          TranslationApiClient.retryDelayForError(config, error, attempt),
          cancelToken: cancelToken,
        );
      }
    }
    if (lastError is DioException && lastError.error is HandshakeException) {
      final String host = Uri.parse(
        _apiClient.normalizedBaseUrl(config.apiBaseUrl),
      ).host;
      throw StateError(
        'TLS handshake failed while connecting to $host. The API endpoint may be blocked on this network, require a proxy/VPN, or be interrupted by certificate inspection.',
      );
    }
    throw StateError(
      'Translation failed after ${config.maxRetries} attempts: $lastError',
    );
  }

  Future<_BookMemory> _generateInitialBookMemory({
    required Dio dio,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
  }) async {
    final List<Map<String, String>> sourceChapters =
        _initialMemorySourceChapters(chapters);
    if (sourceChapters.isEmpty) {
      return _BookMemory.empty;
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'kind': 'initialBookMemory',
      'targetLanguage': config.targetLanguage,
      'chapters': sourceChapters,
    };
    final Map<String, dynamic> jsonPayload = await _requestMemoryJson(
      dio: dio,
      config: config,
      payload: payload,
      systemPrompt:
          'Create a compact translation memory for an EPUB before chapter translation begins. Return strict JSON only with keys: bookSummary, styleGuide, glossary, recentChapters. Keep bookSummary under 120 words. styleGuide is a short string array. glossary is an array of objects with source and target. recentChapters should be empty for the initial memory. Write target terms and notes for ${config.targetLanguage}.',
      cancelToken: cancelToken,
    );
    return _BookMemory.fromJson(jsonPayload);
  }

  Future<_BookMemory> _updateBookMemoryAfterChapter({
    required Dio dio,
    required TranslationConfig config,
    required _BookMemory currentMemory,
    required InspectedChapter chapter,
    CancelToken? cancelToken,
  }) async {
    final String chapterText = _chapterMemoryText(
      chapter,
      preferTranslated: true,
    );
    if (chapterText.isEmpty) {
      return currentMemory;
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'kind': 'chapterMemory',
      'targetLanguage': config.targetLanguage,
      'bookMemory': currentMemory.toJson(),
      'chapter': <String, String>{
        'title': chapter.title,
        'category': chapter.category.name,
        'text': chapterText,
      },
    };
    final Map<String, dynamic> jsonPayload = await _requestMemoryJson(
      dio: dio,
      config: config,
      payload: payload,
      systemPrompt:
          'Summarize the just-translated EPUB chapter into rolling translation memory. Return strict JSON only with keys: title, summary, continuityNotes, glossary. Keep summary under 100 words. continuityNotes is a short string array focused on unresolved plot, tone, names, and terminology for later chapters. glossary is an array of objects with source and target. Write notes for ${config.targetLanguage}.',
      cancelToken: cancelToken,
    );
    return currentMemory.mergeChapter(_ChapterMemory.fromJson(jsonPayload));
  }

  Future<Map<String, dynamic>> _requestMemoryJson({
    required Dio dio,
    required TranslationConfig config,
    required Map<String, dynamic> payload,
    required String systemPrompt,
    CancelToken? cancelToken,
  }) {
    return _apiClient.runRetried<Map<String, dynamic>>(
      config: config,
      shouldRetry: TranslationApiClient.shouldRetryBatchError,
      cancelToken: cancelToken,
      operation: () async {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        final Response<dynamic> response = await _apiClient.postChatCompletions(
          dio: dio,
          data: <String, dynamic>{
            'model': config.model,
            'temperature': 0.1,
            'max_tokens': 900,
            'messages': <Map<String, String>>[
              <String, String>{'role': 'system', 'content': systemPrompt},
              <String, String>{'role': 'user', 'content': jsonEncode(payload)},
            ],
          },
          cancelToken: cancelToken,
        );
        return _apiClient.decodeJsonObject(
          _apiClient.extractMessageContent(response.data),
        );
      },
    );
  }

  static List<Map<String, String>> _initialMemorySourceChapters(
    List<InspectedChapter> chapters,
  ) {
    final List<InspectedChapter> eligibleChapters = chapters
        .where((InspectedChapter chapter) => chapter.includeInTranslation)
        .toList(growable: false);
    final List<InspectedChapter> selected = <InspectedChapter>[];

    void addChapter(InspectedChapter chapter) {
      if (selected.any(
        (InspectedChapter selectedChapter) =>
            selectedChapter.path == chapter.path,
      )) {
        return;
      }
      selected.add(chapter);
    }

    for (final InspectedChapter chapter
        in eligibleChapters
            .where(
              (InspectedChapter chapter) =>
                  chapter.category == ChapterCategory.frontMatter,
            )
            .take(_initialMemoryFrontMatterLimit)) {
      addChapter(chapter);
    }
    for (final InspectedChapter chapter
        in eligibleChapters
            .where(
              (InspectedChapter chapter) =>
                  chapter.category == ChapterCategory.content,
            )
            .take(_initialMemoryContentLimit)) {
      addChapter(chapter);
    }
    if (selected.isEmpty) {
      for (final InspectedChapter chapter in eligibleChapters.take(
        _initialMemoryFrontMatterLimit + _initialMemoryContentLimit,
      )) {
        addChapter(chapter);
      }
    }

    return selected
        .map(
          (InspectedChapter chapter) => <String, String>{
            'title': chapter.title,
            'category': chapter.category.name,
            'text': _chapterMemoryText(chapter),
          },
        )
        .where((Map<String, String> chapter) => chapter['text']!.isNotEmpty)
        .toList(growable: false);
  }

  static String _chapterMemoryText(
    InspectedChapter chapter, {
    bool preferTranslated = false,
  }) {
    final String text = chapter.blocks
        .map<String>((ExtractedBlock block) {
          final String? translatedHtml = block.translatedHtml;
          if (preferTranslated &&
              translatedHtml != null &&
              translatedHtml.trim().isNotEmpty) {
            return _plainTextFromHtmlFragment(translatedHtml);
          }
          return block.sourceText;
        })
        .where((String value) => value.trim().isNotEmpty)
        .join('\n');
    return _trimMemoryText(text);
  }

  static String _plainTextFromHtmlFragment(String value) {
    return html_parser.parseFragment(value).text ?? '';
  }

  static String _trimMemoryText(String value) {
    final String collapsed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= _memoryChapterTextLimit) {
      return collapsed;
    }
    return '${collapsed.substring(0, _memoryChapterTextLimit - 3)}...';
  }

  static String _lockTranslatedHtmlStructure(
    ExtractedBlock block,
    String translatedHtml,
  ) {
    return _lockHtmlStructure(
      sourceHtml: block.sourceHtml,
      translatedHtml: translatedHtml,
    );
  }

  static String _lockHtmlStructure({
    required String sourceHtml,
    required String translatedHtml,
  }) {
    final String trimmedTranslation = translatedHtml.trim();
    if (_htmlStructureMatches(sourceHtml, trimmedTranslation)) {
      return _restoreProtectedTexts(
        sourceHtml: sourceHtml,
        translatedHtml: trimmedTranslation,
      );
    }

    final dom.Element? sourceRoot = _singleRootElement(sourceHtml);
    if (sourceRoot == null) {
      return trimmedTranslation;
    }
    final dom.Element rebuiltRoot = sourceRoot.clone(true);
    final List<_HtmlTextSlot> sourceSlots = _textSlots(rebuiltRoot);
    if (sourceSlots.isEmpty) {
      return rebuiltRoot.outerHtml;
    }

    final List<_HtmlTextSlot> translatedSlots = _textSlotsInFragment(
      trimmedTranslation,
    );
    final List<String> translatedTexts = translatedSlots
        .map((_HtmlTextSlot slot) => slot.text)
        .where((String text) => text.isNotEmpty)
        .toList(growable: false);

    if (translatedTexts.length == sourceSlots.length) {
      for (int index = 0; index < sourceSlots.length; index += 1) {
        if (sourceSlots[index].protected) {
          continue;
        }
        sourceSlots[index].text = translatedTexts[index];
      }
      return rebuiltRoot.outerHtml;
    }

    final List<String> protectedTexts = sourceSlots
        .where((_HtmlTextSlot slot) => slot.protected)
        .map((_HtmlTextSlot slot) => slot.text.trim())
        .where((String text) => text.isNotEmpty)
        .toList(growable: false);
    final String translatedPlainText = _plainTextFromHtmlFragment(
      trimmedTranslation,
    );
    final List<_HtmlTextSlot> translatableSourceSlots = sourceSlots
        .where((_HtmlTextSlot slot) => !slot.protected)
        .toList(growable: false);
    final List<String>? splitText = _splitAroundProtectedMarkers(
      translatedPlainText,
      protectedTexts,
    );
    if (splitText != null &&
        splitText.length == translatableSourceSlots.length) {
      for (int index = 0; index < translatableSourceSlots.length; index += 1) {
        translatableSourceSlots[index].text = splitText[index];
      }
      return rebuiltRoot.outerHtml;
    }

    final String plainTranslation = _removeProtectedMarkers(
      translatedPlainText,
      protectedTexts,
    );
    bool wroteMainText = false;
    for (final _HtmlTextSlot slot in sourceSlots) {
      if (slot.protected) {
        continue;
      }
      if (!wroteMainText) {
        slot.text = plainTranslation;
        wroteMainText = true;
      } else {
        slot.text = '';
      }
    }
    if (!wroteMainText) {
      sourceSlots.first.text = plainTranslation;
    }
    return rebuiltRoot.outerHtml;
  }

  static String _restoreProtectedTexts({
    required String sourceHtml,
    required String translatedHtml,
  }) {
    final dom.Element? sourceRoot = _singleRootElement(sourceHtml);
    final dom.Element? translatedRoot = _singleRootElement(translatedHtml);
    if (sourceRoot == null || translatedRoot == null) {
      return translatedHtml;
    }

    final List<_HtmlTextSlot> sourceSlots = _textSlots(sourceRoot);
    final List<_HtmlTextSlot> translatedSlots = _textSlots(translatedRoot);
    if (sourceSlots.length != translatedSlots.length) {
      return translatedHtml;
    }

    for (int index = 0; index < sourceSlots.length; index += 1) {
      if (sourceSlots[index].protected) {
        translatedSlots[index].text = sourceSlots[index].text;
      }
    }
    return translatedRoot.outerHtml;
  }

  static bool _htmlStructureMatches(String sourceHtml, String translatedHtml) {
    final dom.Element? sourceRoot = _singleRootElement(sourceHtml);
    final dom.Element? translatedRoot = _singleRootElement(translatedHtml);
    if (sourceRoot == null || translatedRoot == null) {
      return false;
    }
    return _elementStructureMatches(sourceRoot, translatedRoot);
  }

  static dom.Element? _singleRootElement(String fragmentHtml) {
    final dom.DocumentFragment fragment = html_parser.parseFragment(
      fragmentHtml,
    );
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

  static List<_HtmlTextSlot> _textSlotsInFragment(String html) {
    final dom.DocumentFragment fragment = html_parser.parseFragment(html);
    final List<_HtmlTextSlot> slots = <_HtmlTextSlot>[];
    for (final dom.Node node in fragment.nodes) {
      _collectTextSlots(node, slots, protected: false);
    }
    return slots;
  }

  static List<_HtmlTextSlot> _textSlots(dom.Node root) {
    final List<_HtmlTextSlot> slots = <_HtmlTextSlot>[];
    _collectTextSlots(root, slots, protected: false);
    return slots;
  }

  static void _collectTextSlots(
    dom.Node node,
    List<_HtmlTextSlot> slots, {
    required bool protected,
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
    final bool childProtected = protected || _isProtectedTextElement(node);
    for (final dom.Node child in node.nodes) {
      _collectTextSlots(child, slots, protected: childProtected);
    }
  }

  static bool _isProtectedTextElement(dom.Element element) {
    final String tag = element.localName ?? '';
    final String role = element.attributes['role']?.toLowerCase() ?? '';
    final Set<String> epubTypes = _epubTypes(element);

    if (role == 'doc-noteref' || epubTypes.contains('noteref')) {
      return true;
    }
    if (role == 'doc-pagebreak' || epubTypes.contains('pagebreak')) {
      return _isProtectedPagebreakText(element.text);
    }
    final String href = element.attributes['href'] ?? '';
    return tag == 'a' &&
        href.startsWith('#') &&
        _isProtectedMarkerText(element.text);
  }

  static Set<String> _epubTypes(dom.Element element) {
    return (element.attributes['epub:type']?.toLowerCase() ?? '')
        .split(RegExp(r'\s+'))
        .where((String type) => type.isNotEmpty)
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
    return RegExp(r'^[\[\(（【].+[\]\)）】]$').hasMatch(compact) ||
        RegExp(r'^[0-9]+[.)]?$').hasMatch(compact) ||
        RegExp(r'^[*†‡§¶]+$').hasMatch(compact) ||
        compact == '↩';
  }

  static List<String>? _splitAroundProtectedMarkers(
    String value,
    List<String> protectedTexts,
  ) {
    if (protectedTexts.isEmpty) {
      return null;
    }

    String remaining = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    final List<String> parts = <String>[];
    for (final String marker in protectedTexts) {
      if (marker.isEmpty) {
        continue;
      }
      final List<int>? markerRange = _protectedMarkerRange(remaining, marker);
      if (markerRange == null) {
        return null;
      }
      parts.add(remaining.substring(0, markerRange[0]));
      remaining = remaining.substring(markerRange[1]);
    }
    parts.add(remaining);
    return parts;
  }

  static String _removeProtectedMarkers(
    String value,
    Iterable<String> protectedTexts,
  ) {
    String result = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final String marker in protectedTexts) {
      if (marker.isEmpty) {
        continue;
      }
      final List<int>? markerRange = _protectedMarkerRange(result, marker);
      if (markerRange == null) {
        continue;
      }
      result =
          result.substring(0, markerRange[0]) +
          result.substring(markerRange[1]);
    }
    return result.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<int>? _protectedMarkerRange(String value, String marker) {
    final int exactIndex = value.indexOf(marker);
    if (exactIndex >= 0) {
      return <int>[exactIndex, exactIndex + marker.length];
    }

    if (!RegExp(r'^[\[\(（【].+[\]\)）】]$').hasMatch(marker)) {
      return null;
    }
    final RegExpMatch? translatedMarkerMatch = RegExp(
      r'[\[\(（【][^\]\)）】]{1,10}[\]\)）】]',
    ).firstMatch(value);
    if (translatedMarkerMatch == null ||
        !_isProtectedMarkerText(translatedMarkerMatch.group(0)!)) {
      return null;
    }
    return <int>[translatedMarkerMatch.start, translatedMarkerMatch.end];
  }

  Future<List<String>> _translateBlockBatch({
    required Dio dio,
    required TranslationConfig config,
    required TranslationBlockBatch batch,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
  }) async {
    final Map<String, dynamic> payloadMap = <String, dynamic>{
      if (!batch.context.isEmpty) 'context': batch.context.toJson(),
      'blocks': batch.blocks
          .map(
            (ExtractedBlock block) => <String, String>{
              'id': block.id,
              'html': block.sourceHtml,
            },
          )
          .toList(),
    };
    final String payload = jsonEncode(payloadMap);

    try {
      return await _apiClient.runRetried<List<String>>(
        config: config,
        retryDelayOverride: retryDelayOverride,
        shouldRetry: TranslationApiClient.shouldRetryBatchError,
        cancelToken: cancelToken,
        operation: () async {
          if (cancelToken?.isCancelled ?? false) {
            throw const TranslationCancelledException();
          }
          final Map<String, dynamic> requestData = <String, dynamic>{
            'model': config.model,
            'temperature': 0.2,
            'messages': <Map<String, String>>[
              <String, String>{
                'role': 'system',
                'content':
                    'You translate EPUB HTML fragments into ${config.targetLanguage}. The user payload may include read-only context before and after the requested blocks plus a compact bookMemory summary of earlier chapters. Use that context only for continuity, pronouns, tone, terminology, and paragraph flow. Translate only items in "blocks"; never include context items in the response. Return strict JSON only. Preserve every HTML tag, attribute, entity, footnote marker, and inline emphasis. Translate only human-readable text. The response must be a JSON object with a "blocks" array. Each array item must contain the original "id" and the translated HTML in "html". Do not omit any block and keep the same order.${_apiClient.lockedGlossaryInstruction(config)}',
              },
              <String, String>{'role': 'user', 'content': payload},
            ],
          };
          final Response<dynamic> response = await _apiClient
              .postChatCompletions(
                dio: dio,
                data: requestData,
                cancelToken: cancelToken,
              );

          final String parsedContent = _apiClient.extractMessageContent(
            response.data,
          );
          final Map<String, dynamic> jsonPayload = _apiClient.decodeJsonObject(
            parsedContent,
          );
          final List<dynamic> blocksJson =
              jsonPayload['blocks'] as List<dynamic>? ?? <dynamic>[];
          if (blocksJson.length != batch.blocks.length) {
            throw const FormatException(
              'Translated batch length does not match request length.',
            );
          }

          final Map<String, String> translatedById = <String, String>{};
          for (final dynamic item in blocksJson) {
            if (item is! Map<String, dynamic>) {
              throw const FormatException(
                'Translated batch item is not a JSON object.',
              );
            }
            final String? id = item['id'] as String?;
            final String? html = item['html'] as String?;
            if (id == null || html == null || html.trim().isEmpty) {
              throw const FormatException(
                'Translated batch item is missing id or html.',
              );
            }
            translatedById[id] = html.trim();
          }

          return batch.blocks.map((ExtractedBlock block) {
            final String? translated = translatedById[block.id];
            if (translated == null || translated.isEmpty) {
              throw const FormatException(
                'A translated block is missing from the batch response.',
              );
            }
            final String locked = _lockTranslatedHtmlStructure(
              block,
              translated,
            );
            _validateTranslatedBlockQuality(
              config: config,
              block: block,
              translatedHtml: locked,
            );
            return locked;
          }).toList();
        },
      );
    } on DioException catch (error) {
      if (_isCancelError(error)) {
        throw const TranslationCancelledException();
      }
      if (TranslationApiClient.shouldFallbackBatchDioException(error)) {
        return Future.wait<String>(
          batch.blocks.map(
            (ExtractedBlock block) => _translateBlock(
              dio: dio,
              config: config,
              block: block,
              cancelToken: cancelToken,
            ),
          ),
        );
      }
      rethrow;
    } on FormatException catch (_) {
      return Future.wait<String>(
        batch.blocks.map(
          (ExtractedBlock block) => _translateBlock(
            dio: dio,
            config: config,
            block: block,
            cancelToken: cancelToken,
          ),
        ),
      );
    }
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
    required String translatedHtml,
  }) {
    if (!config.residualQualityCheck) {
      return;
    }
    final String translatedText = _plainTextFromHtmlFragment(
      translatedHtml,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!TranslationQuality.hasSuspiciousSourceResidual(
      sourceText: block.sourceText,
      translatedText: translatedText,
      targetLanguage: config.targetLanguage,
    )) {
      return;
    }

    throw FormatException(
      'Possible untranslated source-language text remains in block ${block.id}.',
    );
  }

  String _outputFilePath({
    required String inputPath,
    required String outputDirectory,
    required String suffix,
  }) {
    final String safeSuffix = TranslationApiClient.sanitizeOutputSuffix(suffix);
    final String baseName = path.basenameWithoutExtension(inputPath);
    String candidate = path.join(outputDirectory, '$baseName$safeSuffix.epub');
    // Never overwrite the source EPUB even if sanitization collapses the name.
    if (_sameFilesystemPath(candidate, inputPath)) {
      candidate = path.join(outputDirectory, '$baseName${safeSuffix}_out.epub');
    }
    return candidate;
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

  Future<String> _inputFingerprint(String inputPath) async {
    final FileStat stat = await File(inputPath).stat();
    final String normalizedPath = _normalizeInputPathForCache(inputPath);
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              _cacheSchemaVersion,
              normalizedPath,
              stat.size,
              stat.modified.millisecondsSinceEpoch,
            ].join('|'),
          ),
        )
        .toString();
  }

  String _jobKey({
    required String inputFingerprint,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
  }) {
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              _cacheSchemaVersion,
              inputFingerprint,
              _apiClient.normalizedBaseUrl(config.apiBaseUrl),
              config.model.trim(),
              config.targetLanguage.trim(),
              config.bilingual,
              config.lockedGlossary.trim(),
              config.residualQualityCheck,
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
  }) {
    return sha256
        .convert(
          utf8.encode(
            <Object>[
              _cacheSchemaVersion,
              _apiClient.normalizedBaseUrl(config.apiBaseUrl),
              config.model.trim(),
              config.targetLanguage.trim(),
              config.lockedGlossary.trim(),
              config.residualQualityCheck,
              chapterPath,
              block.sourceHtml,
            ].join('|'),
          ),
        )
        .toString();
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

  String _previewBodyFromBlocks(
    List<ExtractedBlock> blocks, {
    required String fallback,
  }) {
    final Iterable<String> translated = blocks
        .map((ExtractedBlock block) => _plainTextFromHtml(block.translatedHtml))
        .whereType<String>()
        .map((String text) => text.trim())
        .where((String text) => text.isNotEmpty)
        .take(12);
    if (translated.isEmpty) {
      return fallback;
    }
    return translated.join('\n\n');
  }

  String? _plainTextFromHtml(String? html) {
    if (html == null || html.trim().isEmpty) {
      return null;
    }
    final dom.DocumentFragment fragment = html_parser.parseFragment(html);
    return (fragment.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
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

class _HtmlTextSlot {
  const _HtmlTextSlot({required this.node, required this.protected});

  final dom.Text node;
  final bool protected;

  String get text => node.data;

  set text(String value) {
    node.data = value;
  }
}

class _BookMemory {
  const _BookMemory({
    this.bookSummary = '',
    this.styleGuide = const <String>[],
    this.glossary = const <Map<String, String>>[],
    this.recentChapters = const <_ChapterMemory>[],
  });

  static const _BookMemory empty = _BookMemory();

  factory _BookMemory.fromJson(Map<String, Object?> json) {
    return _BookMemory(
      bookSummary: _stringValue(json['bookSummary']),
      styleGuide: _stringList(
        json['styleGuide'],
        limit: EpubChapterTranslator._memoryListLimit,
      ),
      glossary: _glossaryList(json['glossary']),
      recentChapters: _chapterMemoryList(json['recentChapters']),
    );
  }

  final String bookSummary;
  final List<String> styleGuide;
  final List<Map<String, String>> glossary;
  final List<_ChapterMemory> recentChapters;

  bool get isEmpty =>
      bookSummary.trim().isEmpty &&
      styleGuide.isEmpty &&
      glossary.isEmpty &&
      recentChapters.isEmpty;

  _BookMemory mergeChapter(_ChapterMemory chapter) {
    final List<_ChapterMemory> mergedRecent = <_ChapterMemory>[
      ...recentChapters,
      chapter,
    ];
    final List<_ChapterMemory> limitedRecent =
        mergedRecent.length <= EpubChapterTranslator._recentChapterMemoryLimit
        ? mergedRecent
        : mergedRecent.sublist(
            mergedRecent.length -
                EpubChapterTranslator._recentChapterMemoryLimit,
          );

    return _BookMemory(
      bookSummary: bookSummary,
      styleGuide: styleGuide,
      glossary: _mergeGlossary(glossary, chapter.glossary),
      recentChapters: List<_ChapterMemory>.unmodifiable(limitedRecent),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (bookSummary.trim().isNotEmpty) 'bookSummary': bookSummary.trim(),
      'styleGuide': styleGuide,
      'glossary': glossary,
      'recentChapters': recentChapters
          .map((_ChapterMemory chapter) => chapter.toJson())
          .toList(growable: false),
    };
  }

  static String _stringValue(Object? value) {
    return value is String ? value.trim() : '';
  }

  static List<String> _stringList(Object? value, {required int limit}) {
    if (value is! List<dynamic>) {
      return const <String>[];
    }
    return value
        .whereType<String>()
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .take(limit)
        .toList(growable: false);
  }

  static List<Map<String, String>> _glossaryList(Object? value) {
    if (value is! List<dynamic>) {
      return const <Map<String, String>>[];
    }
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> item) {
          final String source = _stringValue(item['source']);
          final String target = _stringValue(item['target']);
          if (source.isEmpty || target.isEmpty) {
            return null;
          }
          return <String, String>{'source': source, 'target': target};
        })
        .whereType<Map<String, String>>()
        .take(EpubChapterTranslator._memoryGlossaryLimit)
        .toList(growable: false);
  }

  static List<_ChapterMemory> _chapterMemoryList(Object? value) {
    if (value is! List<dynamic>) {
      return const <_ChapterMemory>[];
    }
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> item) => _ChapterMemory.fromJson(
            item.map(
              (dynamic key, dynamic value) =>
                  MapEntry<String, Object?>(key.toString(), value),
            ),
          ),
        )
        .where((_ChapterMemory chapter) => !chapter.isEmpty)
        .take(EpubChapterTranslator._recentChapterMemoryLimit)
        .toList(growable: false);
  }

  static List<Map<String, String>> _mergeGlossary(
    List<Map<String, String>> existing,
    List<Map<String, String>> incoming,
  ) {
    final Map<String, Map<String, String>> merged =
        <String, Map<String, String>>{};
    for (final Map<String, String> entry in <Map<String, String>>[
      ...existing,
      ...incoming,
    ]) {
      merged[entry['source']!.toLowerCase()] = entry;
    }
    return merged.values
        .take(EpubChapterTranslator._memoryGlossaryLimit)
        .toList(growable: false);
  }
}

class _ChapterMemory {
  const _ChapterMemory({
    required this.title,
    required this.summary,
    this.continuityNotes = const <String>[],
    this.glossary = const <Map<String, String>>[],
  });

  factory _ChapterMemory.fromJson(Map<String, Object?> json) {
    return _ChapterMemory(
      title: _BookMemory._stringValue(json['title']),
      summary: _BookMemory._stringValue(json['summary']),
      continuityNotes: _BookMemory._stringList(
        json['continuityNotes'],
        limit: EpubChapterTranslator._memoryListLimit,
      ),
      glossary: _BookMemory._glossaryList(json['glossary']),
    );
  }

  final String title;
  final String summary;
  final List<String> continuityNotes;
  final List<Map<String, String>> glossary;

  bool get isEmpty =>
      title.trim().isEmpty &&
      summary.trim().isEmpty &&
      continuityNotes.isEmpty &&
      glossary.isEmpty;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (title.trim().isNotEmpty) 'title': title.trim(),
      if (summary.trim().isNotEmpty) 'summary': summary.trim(),
      'continuityNotes': continuityNotes,
      'glossary': glossary,
    };
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
