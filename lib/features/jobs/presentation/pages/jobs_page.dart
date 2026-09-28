import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../application/jobs_provider.dart';
import '../../../translation/application/translation_dashboard_controller.dart';
import '../widgets/job_row.dart';

class JobsPage extends ConsumerWidget {
  const JobsPage({super.key});

  /// Clearing history is destructive and cannot be undone; ask first instead
  /// of wiping on a single tap.
  Future<void> _confirmClearHistory(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
    TranslationDashboardController controller,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(strings.clearHistoryConfirmTitle),
        content: Text(strings.clearHistoryConfirmBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.dialogCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.dialogConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final bool cleared = await controller.clearJobHistory();
      if (!cleared && context.mounted) {
        // The controller logs to the dashboard, which this page never shows:
        // surface the reason here instead of leaving a silent no-op.
        final bool runActive = ref
            .read(translationDashboardProvider)
            .isRunActive;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              runActive
                  ? strings.clearBlockedByActiveRun
                  : strings.logClearHistoryFailed,
            ),
          ),
        );
      }
    }
  }

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
            onPressed: () =>
                _confirmClearHistory(context, ref, strings, controller),
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
