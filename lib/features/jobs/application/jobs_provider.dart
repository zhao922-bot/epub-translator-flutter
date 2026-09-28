import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../../shared/localization/app_strings.dart';
import '../../translation/application/translation_dashboard_controller.dart';
import '../../translation/domain/models/translation_job.dart';
import '../domain/models/job_summary.dart';

final jobsProvider = Provider<List<JobSummary>>((ref) {
  // Only the fields the job list actually renders are selected: a plain
  // watch of the whole dashboard state rebuilt this page on every log tick.
  final (
    :TranslationJob? job,
    :List<TranslationJob> jobHistory,
    :bool isRunActive,
  ) = ref.watch(
    translationDashboardProvider.select(
      (TranslationDashboardState dashboard) => (
        job: dashboard.job,
        jobHistory: dashboard.jobHistory,
        isRunActive: dashboard.isRunActive,
      ),
    ),
  );
  final AppStrings strings = ref.watch(appStringsProvider);
  final TranslationJob? currentJob = job;
  final Set<String> includedIds = <String>{};
  final List<TranslationJob> jobs = <TranslationJob>[
    ?currentJob,
    ...jobHistory.where((TranslationJob job) {
      if (currentJob != null && job.id == currentJob.id) {
        return false;
      }
      return includedIds.add(job.id);
    }),
  ];

  return jobs
      .map(
        (TranslationJob job) => JobSummary(
          id: job.id,
          title: path.basename(job.inputPath),
          status: job.status,
          progressLabel: _progressLabel(job, strings),
          outputPath: job.outputPath,
          errorMessage: job.errorMessage,
          isActive:
              job.status == TranslationJobStatus.queued ||
              job.status == TranslationJobStatus.running,
          canOpenOutput: job.hasExportableEpub,
          canRetry:
              job.status == TranslationJobStatus.failed ||
              job.status == TranslationJobStatus.cancelled ||
              job.status == TranslationJobStatus.completedWithWarnings,
          // While a run is active the controller's _retryJob only appends a
          // log line the Jobs page never shows; surface it here instead.
          retryBlocked: isRunActive,
          canResume: job.canResumeTranslation,
          degradedBlockCount: job.degradedBlockCount,
        ),
      )
      .toList(growable: false);
});

String _progressLabel(TranslationJob job, AppStrings strings) {
  if (job.totalBlocks > 0) {
    return strings.jobProgressBlocks(job.completedBlocks, job.totalBlocks);
  }
  if (job.totalFiles > 0) {
    return strings.jobProgressChapters(job.completedFiles, job.totalFiles);
  }
  final int percent = (job.progress * 100).round().clamp(0, 100);
  return strings.jobProgressPercent(percent);
}
