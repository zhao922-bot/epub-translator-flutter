import 'inspected_chapter.dart';
import 'translation_job.dart';

class InspectionResult {
  const InspectionResult({
    required this.job,
    required this.chapters,
    this.warnings = const <String>[],
  });

  final TranslationJob job;
  final List<InspectedChapter> chapters;

  /// Non-fatal problems found during inspection (e.g. spine entries whose
  /// files are missing from the archive). The book is still usable; these
  /// are surfaced so the user knows why fewer chapters were found.
  final List<String> warnings;
}
