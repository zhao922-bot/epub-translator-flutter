import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../shared/localization/app_strings.dart';
import '../domain/models/translation_job.dart';

/// Job lookup, interruption display, and cross-instance history merging.
abstract final class DashboardJobHistoryHelper {
  static TranslationJob? findKnownJob(
    String jobId, {
    required TranslationJob? currentJob,
    required List<TranslationJob> jobHistory,
  }) {
    if (currentJob?.id == jobId) {
      return currentJob;
    }
    for (final TranslationJob job in jobHistory) {
      if (job.id == jobId) {
        return job;
      }
    }
    return null;
  }

  static String outputDirectoryForRetry(
    TranslationJob job, {
    required String fallbackDirectory,
  }) {
    if (job.outputDirectory.isNotEmpty) {
      return job.outputDirectory;
    }
    if (job.outputPath.isEmpty) {
      return fallbackDirectory;
    }
    final type = FileSystemEntity.typeSync(job.outputPath);
    if (type == FileSystemEntityType.file) {
      return path.dirname(job.outputPath);
    }
    // An absent path could be either a former file or an intended directory.
    // Preserve it rather than silently redirecting an export to its parent.
    return job.outputPath;
  }

  static TranslationJob restoreInterruptedJob(
    TranslationJob job, {
    required AppStrings strings,
    required bool isTranslationPhase,
  }) {
    return job.copyWith(
      status: TranslationJobStatus.cancelled,
      currentChapter: isTranslationPhase
          ? strings.jobStatusTranslationInterrupted
          : strings.jobStatusInspectionInterrupted,
      currentBlock: null,
      // Note: the retry heuristic reads `phase`, not this display string,
      // so currentChapter is safe to localize.
      errorMessage: strings.jobInterruptedOnRestart,
    );
  }

  static List<TranslationJob> mergeHistorySnapshots(
    List<TranslationJob> memoryJobs,
    List<TranslationJob> fileJobs,
  ) {
    // A new run supersedes every snapshot of the old one. Within one run,
    // terminal states outrank in-flight snapshots; revisions break ties so
    // a stale instance cannot roll back progress within the same status.
    int priority(TranslationJob job) => switch (job.status) {
      TranslationJobStatus.completed => 5,
      TranslationJobStatus.completedWithWarnings => 4,
      TranslationJobStatus.failed ||
      TranslationJobStatus.cancelled ||
      TranslationJobStatus.budgetPaused => 3,
      TranslationJobStatus.running || TranslationJobStatus.queued => 2,
      _ => 1,
    };
    final merged = <String, TranslationJob>{};
    for (final job in <TranslationJob>[...memoryJobs, ...fileJobs]) {
      final previous = merged[job.id];
      final int order = previous == null
          ? 1
          : job.runStartedAt != previous.runStartedAt
          ? job.runStartedAt.compareTo(previous.runStartedAt)
          : priority(job) != priority(previous)
          ? priority(job).compareTo(priority(previous))
          : job.recordRevision.compareTo(previous.recordRevision);
      if (order > 0) {
        merged[job.id] = job;
      }
    }
    final sorted = merged.values.toList()
      ..sort((a, b) {
        // runStartedAt is microseconds; the ID prefix is wall-clock
        // milliseconds — scale it so a fresh inspection record is not
        // sorted below (and truncated in favor of) older translation
        // records by the ~1000x unit gap.
        int latestTaskTime(TranslationJob job) => job.runStartedAt > 0
            ? job.runStartedAt
            : (int.tryParse(job.id.split('-').first) ?? 0) * 1000;
        final byRun = latestTaskTime(b).compareTo(latestTaskTime(a));
        if (byRun != 0) return byRun;
        // Legacy IDs begin with wall-clock milliseconds. Deterministic ID
        // ordering also makes equal timestamps independent of insertion order.
        return b.id.compareTo(a.id);
      });
    return sorted.take(20).toList(growable: false);
  }
}
