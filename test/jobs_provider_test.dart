import 'package:epub_translator_flutter/features/jobs/application/jobs_provider.dart';
import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
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
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async {
    return TranslationStyleProfile.empty;
  }

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
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
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: initial, clearedAt: 0);

  @override
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {}

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    return (written: true, fileClearedAt: 0);
  }
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

  test('shows the real current translation job', testOn: 'windows', () async {
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
    expect(jobs.single.status, TranslationJobStatus.inspected);
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
            TranslationJob(
              id: 'warning-job',
              inputPath: 'C:\\Books\\partial.epub',
              outputPath: 'C:\\Translated\\partial_translated.epub',
              status: TranslationJobStatus.completedWithWarnings,
              phase: TranslationJobPhase.translation,
              progress: 1,
              completedBlocks: 10,
              totalBlocks: 10,
              degradedBlockCount: 2,
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
    final warningJob = jobs.firstWhere((job) => job.id == 'warning-job');
    expect(warningJob.status, TranslationJobStatus.completedWithWarnings);
    expect(warningJob.canOpenOutput, isTrue);
    expect(warningJob.canRetry, isTrue);
    expect(warningJob.canResume, isTrue);
    expect(warningJob.isActive, isFalse);
    expect(warningJob.degradedBlockCount, 2);
  });

  test('retry is reported blocked while another run is active', () async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        jobHistoryStoreProvider.overrideWithValue(
          _MemoryJobHistoryStore(const <TranslationJob>[
            TranslationJob(
              id: 'failed-job',
              inputPath: 'failed.epub',
              outputPath: 'out',
              status: TranslationJobStatus.failed,
              progress: 0.2,
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(translationDashboardProvider.notifier);
    // Simulate an active run: the retry button must stay tappable and
    // explain the situation instead of silently no-op'ing.
    controller.state = controller.state.copyWith(
      job: const TranslationJob(
        id: 'active-job',
        inputPath: 'active.epub',
        outputPath: 'out',
        status: TranslationJobStatus.running,
        progress: 0.1,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final blocked = container
        .read(jobsProvider)
        .firstWhere((job) => job.id == 'failed-job');
    expect(blocked.canRetry, isTrue);
    expect(blocked.retryBlocked, isTrue);

    controller.state = controller.state.copyWith(job: null);
    await Future<void>.delayed(Duration.zero);

    final unblocked = container
        .read(jobsProvider)
        .firstWhere((job) => job.id == 'failed-job');
    expect(unblocked.retryBlocked, isFalse);
  });
}
