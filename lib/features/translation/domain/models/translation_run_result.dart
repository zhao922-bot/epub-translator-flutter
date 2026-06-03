import 'inspected_chapter.dart';
import 'translation_job.dart';

class TranslationRunResult {
  const TranslationRunResult({required this.job, required this.chapters});

  final TranslationJob job;
  final List<InspectedChapter> chapters;
}
