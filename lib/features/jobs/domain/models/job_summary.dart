import '../../../translation/domain/models/translation_job.dart';

class JobSummary {
  const JobSummary({
    required this.id,
    required this.title,
    required this.status,
    required this.progressLabel,
    required this.outputPath,
    required this.errorMessage,
    required this.isActive,
    required this.canOpenOutput,
    required this.canRetry,
    this.retryBlocked = false,
    this.canResume = false,
    this.phaseLabel = '',
    this.degradedBlockCount = 0,
  });

  final String id;
  final String title;
  final TranslationJobStatus status;
  final String progressLabel;
  final String outputPath;
  final String? errorMessage;
  final bool isActive;
  final bool canOpenOutput;
  final bool canRetry;

  /// True while another run is active: the retry button stays tappable but
  /// explains via snackbar instead of silently no-op'ing in the controller.
  final bool retryBlocked;
  final bool canResume;
  final String phaseLabel;
  final int degradedBlockCount;

  bool get hasWarnings => status == TranslationJobStatus.completedWithWarnings;
}
