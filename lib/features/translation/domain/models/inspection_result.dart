import 'inspected_chapter.dart';
import 'translation_job.dart';

class InspectionResult {
  const InspectionResult({required this.job, required this.chapters});

  final TranslationJob job;
  final List<InspectedChapter> chapters;
}
