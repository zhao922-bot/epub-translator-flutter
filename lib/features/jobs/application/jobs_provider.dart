import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../../translation/application/translation_dashboard_controller.dart';
import '../../translation/domain/models/translation_job.dart';
import '../domain/models/job_summary.dart';

final jobsProvider = Provider<List<JobSummary>>((ref) {
  final TranslationDashboardState dashboard = ref.watch(
    translationDashboardProvider,
  );
  final TranslationJob? currentJob = dashboard.job;
  final Set<String> includedIds = <String>{};
  final List<TranslationJob> jobs = <TranslationJob>[
    ?currentJob,
    ...dashboard.jobHistory.where((TranslationJob job) {
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
          status: _statusLabel(job.status),
          progressLabel: _progressLabel(job),
          outputPath: job.outputPath,
          errorMessage: job.errorMessage,
          isActive:
              job.status == TranslationJobStatus.queued ||
              job.status == TranslationJobStatus.running,
          canOpenOutput: job.hasExportableEpub,
          canRetry:
              job.status == TranslationJobStatus.failed ||
              job.status == TranslationJobStatus.cancelled,
          canResume: job.canResumeTranslation,
          phaseLabel: phaseLabel(job.phase),
        ),
      )
      .toList(growable: false);
});

String _statusLabel(TranslationJobStatus status) {
  return switch (status) {
    TranslationJobStatus.idle => 'Idle',
    TranslationJobStatus.queued => 'Queued',
    TranslationJobStatus.running => 'Running',
    TranslationJobStatus.inspected => 'Inspected',
    TranslationJobStatus.cancelled => 'Cancelled',
    TranslationJobStatus.failed => 'Failed',
    TranslationJobStatus.completed => 'Completed',
  };
}

String phaseLabel(TranslationJobPhase phase) {
  return switch (phase) {
    TranslationJobPhase.inspection => 'Inspection',
    TranslationJobPhase.translation => 'Translation',
  };
}

String _progressLabel(TranslationJob job) {
  if (job.totalBlocks > 0) {
    return '${job.completedBlocks} / ${job.totalBlocks} blocks';
  }
  if (job.totalFiles > 0) {
    return '${job.completedFiles} / ${job.totalFiles} chapters';
  }
  final int percent = (job.progress * 100).round().clamp(0, 100);
  return '$percent% complete';
}
