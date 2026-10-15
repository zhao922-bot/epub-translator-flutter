import 'inspected_chapter.dart';
import 'translation_job.dart';

class TranslationRunResult {
  const TranslationRunResult({
    required this.job,
    required this.chapters,
    this.apiUsage = const {},
    this.qualityReportPath,
  });

  final TranslationJob job;
  final List<InspectedChapter> chapters;
  final Map<String, Object> apiUsage;
  final String? qualityReportPath;
}
