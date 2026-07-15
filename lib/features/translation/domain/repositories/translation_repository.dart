import '../models/inspection_result.dart';
import '../models/inspected_chapter.dart';
import '../models/translation_config.dart';
import '../models/translation_job.dart';
import '../models/translation_run_result.dart';

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
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  });

  Future<String> testConnection({required TranslationConfig config});

  Future<void> cancelJob(String jobId);
}
