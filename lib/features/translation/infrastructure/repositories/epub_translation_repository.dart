import 'package:dio/dio.dart';

import '../../domain/models/inspected_chapter.dart';
import '../../domain/models/inspection_result.dart';
import '../../domain/models/translation_config.dart';
import '../../domain/models/translation_run_result.dart';
import '../../domain/repositories/translation_repository.dart';
import '../epub/epub_chapter_translator.dart';
import '../epub/epub_inspector.dart';
import '../epub/epub_repacker.dart';
import '../translation_cache_store.dart';

/// Facade that wires [EpubInspector], [EpubChapterTranslator], and [EpubRepacker].
///
/// Public API stays stable for Riverpod / tests while heavy work lives in the
/// three focused collaborators.
class EpubTranslationRepository implements TranslationRepository {
  EpubTranslationRepository({
    TranslationCacheStore? cacheStore,
    EpubInspector? inspector,
    EpubChapterTranslator? translator,
    EpubRepacker? repacker,
  }) : this._(
         cacheStore: cacheStore ?? TranslationCacheStore(),
         inspector: inspector ?? EpubInspector(),
         repacker: repacker ?? EpubRepacker(),
         translator: translator,
       );

  EpubTranslationRepository._({
    required this._cacheStore,
    required this._inspector,
    required this._repacker,
    EpubChapterTranslator? translator,
  }) : _translator =
           translator ??
           EpubChapterTranslator(cacheStore: _cacheStore, repacker: _repacker);

  final TranslationCacheStore _cacheStore;
  final EpubInspector _inspector;
  final EpubChapterTranslator _translator;
  final EpubRepacker _repacker;
  CancelToken? _activeCancelToken;

  // Expose collaborators for advanced tests / diagnostics.
  TranslationCacheStore get cacheStore => _cacheStore;
  EpubInspector get inspector => _inspector;
  EpubChapterTranslator get translator => _translator;
  EpubRepacker get repacker => _repacker;

  /// Test seams — delegated to [EpubChapterTranslator].
  static bool shouldFallbackBatchDioExceptionForTest(DioException error) {
    return EpubChapterTranslator.shouldFallbackBatchDioExceptionForTest(error);
  }

  static String sanitizeOutputSuffixForTest(String suffix) {
    return EpubChapterTranslator.sanitizeOutputSuffixForTest(suffix);
  }

  static bool htmlStructureMatchesForTest({
    required String sourceHtml,
    required String translatedHtml,
  }) {
    return EpubChapterTranslator.htmlStructureMatchesForTest(
      sourceHtml: sourceHtml,
      translatedHtml: translatedHtml,
    );
  }

  static String lockHtmlStructureForTest({
    required String sourceHtml,
    required String translatedHtml,
  }) {
    return EpubChapterTranslator.lockHtmlStructureForTest(
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
    return EpubChapterTranslator.batchPlanForTest(
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
    return _translator.translateBlockBatchForTest(
      dio: dio,
      config: config,
      blocks: blocks,
      chapterTitle: chapterTitle,
      contextBefore: contextBefore,
      contextAfter: contextAfter,
      bookMemory: bookMemory,
    );
  }

  Future<Map<String, Object?>> generateInitialBookMemoryForTest({
    required Dio dio,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
  }) {
    return _translator.generateInitialBookMemoryForTest(
      dio: dio,
      config: config,
      chapters: chapters,
    );
  }

  Future<Map<String, Object?>> updateBookMemoryAfterChapterForTest({
    required Dio dio,
    required TranslationConfig config,
    required Map<String, Object?> currentMemory,
    required InspectedChapter chapter,
  }) {
    return _translator.updateBookMemoryAfterChapterForTest(
      dio: dio,
      config: config,
      currentMemory: currentMemory,
      chapter: chapter,
    );
  }

  @override
  Future<void> cancelJob(String jobId) async {
    final CancelToken? token = _activeCancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel('Job cancelled: $jobId');
    }
  }

  CancelToken _beginCancellableRun() {
    final CancelToken? previous = _activeCancelToken;
    if (previous != null && !previous.isCancelled) {
      previous.cancel('Superseded by a new run');
    }
    final CancelToken token = CancelToken();
    _activeCancelToken = token;
    return token;
  }

  void _clearCancelTokenIfCurrent(CancelToken token) {
    if (identical(_activeCancelToken, token)) {
      _activeCancelToken = null;
    }
  }

  static bool _isCancelError(Object error) {
    return error is DioException && CancelToken.isCancel(error);
  }

  @override
  Future<String> testConnection({required TranslationConfig config}) {
    return _translator.testConnection(config: config);
  }

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    final CancelToken cancelToken = _beginCancellableRun();
    try {
      return await _inspector.inspect(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        cancelToken: cancelToken,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } on TranslationCancelledException {
      rethrow;
    } catch (error) {
      if (_isCancelError(error) || (isCancelled?.call() ?? false)) {
        throw const TranslationCancelledException();
      }
      rethrow;
    } finally {
      _clearCancelTokenIfCurrent(cancelToken);
    }
  }

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    final CancelToken cancelToken = _beginCancellableRun();
    try {
      return await _translator.translateChapters(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        config: config,
        chapters: chapters,
        cancelToken: cancelToken,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    } on TranslationCancelledException {
      rethrow;
    } catch (error) {
      if (_isCancelError(error) || (isCancelled?.call() ?? false)) {
        throw const TranslationCancelledException();
      }
      rethrow;
    } finally {
      _clearCancelTokenIfCurrent(cancelToken);
    }
  }
}
