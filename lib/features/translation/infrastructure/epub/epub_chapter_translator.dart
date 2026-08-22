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
import '../../domain/models/translation_style_profile.dart';
import '../../domain/repositories/translation_repository.dart';
import '../translation_cache_store.dart';
import '../translation_quality.dart';
import '../cache_restoration_scanner.dart';
import 'epub_repacker.dart';
import 'footnote_batch_planner.dart';
import 'protected_anchor_text_slots.dart';
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
    FootnoteBatchPlanner? footnoteBatchPlanner,
  }) : _cacheStore = cacheStore ?? TranslationCacheStore(),
       _repacker = repacker ?? EpubRepacker(),
       _apiClient = apiClient ?? const TranslationApiClient(),
       _batchPlanner = batchPlanner ?? const TranslationBatchPlanner(),
       _footnoteBatchPlanner =
           footnoteBatchPlanner ?? const FootnoteBatchPlanner();

  /// Block ids whose translation could not pass quality checks or whose API
  /// connection/response timed out. They degrade to their last usable
  /// translation (or source HTML when no response arrived) so the whole book
  /// can continue. Recorded so the run report can list them honestly.
  final Set<String> degradedBlockIds = <String>{};

  final TranslationCacheStore _cacheStore;
  final EpubRepacker _repacker;
  final TranslationApiClient _apiClient;
  final TranslationBatchPlanner _batchPlanner;
  final FootnoteBatchPlanner _footnoteBatchPlanner;

  static const String _cacheSchemaVersion = 'v12-protected-anchor-text-slots';
  static const int _initialMemoryFrontMatterLimit = 2;
  static const int _initialMemoryContentLimit = 2;
  static const int _memoryChapterTextLimit = 2400;
  static const int _minimumRepresentativeStyleCharacters = 240;
  static const int _memoryListLimit = 8;
  static const int _memoryGlossaryLimit = 32;
  static const int _recentChapterMemoryLimit = 2;

  static bool shouldFallbackBatchDioExceptionForTest(DioException error) {
    return TranslationApiClient.shouldFallbackBatchDioException(error);
  }

  static String sanitizeOutputSuffixForTest(String suffix) {
    return TranslationApiClient.sanitizeOutputSuffix(suffix);
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
    TranslationStyleProfile? confirmedStyleProfile,
  }) {
    return EpubChapterTranslator()._blockCacheKey(
      config,
      block,
      chapterPath: chapterPath,
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
    return _styleProfileSourceChapters(chapters);
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

  /// Test-only view of the blocks degraded for this translator instance.
  Set<String> getDegradedBlockIdsForTest() => degradedBlockIds;

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

  Future<Map<String, String>> translateFootnoteBatchForTest({
    required Dio dio,
    required TranslationConfig config,
    required List<FootnoteBlockReference> references,
    Map<String, Object?>? bookMemory,
  }) {
    return _translateFootnoteBatch(
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

  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
  }) async {
    if (!config.styleProfileEnabled) {
      return TranslationStyleProfile.empty;
    }
    final Dio dio = _apiClient.buildDio(config);
    return _generateStyleProfile(
      dio: dio,
      config: config,
      chapters: chapters,
      cancelToken: cancelToken,
    );
  }

  Future<TranslationStyleProfile> generateStyleProfileForTest({
    required Dio dio,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
  }) async {
    return _generateStyleProfile(dio: dio, config: config, chapters: chapters);
  }

  /// Dedicated style-profile call, not piggybacked on book-memory summary.
  Future<TranslationStyleProfile> _generateStyleProfile({
    required Dio dio,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    CancelToken? cancelToken,
  }) async {
    final List<Map<String, String>> sourceChapters =
        _styleProfileSourceChapters(chapters);
    if (sourceChapters.isEmpty) {
      return TranslationStyleProfile.empty;
    }

    final Map<String, dynamic> payload = <String, dynamic>{
      'kind': 'styleProfile',
      'targetLanguage': config.targetLanguage,
      'chapters': sourceChapters,
    };
    final Map<String, dynamic> jsonPayload = await _requestMemoryJson(
      dio: dio,
      config: config,
      payload: payload,
      systemPrompt:
          'You analyze an EPUB before translation. Return strict JSON only. '
          'Required top-level object keys: primaryGenre, secondaryGenres, tone, '
          'sentenceStyle, translationConstraints, avoid, confidence. '
          'primaryGenre must be a practical book type such as business nonfiction, '
          'science fiction, romance, historical fiction, literary fiction, mystery, '
          'fantasy, memoir, self-help, biography, or philosophy. '
          'secondaryGenres is a short string array. tone and sentenceStyle are short phrases. '
          'translationConstraints and avoid may be either string arrays or single strings. '
          'Write notes for translators into ${config.targetLanguage}. '
          'confidence must be one of: high, medium, low. '
          'Prefer executable style rules over marketing labels. '
          'Never instruct translators to keep whole English quotations, dialogue, or epigraphs untranslated when the target language is not English; only proper names, work titles, URLs, and short technical terms may remain in the source language. '
          'If evidence is thin, still provide a best-effort primaryGenre with confidence low. '
          'Do not wrap the JSON in markdown fences.',
      cancelToken: cancelToken,
    );
    return _parseStyleProfileResponse(jsonPayload);
  }

  /// Samples meaningful front matter plus early/middle/late body chapters.
  ///
  /// Indexes, contents, copyright pages, credits and other structural matter
  /// must not influence the inferred writing style even when an EPUB uses
  /// opaque filenames or generic document titles.
  static List<Map<String, String>> _styleProfileSourceChapters(
    List<InspectedChapter> chapters,
  ) {
    final List<InspectedChapter> eligible = chapters
        .where((InspectedChapter chapter) => chapter.includeInTranslation)
        .where((InspectedChapter chapter) => chapter.blocks.isNotEmpty)
        .where(
          (InspectedChapter chapter) => !_excludeFromStyleSampling(chapter),
        )
        .toList(growable: false);
    if (eligible.isEmpty) {
      return const <Map<String, String>>[];
    }

    final List<InspectedChapter> selected = <InspectedChapter>[];
    final Map<String, String> rolesByPath = <String, String>{};
    void add(InspectedChapter chapter, String role) {
      if (selected.any((InspectedChapter c) => c.path == chapter.path)) {
        return;
      }
      selected.add(chapter);
      rolesByPath[chapter.path] = role;
    }

    for (final InspectedChapter chapter
        in eligible
            .where(
              (InspectedChapter c) => c.category == ChapterCategory.frontMatter,
            )
            .where(_isMeaningfulFrontMatter)
            .take(2)) {
      add(chapter, 'frontMatter');
    }

    final List<InspectedChapter> contentCandidates = eligible
        .where((InspectedChapter c) => c.category == ChapterCategory.content)
        .toList(growable: false);
    final List<InspectedChapter> substantialContent = contentCandidates
        .where(
          (InspectedChapter chapter) =>
              _representativeStyleText(chapter.blocks).length >=
              _minimumRepresentativeStyleCharacters,
        )
        .toList(growable: false);
    final int desiredRepresentativeCount = min(3, contentCandidates.length);
    final List<InspectedChapter> content =
        desiredRepresentativeCount > 0 &&
            substantialContent.length >= desiredRepresentativeCount
        ? substantialContent
        : contentCandidates;
    final List<InspectedChapter> representativeContent =
        _representativeContentChapters(content);
    for (int index = 0; index < representativeContent.length; index += 1) {
      final String role = switch (index) {
        0 => 'earlyContent',
        1 when representativeContent.length >= 3 => 'middleContent',
        _ => 'lateContent',
      };
      add(representativeContent[index], role);
    }

    if (selected.length < 2) {
      for (final InspectedChapter chapter in eligible) {
        add(chapter, 'fallback');
        if (selected.length >= 4) {
          break;
        }
      }
    }

    return selected
        .map((InspectedChapter chapter) {
          return <String, String>{
            'path': chapter.path,
            'title': chapter.title,
            'category': chapter.category.name,
            'role': rolesByPath[chapter.path] ?? 'fallback',
            'text': _representativeStyleText(chapter.blocks),
          };
        })
        .where((Map<String, String> chapter) => chapter['text']!.isNotEmpty)
        .toList(growable: false);
  }

  static List<InspectedChapter> _representativeContentChapters(
    List<InspectedChapter> content,
  ) {
    if (content.length <= 3) {
      return content;
    }
    return <InspectedChapter>[
      content.first,
      content[content.length ~/ 2],
      content.last,
    ];
  }

  static bool _excludeFromStyleSampling(InspectedChapter chapter) {
    if (chapter.category == ChapterCategory.ancillary ||
        chapter.category == ChapterCategory.reference ||
        chapter.category == ChapterCategory.backMatter) {
      return true;
    }
    final String normalizedPath = chapter.path
        .replaceAll('\\', '/')
        .toLowerCase();
    final String fileName = normalizedPath.split('/').last;
    final String normalizedTitle = chapter.title.trim().toLowerCase();
    if (RegExp(r'^(nav|navigation)(\.[^.]+)?$').hasMatch(fileName) ||
        RegExp(r'(^|[-_.])(fn|footnotes?)([-_.]|$)').hasMatch(fileName) ||
        <String>{
          'footnote',
          'footnotes',
          'navigation',
          'table of contents',
          'contents',
        }.contains(normalizedTitle)) {
      return true;
    }
    final String token = '$normalizedPath $normalizedTitle';
    return <String>[
      'index',
      '_ind_',
      'table of contents',
      'contents',
      '_toc_',
      'copyright',
      '_cop_',
      'cover',
      '_cvi_',
      'title page',
      '_tp_',
      'acknowledg',
      '_ack_',
      'illustration',
      '_ill_',
      'about the author',
      '_ata_',
      'bibliography',
      'endnote',
      'about the publisher',
      'book perk',
      'card page',
      'advertisement',
      'also by',
      'books by',
    ].any(token.contains);
  }

  static bool _isMeaningfulFrontMatter(InspectedChapter chapter) {
    final String token = '${chapter.path} ${chapter.title}'.toLowerCase();
    return <String>[
      'preface',
      '_prf_',
      'foreword',
      'introduction',
      'prologue',
    ].any(token.contains);
  }

  static String _representativeStyleText(List<ExtractedBlock> blocks) {
    final List<String> texts = blocks
        .map((ExtractedBlock block) => block.sourceText.trim())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    if (texts.isEmpty) {
      return '';
    }
    if (texts.length <= 12) {
      return _trimMemoryText(texts.join('\n'));
    }

    const int segmentBlocks = 4;
    const int segmentCharacterLimit = _memoryChapterTextLimit ~/ 3;
    final int middleStart = max(0, (texts.length - segmentBlocks) ~/ 2);
    final int endingStart = max(0, texts.length - segmentBlocks);
    final List<String> opening = texts.take(segmentBlocks).toList();
    final List<String> middle = texts
        .skip(middleStart)
        .take(segmentBlocks)
        .toList();
    final List<String> ending = texts
        .skip(endingStart)
        .take(segmentBlocks)
        .toList();

    return <String>[
      '[Opening]\n${_trimStyleSegment(opening, segmentCharacterLimit)}',
      '[Middle]\n${_trimStyleSegment(middle, segmentCharacterLimit)}',
      '[Ending]\n${_trimStyleSegment(ending, segmentCharacterLimit)}',
    ].join('\n');
  }

  static String _trimStyleSegment(List<String> texts, int limit) {
    final String collapsed = texts
        .join('\n')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (collapsed.length <= limit) {
      return collapsed;
    }
    return '${collapsed.substring(0, limit - 3)}...';
  }

  static TranslationStyleProfile _parseStyleProfileResponse(
    Map<String, dynamic> jsonPayload,
  ) {
    Object? candidate = jsonPayload['styleProfile'];
    if (candidate is! Map) {
      candidate = jsonPayload;
    }
    final Map<String, Object?> styleJson = <String, Object?>{
      for (final MapEntry<dynamic, dynamic> entry in candidate.entries)
        entry.key.toString(): entry.value,
    };
    // Common alternate key names from model drift.
    styleJson.putIfAbsent(
      'primaryGenre',
      () => styleJson['genre'] ?? styleJson['primary_genre'],
    );
    styleJson.putIfAbsent(
      'secondaryGenres',
      () => styleJson['secondary'] ?? styleJson['tags'],
    );
    styleJson.putIfAbsent(
      'translationConstraints',
      () => styleJson['constraints'] ?? styleJson['do'],
    );
    final TranslationStyleProfile profile = TranslationStyleProfile.fromJson(
      styleJson,
    );
    if (!profile.isEmpty) {
      return profile;
    }
    // Last-resort: if model only returned a genre-like string field.
    final String genre = TranslationStyleProfile.fromJson(<String, Object?>{
      'primaryGenre': styleJson['primaryGenre'],
    }).primaryGenre;
    if (genre.isEmpty) {
      return TranslationStyleProfile.empty;
    }
    return TranslationStyleProfile(
      primaryGenre: genre,
      confidence: TranslationStyleConfidenceParsing.parse(
        styleJson['confidence'],
      ),
    );
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
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    try {
      final List<InspectedChapter> selectedChapters = chapters
          .where(
            (InspectedChapter chapter) =>
                chapter.includeInTranslation && chapter.blocks.isNotEmpty,
          )
          .map(
            (InspectedChapter chapter) => _prepareChapterForTarget(
              chapter,
              targetLanguage: config.targetLanguage,
            ),
          )
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
      int footnoteBatchCount = 0;
      int footnoteRequestCount = 0;
      DateTime lastResumeSaveAt = DateTime.now();
      int blocksSinceResumeSave = 0;

      final String jobId = DateTime.now().millisecondsSinceEpoch.toString();
      final String outputFilePath = _outputFilePath(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        suffix: config.outputSuffix,
      );
      final TranslationStyleProfile? confirmedProfile =
          config.styleProfileEnabled ? confirmedStyleProfile : null;
      final TranslationStyleProfile? userStyleProfile =
          confirmedProfile == null || confirmedProfile.isEmpty
          ? null
          : confirmedProfile;
      final String inputFingerprint = await _inputFingerprint(inputPath);
      final String jobKey = _jobKey(
        inputFingerprint: inputFingerprint,
        config: config,
        chapters: selectedChapters,
        confirmedStyleProfile: userStyleProfile,
      );
      JobResumeState? previousState;
      bool unreadableResumeState = false;
      try {
        previousState = await _cacheStore.loadJobState(jobKey);
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
          'Found a saved translation checkpoint with $checkpointBlocks/$totalBlocks blocks from ${previousState.updatedAtIso8601}. Verifying local cache before new API calls.',
        );
      } else if (unreadableResumeState) {
        emit(
          currentJob,
          'Saved checkpoint is unreadable. Scanning block caches without checkpoint metadata.',
        );
      }

      emit(
        currentJob,
        'Restoring local cache for ${selectedChapters.length} chapters and $totalBlocks extracted blocks.',
      );
      throwIfCancelled();

      final CacheRestorationResult restoration =
          await CacheRestorationScanner(
            readTranslation: _cacheStore.getBlockTranslation,
          ).scan(
            chapters: selectedChapters,
            cacheKeyFor: (InspectedChapter chapter, ExtractedBlock block) =>
                _blockCacheKey(
                  config,
                  block,
                  chapterPath: chapter.path,
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
                  currentChapter: 'Restoring cached translations',
                  currentBlock: null,
                ),
                'Cache scan ${progress.scannedBlocks}/${progress.totalBlocks}: verified ${progress.cachedBlocks} reusable blocks.',
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
            ? 'Continuing translation'
            : 'All translations restored from cache',
        currentBlock: null,
      );
      emit(
        currentJob,
        hasPendingBlocks
            ? 'Reused $cachedBlocks cached blocks; cache restoration made no API requests. Continuing with ${totalBlocks - cachedBlocks} blocks.'
            : 'Reused all $totalBlocks blocks; this run made no API requests.',
      );
      await saveResumeState(currentJob, force: true);

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
      bool initialBookMemoryAttempted = userStyleProfile != null;
      final Map<int, bool> chapterPendingCache = <int, bool>{};

      if (userStyleProfile != null && !userStyleProfile.isEmpty) {
        emit(
          currentJob,
          'Style profile: using user-confirmed profile ${userStyleProfile.summaryLabel}.',
        );
      }

      Future<void> ensureInitialBookMemory() async {
        if (initialBookMemoryAttempted) {
          return;
        }
        initialBookMemoryAttempted = true;
        throwIfCancelled();
        try {
          final bool hasInitialMemorySources = _initialMemorySourceChapters(
            chapters,
          ).isNotEmpty;
          final Stopwatch memoryStopwatch = Stopwatch()..start();
          final _BookMemory initialMemory = await _generateInitialBookMemory(
            dio: dio,
            config: config,
            chapters: chapters,
            cancelToken: cancelToken,
          );
          bookMemory = userStyleProfile == null
              ? initialMemory
              : initialMemory.copyWith(
                  styleProfile: userStyleProfile,
                  styleProfileConfirmed: true,
                );
          memoryStopwatch.stop();
          if (hasInitialMemorySources) {
            totalMemoryElapsed += memoryStopwatch.elapsed;
            memoryRequestCount += 1;
          }
          if (initialMemory.isEmpty &&
              (userStyleProfile == null || userStyleProfile.isEmpty)) {
            emit(
              currentJob,
              'Book memory: no useful front matter or early chapter text was found in ${_formatDuration(memoryStopwatch.elapsed)}.',
            );
          } else {
            emit(
              currentJob,
              'Book memory: created initial summary from front matter and early chapters in ${_formatDuration(memoryStopwatch.elapsed)}.',
            );
            final TranslationStyleProfile styleProfile =
                bookMemory?.styleProfile ?? TranslationStyleProfile.empty;
            if (!config.styleProfileEnabled) {
              emit(
                currentJob,
                'Style profile: disabled in settings; using generic translation style.',
              );
            } else if (userStyleProfile != null && !userStyleProfile.isEmpty) {
              emit(
                currentJob,
                'Style profile: user-confirmed ${userStyleProfile.summaryLabel} will guide later batches.',
              );
            } else if (styleProfile.shouldInject) {
              emit(
                currentJob,
                'Style profile: ${styleProfile.summaryLabel}. Soft genre/tone constraints will guide later batches.',
              );
            } else if (!styleProfile.isEmpty) {
              emit(
                currentJob,
                'Style profile: low confidence (${styleProfile.summaryLabel}); keeping generic translation style.',
              );
            } else {
              emit(
                currentJob,
                'Style profile: not enough signal from front matter/early chapters; keeping generic translation style.',
              );
            }
          }
        } catch (error) {
          if (userStyleProfile != null && !userStyleProfile.isEmpty) {
            bookMemory = _BookMemory.empty.copyWith(
              styleProfile: userStyleProfile,
              styleProfileConfirmed: true,
            );
            emit(
              currentJob,
              'Book memory: initial summary skipped (${_linePreview(_safeErrorText(error, config))}). Continuing with user-confirmed style profile.',
            );
          } else {
            emit(
              currentJob,
              'Book memory: initial summary skipped (${_linePreview(_safeErrorText(error, config))}). Translation will continue without whole-book memory until a chapter summary is available.',
            );
          }
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
          final String? cachedTranslation = restoration.translationFor(
            chapter.path,
            block.id,
          );
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

      Future<int> translateFootnoteRun(int startChapterIndex) async {
        int endChapterIndex = startChapterIndex;
        while (endChapterIndex + 1 < selectedChapters.length &&
            FootnoteBatchPlanner.isStandaloneFootnoteChapter(
              selectedChapters[endChapterIndex + 1],
            )) {
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
            'Translating chapter ${chapterIndex + 1}/${selectedChapters.length}: ${chapter.title}',
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
          chapterPendingCache[chapterIndex] = pendingBlocks.isNotEmpty;

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
        final List<FootnoteTranslationBatch> batches = _footnoteBatchPlanner
            .plan(
              chapters: selectedChapters,
              pendingBlocksByChapter: pendingBlocksByChapter,
              chunkSize: config.chunkSize,
              bookMemory: bookMemory?.toJson(),
            );
        emit(
          currentJob.copyWith(
            currentChapter: selectedChapters[startChapterIndex].title,
            completedFiles: completedFiles,
            completedBlocks: completedBlocks,
          ),
          'Prepared ${batches.length} cross-file footnote batches for $pendingCount blocks across ${endChapterIndex - startChapterIndex + 1} files${runCacheHits == 0 ? '' : ' after $runCacheHits cache hits'}.',
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
            if (!degradedBlockIds.contains(reference.block.id)) {
              await _cacheStore.putBlockTranslation(
                _blockCacheKey(
                  config,
                  reference.block,
                  chapterPath: reference.chapter.path,
                  confirmedStyleProfile: userStyleProfile,
                ),
                translated,
              );
            }
            translatedByChapterIndex[reference.chapterIndex]![reference
                .block
                .id] = reference.block.copyWith(
              translatedHtml: translated,
            );
            completedBlocks += 1;
            apiTranslatedBlocks += 1;
            cacheWriteCount += 1;
            blocksSinceResumeSave += 1;
            currentJob = currentJob.copyWith(
              progress: completedBlocks / totalBlocks,
              currentChapter: reference.chapter.title,
              currentBlock: _linePreview(reference.block.sourceText),
              completedFiles: completedFiles,
              totalFiles: selectedChapters.length,
              completedBlocks: completedBlocks,
              totalBlocks: totalBlocks,
              cachedBlocks: cachedBlocks,
              resumedBlocks: resumedBlocks,
            );
          }
          cacheStopwatch.stop();
          totalCacheWriteElapsed += cacheStopwatch.elapsed;
        }

        for (int batchIndex = 0; batchIndex < batches.length; batchIndex += 1) {
          throwIfCancelled();
          final FootnoteTranslationBatch batch = batches[batchIndex];
          final Stopwatch batchStopwatch = Stopwatch()..start();
          Duration batchApiElapsed = Duration.zero;
          int requestCount = 0;

          Future<Map<String, String>> sendFootnoteRequest(
            FootnoteTranslationBatch requestBatch,
          ) async {
            final Stopwatch requestStopwatch = Stopwatch()..start();
            try {
              return await _translateFootnoteBatch(
                dio: dio,
                config: config,
                batch: requestBatch,
                cancelToken: cancelToken,
                onRequestAttempt: () {
                  requestCount += 1;
                  footnoteRequestCount += 1;
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
            await saveResumeState(currentJob, force: true);
          } catch (error) {
            if (error is! DioException ||
                !TranslationApiClient.shouldFallbackBatchDioException(error)) {
              rethrow;
            }
            if (batch.references.length <= 1) {
              rethrow;
            }
            for (final FootnoteBlockReference reference in batch.references) {
              throwIfCancelled();
              final Map<String, String> translated = await sendFootnoteRequest(
                FootnoteTranslationBatch(<FootnoteBlockReference>[
                  reference,
                ], context: batch.context),
              );
              await persistTranslations(<FootnoteBlockReference>[
                reference,
              ], translated);
            }
            await saveResumeState(currentJob, force: true);
          }
          batchStopwatch.stop();
          footnoteBatchCount += 1;
          emit(
            currentJob,
            'Performance: footnote batch ${batchIndex + 1}/${batches.length} (${batch.references.length} blocks, $requestCount API ${requestCount == 1 ? 'request' : 'requests'}) took ${_formatDuration(batchStopwatch.elapsed)}; API time ${_formatDuration(batchApiElapsed)}.',
          );
          emit(
            currentJob,
            'Translated $completedBlocks/$totalBlocks blocks after cross-file footnote batch ${batchIndex + 1}/${batches.length}.',
          );
        }

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
            body: _previewBodyFromBlocks(
              translatedBlocks,
              fallback: chapter.body,
            ),
          );
          chapterPendingCache[chapterIndex] = false;
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
            'Completed chapter $completedFiles/${selectedChapters.length}: ${chapter.title}',
          );
          await saveResumeState(chapterDoneJob, force: true);
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
          if (FootnoteBatchPlanner.isStandaloneFootnoteChapter(chapter)) {
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
            'Translating chapter ${chapterIndex + 1}/${selectedChapters.length}: ${chapter.title}',
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
              'Reused $chapterCacheHits cached blocks for ${chapter.title}.',
            );
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
                  if (!degradedBlockIds.contains(batch.blocks[index].id))
                    _cacheStore.putBlockTranslation(
                      _blockCacheKey(
                        config,
                        batch.blocks[index],
                        chapterPath: chapter.path,
                        confirmedStyleProfile: userStyleProfile,
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
      if (degradedBlockIds.isNotEmpty) {
        emit(
          currentJob.copyWith(
            currentChapter: 'Repacking EPUB',
            currentBlock: null,
          ),
          'Degraded blocks retained as their last usable translation: '
          '${degradedBlockIds.join(',')}. The EPUB will still be produced and '
          'the run report lists these blocks.',
        );
      }
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
        phase: TranslationJobPhase.translation,
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
        'Performance: Translation run took ${_formatDuration(translationStopwatch.elapsed)}. Translated $apiTranslatedBlocks new blocks at ${_formatBlocksPerMinute(apiTranslatedBlocks, translationStopwatch.elapsed)} blocks/min on average, excluding cache and resume hits. Total API time ${_formatDuration(totalApiElapsed)}; book memory ${_formatDuration(totalMemoryElapsed)} across $memoryRequestCount requests; block cache writes ${_formatDuration(totalCacheWriteElapsed)} across $cacheWriteCount writes.${footnoteBatchCount == 0 ? '' : ' Cross-file footnotes used $footnoteBatchCount batches across $footnoteRequestCount API requests.'}',
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
    TranslationStyleProfile styleProfile = TranslationStyleProfile.empty,
    bool styleProfileConfirmed = false,
  }) async {
    Object? lastError;
    String? lastCleaned;
    for (int attempt = 1; ; attempt += 1) {
      try {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        String userContent = block.sourceHtml;
        if (attempt > 1 && lastError != null) {
          // Tell the model why the previous attempt was rejected so a clean
          // retry has a concrete instruction instead of repeating the same
          // (often untranslated) output. Keep the reason lossy/safe — never
          // embed the raw exception or API key here.
          final String reason = _safeErrorText(
            lastError,
            config,
          ).replaceAll(RegExp(r'\s+'), ' ').trim();
          final String retryInstruction = _isEmptyTranslationResponse(lastError)
              ? 'The previous response was empty. Return a complete HTML '
                    'fragment with every human-readable text node translated '
                    'into ${config.targetLanguage}.'
              : 'Translate every human-readable text node into '
                    '${config.targetLanguage}.';
          userContent =
              '$userContent\n\n'
              '[RETRY] The previous translation was rejected for this reason: '
              '$reason. $retryInstruction Only titles, proper names, and '
              'reference data (such as author names, journal names, volume, '
              'issue, year, and page numbers in a bibliography entry) may '
              'stay in the original language. Return the complete HTML '
              'fragment with all tags, attributes, and inline emphasis '
              'preserved.';
        }
        final Map<String, dynamic> requestData = <String, dynamic>{
          'model': config.model,
          'temperature': 0.2,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content':
                  'You translate EPUB HTML fragments into ${config.targetLanguage}. Preserve every HTML tag, attribute, inline emphasis, entity, and link target. Translate only human-readable text nodes. Return only the translated HTML fragment with no markdown fences and no explanation.${_styleProfileInstruction(config: config, styleProfile: styleProfile, confirmed: styleProfileConfirmed)}${_apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}',
            },
            <String, String>{'role': 'user', 'content': userContent},
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
        lastCleaned = cleaned;
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
        if (error is FormatException ||
            TranslationApiClient.isRequestTimeout(error)) {
          try {
            final File diagFile = File(
              r'F:\vibe coding\epub-translator-flutter-clean\work\'
              r'_p13_failure_diag.log',
            );
            final RandomAccessFile raf = await diagFile.open(
              mode: FileMode.append,
            );
            final String sourcePreview = _linePreview(
              block.sourceHtml.replaceFirst(RegExp(r'<[^>]*>'), ''),
            );
            String? lockedPreview;
            try {
              lockedPreview = _lockTranslatedHtmlStructure(
                block,
                lastCleaned ?? '',
              );
            } catch (_) {
              lockedPreview = null;
            }
            final String entry =
                'BLOCK=${block.id} attempt=$attempt '
                'error=$error\nSOURCE=$sourcePreview\n'
                'RAW=$lastCleaned\n'
                'LOCKED=${lockedPreview ?? '<unavailable>'}\n---\n';
            raf.writeStringSync(entry);
            raf.flushSync();
            await raf.close();
          } catch (_) {
            // Logging must never break translation.
          }
        }
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
    // A residual-quality rejection that survives every retry must NOT abort
    // the whole book. The model is not reliably deterministic: one unstable
    // batch reply that leaves a source-language run can fail all retries even
    // when the same block translates correctly on another call. Degrade that
    // one block to its last usable translation (or the source HTML when no
    // reply ever came back), record it for the run report, and keep going.
    if (lastError is FormatException && _isQualityRejection(lastError)) {
      degradedBlockIds.add(block.id);
      return lastCleaned != null && lastCleaned.trim().isNotEmpty
          ? lastCleaned
          : block.sourceHtml;
    }
    if (lastError is FormatException &&
        _isEmptyTranslationResponse(lastError)) {
      throw StateError(
        'Translation failed after ${config.maxRetries} attempts for block '
        '${block.id}: the translation API returned empty content.',
      );
    }
    if (TranslationApiClient.isRequestTimeout(lastError)) {
      degradedBlockIds.add(block.id);
      return lastCleaned != null && lastCleaned.trim().isNotEmpty
          ? lastCleaned
          : block.sourceHtml;
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

  /// Whether [error] is a residual-quality gate rejection. Other transport
  /// failures remain fatal unless they are explicitly handled below.
  static bool _isQualityRejection(Object error) {
    final String message = error.toString();
    return RegExp(
      r'Possible untranslated source-language text remains in block '
      r'|Possible untranslated source-language token '
      r'|Possible untranslated source-language text',
    ).hasMatch(message);
  }

  static bool _isEmptyTranslationResponse(Object error) {
    return error is FormatException &&
        error.toString().contains(
          'The translation API returned an empty block.',
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
      'styleProfileEnabled': config.styleProfileEnabled,
      'chapters': sourceChapters,
    };
    final String styleProfilePrompt = config.styleProfileEnabled
        ? ' Also return styleProfile as an object with keys: primaryGenre, secondaryGenres, tone, sentenceStyle, translationConstraints, avoid, confidence. primaryGenre should be a practical book type such as business nonfiction, science fiction, romance, historical fiction, literary fiction, mystery, fantasy, memoir, or self-help. secondaryGenres is a short string array. tone and sentenceStyle are short phrases. translationConstraints and avoid are short actionable string arrays for translators. confidence must be one of: high, medium, low. If evidence is weak, set confidence to low and keep constraints conservative. Prefer executable style rules over marketing labels. Never instruct translators to keep whole English quotations, dialogue, or epigraphs untranslated when the target language is not English; only proper names, work titles, URLs, and short technical terms may remain in the source language.'
        : ' Do not invent a styleProfile.';
    final Map<String, dynamic> jsonPayload = await _requestMemoryJson(
      dio: dio,
      config: config,
      payload: payload,
      systemPrompt:
          'Create a compact translation memory for an EPUB before chapter translation begins. Return strict JSON only with keys: bookSummary, styleGuide, glossary, recentChapters${config.styleProfileEnabled ? ', styleProfile' : ''}. Keep bookSummary under 120 words. styleGuide is a short string array. glossary is an array of objects with source and target. recentChapters should be empty for the initial memory. Write target terms and notes for ${config.targetLanguage}.$styleProfilePrompt',
      cancelToken: cancelToken,
    );
    final _BookMemory memory = _BookMemory.fromJson(jsonPayload);
    if (!config.styleProfileEnabled) {
      return memory.copyWith(clearStyleProfile: true);
    }
    return memory;
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
        .where(
          (InspectedChapter chapter) =>
              chapter.includeInTranslation &&
              !FootnoteBatchPlanner.isStandaloneFootnoteChapter(chapter),
        )
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
    final _NormalizedAnchorHtml normalizedTranslation =
        _normalizeProtectedAnchorMarkers(
          sourceHtml: sourceHtml,
          translatedHtml: translatedHtml,
        );
    final String trimmedTranslation = normalizedTranslation.html.trim();
    if (normalizedTranslation.hasOverflow &&
        normalizedTranslation.root != null &&
        _elementSkeletonMatches(
          _singleRootElement(sourceHtml)!,
          normalizedTranslation.root!,
        ) &&
        _overflowTextFitsSourceSlots(
          sourceRoot: _singleRootElement(sourceHtml)!,
          translatedRoot: normalizedTranslation.root!,
          trustedOverflowTexts: normalizedTranslation.trustedOverflowTexts,
        )) {
      return normalizedTranslation.root!.outerHtml;
    }
    if (_htmlStructureMatches(sourceHtml, trimmedTranslation)) {
      final String? restored = _restoreProtectedTexts(
        sourceHtml: sourceHtml,
        translatedHtml: trimmedTranslation,
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
    if (sourceHtml.contains('smallcaps')) {
      final String? flattenedRestored = _restoreWithFlattenedSmallcaps(
        sourceHtml: sourceHtml,
        translatedHtml: trimmedTranslation,
      );
      if (flattenedRestored != null) {
        return flattenedRestored;
      }
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

    final String translatedPlainText = _plainTextFromHtmlFragment(
      trimmedTranslation,
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
    return rebuiltRoot.outerHtml;
  }

  /// If [sourceHtml] contains `<span class="smallcaps">` nodes that the
  /// translation folded into a single plain text run, return a version of the
  /// source with those spans flattened so the skeletons match and the
  /// translation text can be restored positionally. Returns null when the
  /// flattened source still does not align with the translation.
  static String? _restoreWithFlattenedSmallcaps({
    required String sourceHtml,
    required String translatedHtml,
  }) {
    final dom.Element? sourceRoot = _singleRootElement(sourceHtml);
    final dom.Element? translatedRoot = _singleRootElement(translatedHtml);
    if (sourceRoot == null || translatedRoot == null) {
      return null;
    }
    // Flatten smallcaps spans in a clone of the source root.
    final dom.Element flattened = sourceRoot.clone(true);
    bool changed = false;
    for (final dom.Element span
        in flattened.querySelectorAll('span').toList(growable: false)) {
      final String cls = span.className.toLowerCase();
      if (!cls.split(RegExp(r'\s+')).contains('smallcaps')) {
        continue;
      }
      final List<dom.Node> children = span.nodes.toList(growable: false);
      for (final dom.Node child in children) {
        span.parentNode?.insertBefore(child.clone(true), span);
      }
      span.remove();
      changed = true;
    }
    if (!changed ||
        !_htmlStructureMatches(flattened.outerHtml, translatedHtml)) {
      return null;
    }
    final String? restored = _restoreProtectedTexts(
      sourceHtml: flattened.outerHtml,
      translatedHtml: translatedHtml,
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
    required dom.Element sourceRoot,
    required dom.Element translatedRoot,
    required List<dom.Text> trustedOverflowTexts,
  }) {
    final int sourceTextSlots = _textSlots(
      sourceRoot,
    ).where((_HtmlTextSlot slot) => !slot.protected).length;
    final List<_HtmlTextSlot> untrustedTranslatedSlots =
        _textSlots(translatedRoot)
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

  static String? _restoreProtectedTexts({
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
      return null;
    }

    for (int index = 0; index < sourceSlots.length; index += 1) {
      if (sourceSlots[index].protected) {
        translatedSlots[index].text = sourceSlots[index].text;
      }
    }
    return translatedRoot.outerHtml;
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
    required String sourceHtml,
    required String translatedHtml,
  }) {
    final dom.Element? sourceRoot = _singleRootElement(sourceHtml);
    final dom.Element? translatedRoot = _singleRootElement(translatedHtml);
    if (sourceRoot == null || translatedRoot == null) {
      return _NormalizedAnchorHtml(html: translatedHtml);
    }
    final List<String> overflowTexts = <String>[];
    final List<dom.Text> trustedOverflowTexts = <dom.Text>[];
    _normalizePairedProtectedAnchors(
      sourceRoot,
      translatedRoot,
      overflowTexts,
      trustedOverflowTexts,
    );
    return _NormalizedAnchorHtml(
      html: translatedRoot.outerHtml,
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
  ) {
    if (source.localName != translated.localName ||
        !_attributesMatch(source, translated)) {
      return;
    }

    final String sourceMarker = source.text.trim();
    if (_isProtectedTextElement(source) &&
        _isProtectedMarkerText(sourceMarker)) {
      _normalizeProtectedAnchor(
        source: source,
        translated: translated,
        sourceMarker: sourceMarker,
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
    final Set<String> roles = _roleTokens(element);
    final Set<String> epubTypes = _epubTypes(element);
    final bool protectedMarkerText = _isProtectedMarkerText(element.text);

    if ((roles.contains('doc-noteref') || epubTypes.contains('noteref')) &&
        protectedMarkerText) {
      return true;
    }
    if (roles.contains('doc-pagebreak') || epubTypes.contains('pagebreak')) {
      return _isProtectedPagebreakText(element.text);
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
    return (element.attributes['epub:type']?.toLowerCase() ?? '')
        .split(RegExp(r'\s+'))
        .where((String type) => type.isNotEmpty)
        .toSet();
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

  Future<Map<String, String>> _translateFootnoteBatch({
    required Dio dio,
    required TranslationConfig config,
    required FootnoteTranslationBatch batch,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
  }) async {
    final Set<String> requestedIds = batch.references
        .map((FootnoteBlockReference reference) => reference.requestId)
        .toSet();
    if (requestedIds.length != batch.references.length) {
      throw const FormatException(
        'Cross-file footnote request ids must be unique.',
      );
    }

    final List<FootnoteBlockReference> htmlReferences =
        <FootnoteBlockReference>[];
    final List<_ProtectedSlotRequest> slotRequests = <_ProtectedSlotRequest>[];
    for (final FootnoteBlockReference reference in batch.references) {
      if (!ProtectedAnchorTextSlots.containsProtectedAnchors(
        reference.block.sourceHtml,
      )) {
        htmlReferences.add(reference);
        continue;
      }
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        reference.block.sourceHtml,
      );
      if (template.hasProtectedAnchors) {
        slotRequests.add(
          _ProtectedSlotRequest(
            id: reference.requestId,
            block: reference.block,
            template: template,
          ),
        );
      }
    }

    final Map<String, String> translatedById = <String, String>{};
    if (htmlReferences.isNotEmpty) {
      try {
        translatedById.addAll(
          await _translateFootnoteHtmlBatch(
            dio: dio,
            config: config,
            references: htmlReferences,
            context: batch.context,
            retryDelayOverride: retryDelayOverride,
            cancelToken: cancelToken,
            onRequestAttempt: onRequestAttempt,
          ),
        );
      } on DioException catch (error) {
        if (TranslationApiClient.isConnectionTimeout(error)) {
          // A connection timeout is endpoint-wide rather than payload-size
          // related. The batch already retried once, so retain its source
          // blocks instead of multiplying the outage into per-block calls.
          for (final FootnoteBlockReference reference in htmlReferences) {
            degradedBlockIds.add(reference.block.id);
            translatedById[reference.requestId] = reference.block.sourceHtml;
          }
        } else {
          if (!TranslationApiClient.isReceiveTimeout(error)) {
            rethrow;
          }
          // A receive timeout on a large batch can be payload related. Retry
          // each reference independently; one that still times out degrades
          // to its source HTML and is reported with the run.
          for (final FootnoteBlockReference reference in htmlReferences) {
            try {
              translatedById.addAll(
                await _translateFootnoteHtmlBatch(
                  dio: dio,
                  config: config,
                  references: <FootnoteBlockReference>[reference],
                  context: batch.context,
                  retryDelayOverride: retryDelayOverride,
                  cancelToken: cancelToken,
                  onRequestAttempt: onRequestAttempt,
                ),
              );
            } on DioException catch (singleError) {
              if (!TranslationApiClient.isReceiveTimeout(singleError)) {
                rethrow;
              }
              degradedBlockIds.add(reference.block.id);
              translatedById[reference.requestId] = reference.block.sourceHtml;
            }
          }
        }
      }
    }
    if (slotRequests.isNotEmpty) {
      translatedById.addAll(
        await _translateProtectedSlotBatch(
          dio: dio,
          config: config,
          requests: slotRequests,
          context: batch.context,
          retryDelayOverride: retryDelayOverride,
          cancelToken: cancelToken,
          onRequestAttempt: onRequestAttempt,
        ),
      );
    }
    return <String, String>{
      for (final FootnoteBlockReference reference in batch.references)
        reference.requestId: translatedById[reference.requestId]!,
    };
  }

  Future<Map<String, String>> _translateFootnoteHtmlBatch({
    required Dio dio,
    required TranslationConfig config,
    required List<FootnoteBlockReference> references,
    required TranslationBatchContext context,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
  }) {
    final Set<String> requestedIds = references
        .map((FootnoteBlockReference reference) => reference.requestId)
        .toSet();
    final Map<String, dynamic> payloadMap = <String, dynamic>{
      if (!context.isEmpty) 'context': context.toJson(),
      'blocks': references
          .map(
            (FootnoteBlockReference reference) => <String, String>{
              'id': reference.requestId,
              'html': reference.block.sourceHtml,
            },
          )
          .toList(),
    };
    final String payload = jsonEncode(payloadMap);

    return _apiClient.runRetried<Map<String, String>>(
      config: config,
      retryDelayOverride: retryDelayOverride,
      shouldRetry: TranslationApiClient.shouldRetryBatchError,
      cancelToken: cancelToken,
      operation: () async {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        final TranslationStyleProfile batchStyleProfile =
            _styleProfileFromBookMemoryJson(context.bookMemory);
        final bool batchStyleConfirmed =
            _styleProfileConfirmedFromBookMemoryJson(context.bookMemory);
        final Map<String, dynamic> requestData = <String, dynamic>{
          'model': config.model,
          'temperature': 0.2,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content':
                  'You translate EPUB HTML fragments into ${config.targetLanguage}. The user payload may include a compact read-only bookMemory summary. Use that context only for terminology and style. Translate only items in "blocks". Return strict JSON only. Preserve every HTML tag, attribute, entity, footnote marker, link target, and inline emphasis. Translate only human-readable text. The response must be a JSON object with a "blocks" array. Each array item must contain exactly one original request "id" and the translated HTML in "html". Return every requested id exactly once.${_styleProfileInstruction(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${_apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}',
            },
            <String, String>{'role': 'user', 'content': payload},
          ],
        };
        onRequestAttempt?.call();
        final Response<dynamic> response = await _apiClient.postChatCompletions(
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
        final Object? rawBlocks = jsonPayload['blocks'];
        if (rawBlocks is! List<dynamic> ||
            rawBlocks.length != references.length) {
          throw const FormatException(
            'Translated footnote batch length does not match request length.',
          );
        }

        final Map<String, String> rawTranslatedById = <String, String>{};
        for (final Object? item in rawBlocks) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException(
              'Translated footnote batch item is not a JSON object.',
            );
          }
          final Object? rawId = item['id'];
          final Object? rawHtml = item['html'];
          if (rawId is! String ||
              rawId.isEmpty ||
              rawHtml is! String ||
              rawHtml.trim().isEmpty) {
            throw const FormatException(
              'Translated footnote batch item is missing id or html.',
            );
          }
          if (!requestedIds.contains(rawId)) {
            throw FormatException(
              'Translated footnote batch contains unknown id $rawId.',
            );
          }
          if (rawTranslatedById.containsKey(rawId)) {
            throw FormatException(
              'Translated footnote batch contains duplicate id $rawId.',
            );
          }
          rawTranslatedById[rawId] = rawHtml.trim();
        }

        final Map<String, String> translatedById = <String, String>{};
        for (final FootnoteBlockReference reference in references) {
          final String? translated = rawTranslatedById[reference.requestId];
          if (translated == null) {
            throw FormatException(
              'Translated footnote ${reference.requestId} is missing from the batch response.',
            );
          }
          final String locked = _lockTranslatedHtmlStructure(
            reference.block,
            translated,
          );
          _validateTranslatedBlockQuality(
            config: config,
            block: reference.block,
            translatedHtml: locked,
          );
          translatedById[reference.requestId] = locked;
        }
        return translatedById;
      },
    );
  }

  Future<Map<String, String>> _translateProtectedSlotBatch({
    required Dio dio,
    required TranslationConfig config,
    required List<_ProtectedSlotRequest> requests,
    required TranslationBatchContext context,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
  }) async {
    final Set<String> requestedIds = requests
        .map((_ProtectedSlotRequest request) => request.id)
        .toSet();
    if (requestedIds.length != requests.length) {
      throw const FormatException('Protected slot request ids must be unique.');
    }
    try {
      return await _translateProtectedSlotBatchOnce(
        dio: dio,
        config: config,
        requests: requests,
        context: context,
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
        onRequestAttempt: onRequestAttempt,
      );
    } on FormatException {
      if (requests.length == 1) {
        try {
          return await _translateProtectedSlotsIndividually(
            dio: dio,
            config: config,
            request: requests.single,
            context: context,
            retryDelayOverride: retryDelayOverride,
            cancelToken: cancelToken,
            onRequestAttempt: onRequestAttempt,
          );
        } on FormatException catch (error) {
          if (_isQualityRejection(error)) {
            degradedBlockIds.add(requests.single.block.id);
            return <String, String>{
              requests.single.id: requests.single.block.sourceHtml,
            };
          }
          rethrow;
        }
      }
    } on DioException catch (error) {
      if (_isCancelError(error)) {
        throw const TranslationCancelledException();
      }
      if (TranslationApiClient.isConnectionTimeout(error)) {
        degradedBlockIds.addAll(
          requests.map((_ProtectedSlotRequest request) => request.block.id),
        );
        return <String, String>{
          for (final _ProtectedSlotRequest request in requests)
            request.id: request.block.sourceHtml,
        };
      }
      if (TranslationApiClient.isReceiveTimeout(error) &&
          requests.length == 1) {
        degradedBlockIds.add(requests.single.block.id);
        return <String, String>{
          requests.single.id: requests.single.block.sourceHtml,
        };
      }
      if (!TranslationApiClient.shouldFallbackBatchDioException(error) ||
          requests.length == 1) {
        rethrow;
      }
    }

    final int midpoint = requests.length ~/ 2;
    final Map<String, String> left = await _translateProtectedSlotBatch(
      dio: dio,
      config: config,
      requests: requests.sublist(0, midpoint),
      context: context,
      retryDelayOverride: retryDelayOverride,
      cancelToken: cancelToken,
      onRequestAttempt: onRequestAttempt,
    );
    final Map<String, String> right = await _translateProtectedSlotBatch(
      dio: dio,
      config: config,
      requests: requests.sublist(midpoint),
      context: context,
      retryDelayOverride: retryDelayOverride,
      cancelToken: cancelToken,
      onRequestAttempt: onRequestAttempt,
    );
    return <String, String>{...left, ...right};
  }

  Future<Map<String, String>> _translateProtectedSlotBatchOnce({
    required Dio dio,
    required TranslationConfig config,
    required List<_ProtectedSlotRequest> requests,
    required TranslationBatchContext context,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
  }) {
    final Set<String> requestedIds = requests
        .map((_ProtectedSlotRequest request) => request.id)
        .toSet();
    final Map<String, _ProtectedSlotRequest> requestById =
        <String, _ProtectedSlotRequest>{
          for (final _ProtectedSlotRequest request in requests)
            request.id: request,
        };
    final String payload = jsonEncode(<String, Object?>{
      if (!context.isEmpty) 'context': context.toJson(),
      'blocks': requests
          .map((_ProtectedSlotRequest request) => request.toJson())
          .toList(growable: false),
    });

    return _apiClient.runRetried<Map<String, String>>(
      config: config,
      retryDelayOverride: retryDelayOverride,
      shouldRetry: TranslationApiClient.shouldRetryBatchError,
      cancelToken: cancelToken,
      operation: () async {
        if (cancelToken?.isCancelled ?? false) {
          throw const TranslationCancelledException();
        }
        final TranslationStyleProfile batchStyleProfile =
            _styleProfileFromBookMemoryJson(context.bookMemory);
        final bool batchStyleConfirmed =
            _styleProfileConfirmedFromBookMemoryJson(context.bookMemory);
        final Map<String, dynamic> requestData = <String, dynamic>{
          'model': config.model,
          'temperature': 0.2,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content':
                  'Translate only each slot "text" into ${config.targetLanguage}. Return strict JSON only, with exactly the requested block ids and slot ids. Every block must contain only "id" and "slots"; every slot must contain only string "id" and string "text"; never return HTML, tags, attributes, markdown, or explanations. Treat angle brackets in translated text as ordinary text.${_styleProfileInstruction(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${_apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}',
            },
            <String, String>{'role': 'user', 'content': payload},
          ],
        };
        onRequestAttempt?.call();
        final Response<dynamic> response = await _apiClient.postChatCompletions(
          dio: dio,
          data: requestData,
          cancelToken: cancelToken,
        );
        final Map<String, dynamic> jsonPayload = _apiClient.decodeJsonObject(
          _apiClient.extractMessageContent(response.data),
        );
        final Object? rawBlocks = jsonPayload['blocks'];
        if (rawBlocks is! List<dynamic> ||
            rawBlocks.length != requests.length) {
          throw const FormatException(
            'Translated slot block count does not match request count.',
          );
        }

        final Map<String, List<String>> translatedSlotsById =
            <String, List<String>>{};
        for (final Object? rawBlock in rawBlocks) {
          if (rawBlock is! Map<String, dynamic> ||
              rawBlock.keys.toSet().difference(const <String>{
                'id',
                'slots',
              }).isNotEmpty ||
              const <String>{
                'id',
                'slots',
              }.difference(rawBlock.keys.toSet()).isNotEmpty) {
            throw const FormatException(
              'Translated slot block must contain only id and slots.',
            );
          }
          final Object? rawId = rawBlock['id'];
          final Object? rawSlots = rawBlock['slots'];
          if (rawId is! String ||
              !requestedIds.contains(rawId) ||
              translatedSlotsById.containsKey(rawId)) {
            throw const FormatException(
              'Translated slot response contains an unknown or duplicate block id.',
            );
          }
          final _ProtectedSlotRequest request = requestById[rawId]!;
          if (rawSlots is! List<dynamic> ||
              rawSlots.length != request.template.slotTexts.length) {
            throw FormatException(
              'Translated slot count does not match block $rawId.',
            );
          }
          final Map<String, String> textBySlotId = <String, String>{};
          final Set<String> expectedSlotIds = request.slotIds.toSet();
          for (final Object? rawSlot in rawSlots) {
            if (rawSlot is! Map<String, dynamic> ||
                rawSlot.keys.toSet().difference(const <String>{
                  'id',
                  'text',
                }).isNotEmpty ||
                const <String>{
                  'id',
                  'text',
                }.difference(rawSlot.keys.toSet()).isNotEmpty) {
              throw const FormatException(
                'Translated slot must contain only id and text.',
              );
            }
            final Object? rawSlotId = rawSlot['id'];
            final Object? rawText = rawSlot['text'];
            if (rawSlotId is! String ||
                !expectedSlotIds.contains(rawSlotId) ||
                textBySlotId.containsKey(rawSlotId) ||
                rawText is! String) {
              throw const FormatException(
                'Translated slot contains an unknown or duplicate id, or non-string text.',
              );
            }
            textBySlotId[rawSlotId] = rawText;
          }
          translatedSlotsById[rawId] = request.slotIds
              .map((String slotId) => textBySlotId[slotId]!)
              .toList(growable: false);
        }

        return <String, String>{
          for (final _ProtectedSlotRequest request in requests)
            request.id: _renderAndValidateProtectedSlots(
              config: config,
              request: request,
              translatedSlots: translatedSlotsById[request.id]!,
            ),
        };
      },
    );
  }

  Future<Map<String, String>> _translateProtectedSlotsIndividually({
    required Dio dio,
    required TranslationConfig config,
    required _ProtectedSlotRequest request,
    required TranslationBatchContext context,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
  }) {
    return _apiClient.runRetried<Map<String, String>>(
      config: config,
      retryDelayOverride: retryDelayOverride,
      shouldRetry: TranslationApiClient.shouldRetryBatchError,
      cancelToken: cancelToken,
      operation: () => _translateProtectedSlotsIndividuallyOnce(
        dio: dio,
        config: config,
        request: request,
        context: context,
        cancelToken: cancelToken,
        onRequestAttempt: onRequestAttempt,
      ),
    );
  }

  Future<Map<String, String>> _translateProtectedSlotsIndividuallyOnce({
    required Dio dio,
    required TranslationConfig config,
    required _ProtectedSlotRequest request,
    required TranslationBatchContext context,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
  }) async {
    final List<String> translatedSlots = <String>[];
    for (final String sourceText in request.template.slotTexts) {
      translatedSlots.add(
        await _translateProtectedSlotTextOnce(
          dio: dio,
          config: config,
          sourceText: sourceText,
          context: context,
          cancelToken: cancelToken,
          onRequestAttempt: onRequestAttempt,
        ),
      );
    }
    return <String, String>{
      request.id: _renderAndValidateProtectedSlots(
        config: config,
        request: request,
        translatedSlots: translatedSlots,
      ),
    };
  }

  Future<String> _translateProtectedSlotTextOnce({
    required Dio dio,
    required TranslationConfig config,
    required String sourceText,
    required TranslationBatchContext context,
    CancelToken? cancelToken,
    void Function()? onRequestAttempt,
  }) async {
    final String trimmedSource = sourceText.trim();
    if (cancelToken?.isCancelled ?? false) {
      throw const TranslationCancelledException();
    }
    final TranslationStyleProfile batchStyleProfile =
        _styleProfileFromBookMemoryJson(context.bookMemory);
    final bool batchStyleConfirmed = _styleProfileConfirmedFromBookMemoryJson(
      context.bookMemory,
    );
    final Map<String, dynamic> requestData = <String, dynamic>{
      'model': config.model,
      'temperature': 0.2,
      'messages': <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content':
              'Translate the user text into ${config.targetLanguage}. Return only the translated text, with no JSON, HTML, Markdown formatting, labels, or explanation.${_styleProfileInstruction(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${_apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}',
        },
        <String, String>{'role': 'user', 'content': trimmedSource},
      ],
    };
    onRequestAttempt?.call();
    final Response<dynamic> response = await _apiClient.postChatCompletions(
      dio: dio,
      data: requestData,
      cancelToken: cancelToken,
    );
    final String translated = _apiClient.extractMessageContent(response.data);
    _validateIndividualSlotTranslation(
      sourceText: trimmedSource,
      translatedText: translated,
    );
    return translated.trim();
  }

  static void _validateIndividualSlotTranslation({
    required String sourceText,
    required String translatedText,
  }) {
    final String trimmed = translatedText.trim();
    if (trimmed.isEmpty) {
      throw const FormatException(
        'Individual protected slot translation is empty.',
      );
    }
    if (trimmed.contains('```') ||
        _hasUnexpectedJsonWrapper(
          sourceText: sourceText,
          translatedText: trimmed,
        ) ||
        _hasMarkdownWrapper(trimmed) ||
        RegExp(r'<!--[\s\S]*?-->').hasMatch(trimmed) ||
        RegExp(r'<\s*/?\s*[A-Za-z][^>]*>').hasMatch(trimmed) ||
        _hasTranslationExplanationPrefix(trimmed)) {
      throw const FormatException(
        'Individual protected slot translation contains wrapper content.',
      );
    }
  }

  static bool _hasMarkdownWrapper(String value) {
    if (RegExp(r'^`{1,2}[\s\S]+`{1,2}$').hasMatch(value) ||
        RegExp(r'^~~[\s\S]+~~$').hasMatch(value) ||
        RegExp(r'^\*\*[\s\S]+\*\*$').hasMatch(value) ||
        RegExp(r'^__[\s\S]+__$').hasMatch(value) ||
        RegExp(r'^\*[\s\S]+\*$').hasMatch(value) ||
        RegExp(r'^_[\s\S]+_$').hasMatch(value) ||
        RegExp(r'!?\[[^\]\r\n]+\]\([^\)\r\n]+\)').hasMatch(value)) {
      return true;
    }
    return value
        .split(RegExp(r'\r?\n'))
        .any(
          (String line) =>
              RegExp(r'^\s*(?:#{1,6}|>|[-+*]|\d+[.)])\s+').hasMatch(line) ||
              RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line) ||
              RegExp(r'^\s*\|.*\|\s*$').hasMatch(line),
        );
  }

  static bool _hasTranslationExplanationPrefix(String value) {
    return RegExp(
          r'^(?:(?:好的|当然|可以|没问题)[，,。.!！\s]*)?(?:(?:以下|下面)是)?(?:译文|翻译(?:结果|内容)?)(?:如下)?\s*[:：]',
        ).hasMatch(value) ||
        RegExp(
          r"^(?:(?:sure|certainly|of course|okay|ok)[,!.]?\s*)?(?:here(?:'s| is)\s+)?(?:the\s+)?(?:translation|translated text)(?:\s+is)?\s*[:：]",
          caseSensitive: false,
        ).hasMatch(value);
  }

  static bool _hasUnexpectedJsonWrapper({
    required String sourceText,
    required String translatedText,
  }) {
    if (!RegExp(
      r'^[\[{"\d\-]|^(?:true|false|null)$',
    ).hasMatch(translatedText)) {
      return false;
    }
    try {
      final Object? decoded = jsonDecode(translatedText);
      if (decoded is String) {
        final String source = sourceText.trim();
        return !(source.startsWith('"') && source.endsWith('"'));
      }
      return true;
    } on FormatException {
      return false;
    }
  }

  static String _renderAndValidateProtectedSlots({
    required TranslationConfig config,
    required _ProtectedSlotRequest request,
    required List<String> translatedSlots,
  }) {
    final String rendered = request.template.render(translatedSlots);
    _validateTranslatedBlockQuality(
      config: config,
      block: request.block,
      translatedHtml: rendered,
    );
    return rendered;
  }

  Future<List<String>> _translateBlockBatch({
    required Dio dio,
    required TranslationConfig config,
    required TranslationBlockBatch batch,
    Duration? retryDelayOverride,
    CancelToken? cancelToken,
  }) async {
    final List<ExtractedBlock> htmlBlocks = <ExtractedBlock>[];
    final List<_ProtectedSlotRequest> slotRequests = <_ProtectedSlotRequest>[];
    for (final ExtractedBlock block in batch.blocks) {
      if (!ProtectedAnchorTextSlots.containsProtectedAnchors(
        block.sourceHtml,
      )) {
        htmlBlocks.add(block);
        continue;
      }
      final ProtectedAnchorTextSlots template = ProtectedAnchorTextSlots.parse(
        block.sourceHtml,
      );
      if (template.hasProtectedAnchors) {
        slotRequests.add(
          _ProtectedSlotRequest(id: block.id, block: block, template: template),
        );
      }
    }

    final Map<String, String> translatedById = <String, String>{};
    if (htmlBlocks.isNotEmpty) {
      final List<String> translatedHtml = await _translateHtmlBlockBatch(
        dio: dio,
        config: config,
        batch: TranslationBlockBatch(htmlBlocks, context: batch.context),
        retryDelayOverride: retryDelayOverride,
        cancelToken: cancelToken,
      );
      for (int index = 0; index < htmlBlocks.length; index += 1) {
        translatedById[htmlBlocks[index].id] = translatedHtml[index];
      }
    }
    if (slotRequests.isNotEmpty) {
      translatedById.addAll(
        await _translateProtectedSlotBatch(
          dio: dio,
          config: config,
          requests: slotRequests,
          context: batch.context,
          retryDelayOverride: retryDelayOverride,
          cancelToken: cancelToken,
        ),
      );
    }
    return batch.blocks
        .map((ExtractedBlock block) => translatedById[block.id]!)
        .toList(growable: false);
  }

  Future<List<String>> _translateHtmlBlockBatch({
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
          final TranslationStyleProfile batchStyleProfile =
              _styleProfileFromBookMemoryJson(batch.context.bookMemory);
          final bool batchStyleConfirmed =
              _styleProfileConfirmedFromBookMemoryJson(
                batch.context.bookMemory,
              );
          final Map<String, dynamic> requestData = <String, dynamic>{
            'model': config.model,
            'temperature': 0.2,
            'messages': <Map<String, String>>[
              <String, String>{
                'role': 'system',
                'content':
                    'You translate EPUB HTML fragments into ${config.targetLanguage}. The user payload may include read-only context before and after the requested blocks plus a compact bookMemory summary of earlier chapters. Use that context only for continuity, pronouns, tone, terminology, and paragraph flow. Translate only items in "blocks"; never include context items in the response. Return strict JSON only. Preserve every HTML tag, attribute, entity, footnote marker, and inline emphasis. Translate only human-readable text. The response must be a JSON object with a "blocks" array. Each array item must contain the original "id" and the translated HTML in "html". Do not omit any block and keep the same order.${_styleProfileInstruction(config: config, styleProfile: batchStyleProfile, confirmed: batchStyleConfirmed)}${_apiClient.lockedGlossaryInstruction(config)}${_terminologyGlossInstruction(config: config)}',
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
      if (TranslationApiClient.isConnectionTimeout(error)) {
        degradedBlockIds.addAll(
          batch.blocks.map((ExtractedBlock block) => block.id),
        );
        return batch.blocks
            .map((ExtractedBlock block) => block.sourceHtml)
            .toList(growable: false);
      }
      if (TranslationApiClient.shouldFallbackBatchDioException(error)) {
        final TranslationStyleProfile fallbackStyleProfile =
            _styleProfileFromBookMemoryJson(batch.context.bookMemory);
        final bool fallbackConfirmed = _styleProfileConfirmedFromBookMemoryJson(
          batch.context.bookMemory,
        );
        return Future.wait<String>(
          batch.blocks.map(
            (ExtractedBlock block) => _translateBlock(
              dio: dio,
              config: config,
              block: block,
              cancelToken: cancelToken,
              styleProfile: fallbackStyleProfile,
              styleProfileConfirmed: fallbackConfirmed,
            ),
          ),
        );
      }
      rethrow;
    } on FormatException catch (_) {
      final TranslationStyleProfile fallbackStyleProfile =
          _styleProfileFromBookMemoryJson(batch.context.bookMemory);
      final bool fallbackConfirmed = _styleProfileConfirmedFromBookMemoryJson(
        batch.context.bookMemory,
      );
      return Future.wait<String>(
        batch.blocks.map(
          (ExtractedBlock block) => _translateBlock(
            dio: dio,
            config: config,
            block: block,
            cancelToken: cancelToken,
            styleProfile: fallbackStyleProfile,
            styleProfileConfirmed: fallbackConfirmed,
          ),
        ),
      );
    }
  }

  TranslationStyleProfile _styleProfileFromBookMemoryJson(
    Map<String, Object?>? bookMemory,
  ) {
    if (bookMemory == null) {
      return TranslationStyleProfile.empty;
    }
    final Object? raw = bookMemory['styleProfile'];
    if (raw is Map<String, Object?>) {
      return TranslationStyleProfile.fromJson(raw);
    }
    if (raw is Map) {
      return TranslationStyleProfile.fromJson(
        raw.map(
          (dynamic key, dynamic value) =>
              MapEntry<String, Object?>(key.toString(), value),
        ),
      );
    }
    return TranslationStyleProfile.empty;
  }

  bool _styleProfileConfirmedFromBookMemoryJson(
    Map<String, Object?>? bookMemory,
  ) {
    if (bookMemory == null) {
      return false;
    }
    final Object? raw = bookMemory['styleProfileConfirmed'];
    return raw == true;
  }

  String _styleProfileInstruction({
    required TranslationConfig config,
    TranslationStyleProfile? styleProfile,
    bool confirmed = false,
  }) {
    if (!config.styleProfileEnabled) {
      return '';
    }
    final TranslationStyleProfile? profile = styleProfile;
    if (profile == null || profile.isEmpty) {
      return '';
    }
    if (confirmed) {
      return profile.toConfirmedPromptInstruction(
        targetLanguage: config.targetLanguage,
      );
    }
    return profile.toPromptInstruction(targetLanguage: config.targetLanguage);
  }

  /// Terminology gloss rule that applies to every translation path.
  ///
  /// For CJK targets (mainly Chinese), a term that is hard to transliterate and
  /// carries real historical/technical meaning (for example "assarting") should
  /// be translated and, on its FIRST occurrence in the book, kept in the
  /// original language inside full-width parentheses as a gloss. Later
  /// occurrences use only the translated form. This helps preserve semantic
  /// precision without leaving bare source-language tokens flagged by the
  /// residual-quality check.
  String _terminologyGlossInstruction({required TranslationConfig config}) {
    if (!_isCjkTargetLanguage(config.targetLanguage)) {
      return '';
    }
    return ' For a term that is hard to transliterate and carries real '
        'historical or technical meaning (for example "assarting" meaning '
        '"clearing forest land"), translate it into ${config.targetLanguage} '
        'and, on its first occurrence in the book, keep the original term '
        'inside full-width parentheses as a gloss, for example '
        'assarting（伐林开垦）. On later occurrences use only the translated '
        'form without parentheses. Keep the gloss term inside the same inline '
        'text run and exact same element as the translated term would occupy.';
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
        TranslationQuality.findSuspiciousHtmlResidual(
          sourceHtml: block.sourceHtml,
          translatedHtml: translatedHtml,
          targetLanguage: config.targetLanguage,
          allowRetainedAuthorSignature: block.isAuthorSignature,
          allowBibliographicRetention: isBibliographicEntry,
        );
    if (finding == null) {
      return;
    }

    throw FormatException(finding.messageForBlock(block.id));
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
    TranslationStyleProfile? confirmedStyleProfile,
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
    TranslationStyleProfile? confirmedStyleProfile,
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
              config.styleProfileEnabled,
              _styleProfileCacheValue(confirmedStyleProfile),
              chapterPath,
              block.sourceHtml,
              if (block.isAuthorSignature) 'author-signature-v1',
            ].join('|'),
          ),
        )
        .toString();
  }

  static String _styleProfileCacheValue(
    TranslationStyleProfile? confirmedStyleProfile,
  ) {
    if (confirmedStyleProfile == null || confirmedStyleProfile.isEmpty) {
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
        (!sourceHtml.contains('dropcap') && !sourceHtml.contains('small'))) {
      return sourceHtml;
    }
    final dom.DocumentFragment fragment = html_parser.parseFragment(sourceHtml);
    bool changed = false;
    final List<dom.Element> spans = fragment
        .querySelectorAll('span[class]')
        .toList(growable: false);
    for (final dom.Element span in spans) {
      if (_isInsideFootnoteMarkerAnchor(span)) {
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
      _unwrapElement(span);
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
    final String normalized = targetLanguage.trim().toLowerCase();
    return normalized.contains('chinese') ||
        normalized.contains('japanese') ||
        normalized.contains('korean') ||
        normalized.contains('中文') ||
        normalized.contains('汉语') ||
        normalized.contains('漢語') ||
        normalized.contains('日语') ||
        normalized.contains('日語') ||
        normalized.contains('韩语') ||
        normalized.contains('韓語');
  }

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

class _NormalizedAnchorHtml {
  const _NormalizedAnchorHtml({
    required this.html,
    this.root,
    this.hasOverflow = false,
    this.trustedOverflowTexts = const <dom.Text>[],
  });

  final String html;
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

class _BookMemory {
  const _BookMemory({
    this.bookSummary = '',
    this.styleGuide = const <String>[],
    this.glossary = const <Map<String, String>>[],
    this.recentChapters = const <_ChapterMemory>[],
    this.styleProfile = TranslationStyleProfile.empty,
    this.styleProfileConfirmed = false,
  });

  static const _BookMemory empty = _BookMemory();

  factory _BookMemory.fromJson(Map<String, Object?> json) {
    final Object? rawStyleProfile = json['styleProfile'];
    final TranslationStyleProfile styleProfile =
        rawStyleProfile is Map<String, Object?>
        ? TranslationStyleProfile.fromJson(rawStyleProfile)
        : rawStyleProfile is Map
        ? TranslationStyleProfile.fromJson(
            rawStyleProfile.map(
              (dynamic key, dynamic value) =>
                  MapEntry<String, Object?>(key.toString(), value),
            ),
          )
        : TranslationStyleProfile.empty;
    return _BookMemory(
      bookSummary: _stringValue(json['bookSummary']),
      styleGuide: _stringList(
        json['styleGuide'],
        limit: EpubChapterTranslator._memoryListLimit,
      ),
      glossary: _glossaryList(json['glossary']),
      recentChapters: _chapterMemoryList(json['recentChapters']),
      styleProfile: styleProfile,
      styleProfileConfirmed: json['styleProfileConfirmed'] == true,
    );
  }

  final String bookSummary;
  final List<String> styleGuide;
  final List<Map<String, String>> glossary;
  final List<_ChapterMemory> recentChapters;
  final TranslationStyleProfile styleProfile;
  final bool styleProfileConfirmed;

  bool get isEmpty =>
      bookSummary.trim().isEmpty &&
      styleGuide.isEmpty &&
      glossary.isEmpty &&
      recentChapters.isEmpty &&
      styleProfile.isEmpty;

  _BookMemory copyWith({
    String? bookSummary,
    List<String>? styleGuide,
    List<Map<String, String>>? glossary,
    List<_ChapterMemory>? recentChapters,
    TranslationStyleProfile? styleProfile,
    bool? styleProfileConfirmed,
    bool clearStyleProfile = false,
  }) {
    return _BookMemory(
      bookSummary: bookSummary ?? this.bookSummary,
      styleGuide: styleGuide ?? this.styleGuide,
      glossary: glossary ?? this.glossary,
      recentChapters: recentChapters ?? this.recentChapters,
      styleProfile: clearStyleProfile
          ? TranslationStyleProfile.empty
          : (styleProfile ?? this.styleProfile),
      styleProfileConfirmed: clearStyleProfile
          ? false
          : (styleProfileConfirmed ?? this.styleProfileConfirmed),
    );
  }

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
      styleProfile: styleProfile,
      styleProfileConfirmed: styleProfileConfirmed,
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
      if (!styleProfile.isEmpty) 'styleProfile': styleProfile.toJson(),
      if (styleProfileConfirmed) 'styleProfileConfirmed': true,
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

class _ProtectedSlotRequest {
  const _ProtectedSlotRequest({
    required this.id,
    required this.block,
    required this.template,
  });

  final String id;
  final ExtractedBlock block;
  final ProtectedAnchorTextSlots template;

  List<String> get slotIds => List<String>.generate(
    template.slotTexts.length,
    (int index) => 's$index',
    growable: false,
  );

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'slots': <Map<String, String>>[
        for (int index = 0; index < template.slotTexts.length; index += 1)
          <String, String>{'id': 's$index', 'text': template.slotTexts[index]},
      ],
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
