import '../models/inspection_result.dart';
import '../models/inspected_chapter.dart';
import '../models/translation_config.dart';
import '../models/translation_job.dart';
import '../models/translation_run_result.dart';
import '../models/translation_style_profile.dart';

typedef TranslationProgressCallback =
    void Function(TranslationJob job, String logLine);

typedef TranslationCancellationCheck = bool Function();

class TranslationCancelledException implements Exception {
  const TranslationCancelledException();

  @override
  String toString() => 'Translation was cancelled.';
}

abstract class TranslationRepository {
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  });

  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
    // Fired on the calling isolate each time a finished chapter's source
    // strings are spooled to disk and released from the worker's lists, so
    // UI-side holders (e.g. the dashboard's inspected chapters) can drop
    // their own references instead of retaining the whole book in memory.
    void Function(String chapterPath)? onChapterSourcesReleased,
  });

  /// Infer a book style profile from front matter / early chapters before translation.
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  });

  Future<String> testConnection({required TranslationConfig config});

  Future<void> cancelJob(String jobId);
}
