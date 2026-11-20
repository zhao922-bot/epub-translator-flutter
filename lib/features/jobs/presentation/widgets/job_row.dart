import 'package:flutter/material.dart';
import '../../../translation/presentation/pages/translation_review_page.dart';
import '../../../translation/presentation/widgets/translation_run_details.dart';
import '../../../translation/presentation/workbench_strings.dart';
import '../../../../shared/localization/app_strings.dart';
import '../../domain/models/job_summary.dart';
import '../../../translation/domain/models/translation_job.dart';

/// Responsive row: status and actions never consume the title's entire width.
class JobRow extends StatelessWidget {
  const JobRow({
    super.key,
    required this.job,
    required this.strings,
    required this.onOpen,
    required this.onRetry,
    this.onPreviewWarnings,
  });
  final JobSummary job;
  final AppStrings strings;
  final VoidCallback onOpen;
  final VoidCallback onRetry;
  final VoidCallback? onPreviewWarnings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final String? reportPath = job.qualityReportPath;
    final color = job.hasWarnings
        ? scheme.tertiary
        : job.status == TranslationJobStatus.failed
        ? scheme.error
        : job.status == TranslationJobStatus.completed
        ? scheme.secondary
        : scheme.onSurfaceVariant;
    final label = job.isActive
        ? strings.activeRun
        : job.hasWarnings
        ? strings.jobStatusLabel(job.status)
        : job.canResume
        ? strings.canResumeLabel
        : strings.jobStatusLabel(job.status);
    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          job.hasWarnings
              ? Icons.warning_amber_rounded
              : job.status == TranslationJobStatus.completed
              ? Icons.check_circle_outline
              : job.status == TranslationJobStatus.failed
              ? Icons.error_outline
              : Icons.schedule,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (job.canOpenOutput)
          IconButton(
            tooltip: strings.openOutput,
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new_rounded, size: 19),
          ),
        if (job.canRetry)
          IconButton(
            tooltip: job.retryBlocked
                ? strings.retryBlockedByActiveRun
                : strings.retryJob,
            onPressed: job.retryBlocked
                ? () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(strings.retryBlockedByActiveRun)),
                  )
                : onRetry,
            icon: const Icon(Icons.replay_rounded, size: 19),
          ),
      ],
    );
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: job.title,
          child: Text(
            job.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          [
            job.progressLabel,
            if (job.errorMessage?.isNotEmpty ?? false) job.errorMessage!,
          ].join('\n'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (job.apiUsage.isNotEmpty || (!job.hasWarnings && reportPath != null))
          TranslationRunDetails(
            apiUsage: job.apiUsage,
            outputPath: job.outputPath,
            reportPath: reportPath,
            showReviewLink: !job.hasWarnings,
            elapsedMilliseconds: job.elapsedMilliseconds,
            isChinese: strings.isChinese,
            enabled: !job.isActive && !job.retryBlocked,
          ),
        if (job.hasWarnings) ...[
          const SizedBox(height: 5),
          Text(
            job.degradedBlockCount > 0
                ? strings.degradedBlocksWarning(job.degradedBlockCount)
                : strings.warningReviewSummary,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.tertiary),
          ),
          if (onPreviewWarnings != null || reportPath?.isNotEmpty == true)
            Wrap(
              spacing: 8,
              children: [
                if (onPreviewWarnings != null)
                  TextButton.icon(
                    onPressed: onPreviewWarnings,
                    icon: const Icon(
                      Icons.chrome_reader_mode_outlined,
                      size: 17,
                    ),
                    label: Text(strings.previewTranslationWarnings),
                  ),
                if (reportPath?.isNotEmpty == true)
                  TextButton.icon(
                    onPressed: job.isActive || job.retryBlocked
                        ? null
                        : () => TranslationReviewPage.open(
                            context,
                            reportPath: reportPath!,
                            outputPath: job.outputPath,
                            isChinese: strings.isChinese,
                          ),
                    icon: const Icon(Icons.fact_check_outlined, size: 17),
                    label: Text(strings.reviewTranslationWarnings),
                  ),
              ],
            ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 17),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth <
              680 * MediaQuery.textScalerOf(context).scale(1)) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                title,
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: status),
                    const SizedBox(width: 8),
                    actions,
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              Icon(
                Icons.article_outlined,
                color: scheme.onSurfaceVariant,
                size: 23,
              ),
              const SizedBox(width: 16),
              Expanded(child: title),
              const SizedBox(width: 24),
              SizedBox(width: 210, child: status),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}
