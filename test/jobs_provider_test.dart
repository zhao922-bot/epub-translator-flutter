import 'package:epub_translator_flutter/features/jobs/application/jobs_provider.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CompletedInspectionRepository implements TranslationRepository {
  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    return InspectionResult(
      job: TranslationJob(
        id: 'job-1',
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.inspected,
        progress: 1,
        currentChapter: 'Ready for translation',
        completedFiles: 2,
        totalFiles: 2,
        completedBlocks: 10,
        totalBlocks: 10,
      ),
      chapters: const <InspectedChapter>[],
    );
  }

  @override
  Future<String> testConnection({required TranslationConfig config}) async {
    return 'OK';
  }

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) {
    throw UnimplementedError();
  }
}

class _MemoryJobHistoryStore extends JobHistoryStore {
  _MemoryJobHistoryStore(this.initial);

  final List<TranslationJob> initial;

  @override
  Future<List<TranslationJob>> load() async => initial;

  @override
  Future<void> save(List<TranslationJob> jobs) async {}
}

void main() {
  test('starts empty instead of showing sample jobs', () {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        jobHistoryStoreProvider.overrideWithValue(
          _MemoryJobHistoryStore(const <TranslationJob>[]),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(jobsProvider), isEmpty);
  });

  test('shows the real current translation job', () async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        translationRepositoryProvider.overrideWithValue(
          _CompletedInspectionRepository(),
        ),
        jobHistoryStoreProvider.overrideWithValue(
          _MemoryJobHistoryStore(const <TranslationJob>[]),
        ),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(translationDashboardProvider.notifier);
    controller.setInputPath('C:\\Books\\real-book.epub');
    await controller.startInspection();

    final jobs = container.read(jobsProvider);

    expect(jobs, hasLength(1));
    expect(jobs.single.title, 'real-book.epub');
    expect(jobs.single.status, 'Inspected');
    expect(jobs.single.progressLabel, '10 / 10 blocks');
    expect(jobs.single.canOpenOutput, isFalse);
  });

  test('marks failed and cancelled history items as retryable', () async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        jobHistoryStoreProvider.overrideWithValue(
          _MemoryJobHistoryStore(const <TranslationJob>[
            TranslationJob(
              id: 'failed-job',
              inputPath: 'C:\\Books\\failed.epub',
              outputPath: 'C:\\Translated',
              status: TranslationJobStatus.failed,
              progress: 0.2,
              errorMessage: 'HTTP 429: rate limited',
            ),
            TranslationJob(
              id: 'completed-job',
              inputPath: 'C:\\Books\\done.epub',
              outputPath: 'C:\\Translated\\done_translated.epub',
              status: TranslationJobStatus.completed,
              progress: 1,
            ),
            TranslationJob(
              id: 'cancelled-job',
              inputPath: 'C:\\Books\\cancelled.epub',
              outputPath: 'C:\\Translated',
              status: TranslationJobStatus.cancelled,
              progress: 0.4,
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(translationDashboardProvider);
    await Future<void>.delayed(Duration.zero);
    final jobs = container.read(jobsProvider);

    expect(jobs.firstWhere((job) => job.id == 'failed-job').canRetry, isTrue);
    expect(
      jobs.firstWhere((job) => job.id == 'failed-job').errorMessage,
      'HTTP 429: rate limited',
    );
    expect(
      jobs.firstWhere((job) => job.id == 'cancelled-job').canRetry,
      isTrue,
    );
    expect(
      jobs.firstWhere((job) => job.id == 'completed-job').canRetry,
      isFalse,
    );
  });
}
