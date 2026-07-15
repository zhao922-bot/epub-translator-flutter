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
    this.canResume = false,
    this.phaseLabel = '',
  });

  final String id;
  final String title;
  final String status;
  final String progressLabel;
  final String outputPath;
  final String? errorMessage;
  final bool isActive;
  final bool canOpenOutput;
  final bool canRetry;
  final bool canResume;
  final String phaseLabel;
}
