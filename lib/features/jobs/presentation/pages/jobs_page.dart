import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../application/jobs_provider.dart';
import '../../domain/models/job_summary.dart';
import '../../../translation/application/translation_dashboard_controller.dart';

class JobsPage extends ConsumerWidget {
  const JobsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    final strings = ref.watch(appStringsProvider);
    final controller = ref.read(translationDashboardProvider.notifier);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return PageScaffold(
      title: strings.jobsTitle,
      subtitle: strings.jobsSubtitle,
      actions: jobs.isEmpty
          ? const <Widget>[]
          : <Widget>[
              TextButton.icon(
                onPressed: controller.clearJobHistory,
                icon: const Icon(Icons.clear_all_rounded, size: 18),
                label: Text(strings.clearHistory),
              ),
            ],
      child: SectionCard(
        variant: SectionCardVariant.standard,
        child: jobs.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text(
                    strings.noRecentJobs,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            : Column(
                children: jobs
                    .map(
                      (job) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: scheme.surfaceContainer.withValues(
                            alpha: 0.65,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: 0.45,
                              ),
                            ),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            leading: Icon(
                              job.isActive
                                  ? Icons.sync_rounded
                                  : Icons.article_outlined,
                              color: scheme.primary,
                            ),
                            title: Text(
                              job.title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            subtitle: Text(
                              _jobSubtitle(job),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  job.isActive
                                      ? strings.activeRun
                                      : job.canResume
                                      ? strings.canResumeLabel
                                      : job.status,
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                                if (job.canOpenOutput)
                                  IconButton(
                                    tooltip: strings.openOutput,
                                    onPressed: () =>
                                        controller.openJobOutput(job.id),
                                    icon: const Icon(Icons.open_in_new_rounded),
                                  ),
                                if (job.canRetry)
                                  IconButton(
                                    tooltip: strings.retryJob,
                                    onPressed: () =>
                                        controller.retryJob(job.id),
                                    icon: const Icon(Icons.replay_rounded),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
      ),
    );
  }

  String _jobSubtitle(JobSummary job) {
    final List<String> lines = <String>[job.progressLabel];
    if (job.errorMessage?.isNotEmpty ?? false) {
      lines.add(job.errorMessage!);
    }
    return lines.join('\n');
  }
}
