import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/job_summary.dart';

final jobsProvider = Provider<List<JobSummary>>(
  (ref) => const <JobSummary>[
    JobSummary(
      title: 'Sample novel.epub',
      status: 'Queued',
      progressLabel: '0 / 12 chapters',
    ),
    JobSummary(
      title: 'Technical handbook.epub',
      status: 'Needs parser wiring',
      progressLabel: 'Scaffold stage',
    ),
  ],
);
