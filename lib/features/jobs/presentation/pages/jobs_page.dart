import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/localization/app_strings.dart';
import '../../../../shared/widgets/page_scaffold.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../application/jobs_provider.dart';

class JobsPage extends ConsumerWidget {
  const JobsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    final strings = ref.watch(appStringsProvider);
    return PageScaffold(
      title: strings.jobsTitle,
      subtitle: strings.jobsSubtitle,
      child: SectionCard(
        title: strings.recentJobs,
        child: Column(
          children: jobs
              .map(
                (job) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.article_outlined),
                  title: Text(job.title),
                  subtitle: Text(job.progressLabel),
                  trailing: Text(job.status),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}
