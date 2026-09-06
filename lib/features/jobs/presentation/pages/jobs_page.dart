import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../application/jobs_provider.dart';
import '../../../translation/application/translation_dashboard_controller.dart';
import '../widgets/job_row.dart';

class JobsPage extends ConsumerWidget {
  const JobsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    final strings = ref.watch(appStringsProvider);
    final controller = ref.read(translationDashboardProvider.notifier);
    return PageScaffold(
      title: strings.jobsTitle,
      subtitle: strings.jobsSubtitle,
      scrollBody: false,
      actions: [
        if (jobs.isNotEmpty)
          TextButton.icon(
            onPressed: controller.clearJobHistory,
            icon: const Icon(Icons.clear_all_rounded, size: 18),
            label: Text(strings.clearHistory),
          ),
      ],
      child: jobs.isEmpty
          ? Center(
              child: Text(
                strings.noRecentJobs,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 28),
              itemCount: jobs.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (context, index) {
                final job = jobs[index];
                return JobRow(
                  key: ValueKey(job.id),
                  job: job,
                  strings: strings,
                  onOpen: () => controller.openJobOutput(job.id),
                  onRetry: () => controller.retryJob(job.id),
                );
              },
            ),
    );
  }
}
