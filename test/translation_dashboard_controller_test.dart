import 'dart:async';

import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _BlockingRepository implements TranslationRepository {
  final Completer<InspectionResult> inspectionCompleter =
      Completer<InspectionResult>();

  int startCount = 0;
  int cancelCount = 0;
  String? cancelledJobId;

  @override
  Future<void> cancelJob(String jobId) async {
    cancelCount += 1;
    cancelledJobId = jobId;
  }

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) {
    startCount += 1;
    onProgress?.call(
      TranslationJob(
        id: 'running-job',
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.running,
        progress: 0.2,
        currentChapter: 'Scanning',
      ),
      'Scanning EPUB...',
    );
    return inspectionCompleter.future;
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

class _SuccessfulInspectionRepository implements TranslationRepository {
  int startCount = 0;
  String? lastInputPath;
  String? lastOutputDirectory;

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
    startCount += 1;
    lastInputPath = inputPath;
    lastOutputDirectory = outputDirectory;
    final List<InspectedChapter> chapters = <InspectedChapter>[
      InspectedChapter(
        path: 'chapter.xhtml',
        title: 'Chapter',
        body: '',
        originalHtml: '',
        blocks: <ExtractedBlock>[
          const ExtractedBlock(
            id: 'block-1',
            tagName: 'p',
            sourceHtml: 'short text',
            sourceText: 'short text',
          ),
        ],
        category: ChapterCategory.content,
        recommendedForTranslation: true,
        includeInTranslation: true,
      ),
    ];
    final TranslationJob job = TranslationJob(
      id: 'job-1',
      inputPath: inputPath,
      outputPath: outputDirectory,
      status: TranslationJobStatus.inspected,
      progress: 1,
      completedFiles: 1,
      totalFiles: 1,
      completedBlocks: 1,
      totalBlocks: 1,
    );
    onProgress?.call(job, 'Inspection complete.');
    return InspectionResult(job: job, chapters: chapters);
  }

  @override
  Future<String> testConnection({required TranslationConfig config}) async {
    return 'OK';
  }

  int translateCount = 0;

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    translateCount += 1;
    final String outputPath =
        '$outputDirectory\\${inputPath.split(RegExp(r'[\\/]')).last.replaceAll('.epub', '')}_translated.epub';
    final TranslationJob job = TranslationJob(
      id: 'translated-job',
      inputPath: inputPath,
      outputPath: outputPath,
      status: TranslationJobStatus.completed,
      phase: TranslationJobPhase.translation,
      progress: 1,
      completedFiles: 1,
      totalFiles: 1,
      completedBlocks: 1,
      totalBlocks: 1,
    );
    onProgress?.call(job, 'Translation complete.');
    return TranslationRunResult(job: job, chapters: chapters);
  }
}

class _FailingTranslationRepository extends _SuccessfulInspectionRepository {
  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    translateCount += 1;
    throw StateError(
      'Request failed with Authorization: Bearer sk-live-secret1234567890 api_key=sk-query-secret',
    );
  }
}

class _MemoryJobHistoryStore extends JobHistoryStore {
  _MemoryJobHistoryStore({this.initial = const <TranslationJob>[]});

  final List<TranslationJob> initial;
  List<TranslationJob> saved = const <TranslationJob>[];

  @override
  Future<List<TranslationJob>> load() async => initial;

  @override
  Future<void> save(List<TranslationJob> jobs) async {
    saved = jobs;
  }
}

void main() {
  test('ignores duplicate inspection requests while a run is active', () async {
    final _BlockingRepository repository = _BlockingRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.setInputPath('C:\\Books\\book.epub');

    final Future<void> firstRun = controller.startInspection();
    await Future<void>.delayed(Duration.zero);
    await controller.startInspection();

    expect(repository.startCount, 1);
    expect(controller.state.logs.last, contains('already in progress'));

    repository.inspectionCompleter.complete(
      const InspectionResult(
        job: TranslationJob(
          id: 'running-job',
          inputPath: 'C:\\Books\\book.epub',
          outputPath: 'C:\\Books',
          status: TranslationJobStatus.inspected,
          progress: 1,
        ),
        chapters: <InspectedChapter>[],
      ),
    );
    await firstRun;
  });

  test(
    'requestCancel keeps the run active until the repository stops',
    () async {
      final _BlockingRepository repository = _BlockingRepository();
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: _MemoryJobHistoryStore(),
          );
      controller.setInputPath('C:\\Books\\book.epub');

      final Future<void> run = controller.startInspection();
      await Future<void>.delayed(Duration.zero);

      await controller.requestCancel();

      expect(repository.cancelCount, 1);
      expect(repository.cancelledJobId, 'running-job');
      expect(controller.state.job?.status, TranslationJobStatus.running);
      expect(controller.state.isRunActive, isTrue);
      expect(controller.state.logs.last, contains('Cancellation requested'));

      repository.inspectionCompleter.complete(
        const InspectionResult(
          job: TranslationJob(
            id: 'running-job',
            inputPath: 'C:\\Books\\book.epub',
            outputPath: 'C:\\Books',
            status: TranslationJobStatus.inspected,
            progress: 1,
          ),
          chapters: <InspectedChapter>[],
        ),
      );
      await run;

      expect(controller.state.job?.status, TranslationJobStatus.cancelled);
      expect(controller.state.isRunActive, isFalse);
    },
  );

  test('blocks new inspection while cancellation is still pending', () async {
    final _BlockingRepository repository = _BlockingRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.setInputPath('C:\\Books\\book.epub');

    final Future<void> run = controller.startInspection();
    await Future<void>.delayed(Duration.zero);

    await controller.requestCancel();
    await controller.startInspection();

    expect(repository.startCount, 1);
    expect(controller.state.logs.last, contains('already in progress'));

    repository.inspectionCompleter.complete(
      const InspectionResult(
        job: TranslationJob(
          id: 'running-job',
          inputPath: 'C:\\Books\\book.epub',
          outputPath: 'C:\\Books',
          status: TranslationJobStatus.inspected,
          progress: 1,
        ),
        chapters: <InspectedChapter>[],
      ),
    );
    await run;
  });

  test('creates a run estimate after EPUB inspection', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.setInputPath('C:\\Books\\book.epub');

    await controller.startInspection();

    expect(controller.state.runEstimate?.selectedChapters, 1);
    expect(controller.state.runEstimate?.totalBlocks, 1);
    expect(controller.state.runEstimate?.estimatedApiBatches, 1);
  });

  test('persists completed jobs into history', () async {
    final _MemoryJobHistoryStore historyStore = _MemoryJobHistoryStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: historyStore,
        );
    controller.setInputPath('C:\\Books\\book.epub');

    await controller.startInspection();
    await Future<void>.delayed(Duration.zero);

    expect(historyStore.saved, hasLength(1));
    expect(historyStore.saved.single.id, 'job-1');
  });

  test('loads persisted job history on startup', () async {
    final _MemoryJobHistoryStore historyStore = _MemoryJobHistoryStore(
      initial: const <TranslationJob>[
        TranslationJob(
          id: 'saved-job',
          inputPath: 'C:\\Books\\old.epub',
          outputPath: 'C:\\Books\\old_translated.epub',
          status: TranslationJobStatus.completed,
          progress: 1,
        ),
      ],
    );

    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: historyStore,
        );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.jobHistory, hasLength(1));
    expect(controller.state.jobHistory.single.id, 'saved-job');
  });

  test(
    'retries a failed translation by inspecting then translating again',
    () async {
      final _SuccessfulInspectionRepository repository =
          _SuccessfulInspectionRepository();
      final _MemoryJobHistoryStore historyStore = _MemoryJobHistoryStore(
        initial: const <TranslationJob>[
          TranslationJob(
            id: 'failed-job',
            inputPath: 'C:\\Books\\failed.epub',
            outputPath: 'C:\\Translated',
            status: TranslationJobStatus.failed,
            progress: 0.35,
            currentChapter: 'Translation failed',
            completedBlocks: 2,
            totalBlocks: 10,
          ),
        ],
      );
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: historyStore,
          );
      await Future<void>.delayed(Duration.zero);

      await controller.retryJob('failed-job');

      expect(repository.startCount, 1);
      expect(repository.translateCount, 1);
      expect(repository.lastInputPath, 'C:\\Books\\failed.epub');
      expect(repository.lastOutputDirectory, 'C:\\Translated');
      expect(controller.state.inputPath, 'C:\\Books\\failed.epub');
      expect(controller.state.outputDirectory, 'C:\\Translated');
      expect(controller.state.job?.status, TranslationJobStatus.completed);
      expect(controller.state.job?.hasExportableEpub, isTrue);
      expect(
        controller.state.logs,
        contains('Retrying failed.epub from history.'),
      );
      expect(
        controller.state.logs,
        contains(
          'Inspection ready. Continuing with translation for the retry.',
        ),
      );
    },
  );

  test('inspection alone does not mark exportable output ready', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.setInputPath('C:\\Books\\book.epub');

    await controller.startInspection();

    expect(controller.state.job?.status, TranslationJobStatus.inspected);
    expect(controller.state.job?.hasExportableEpub, isFalse);
  });

  test('does not retry completed history items', () async {
    final _SuccessfulInspectionRepository repository =
        _SuccessfulInspectionRepository();
    final _MemoryJobHistoryStore historyStore = _MemoryJobHistoryStore(
      initial: const <TranslationJob>[
        TranslationJob(
          id: 'completed-job',
          inputPath: 'C:\\Books\\done.epub',
          outputPath: 'C:\\Translated\\done_translated.epub',
          status: TranslationJobStatus.completed,
          progress: 1,
        ),
      ],
    );
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          historyStore: historyStore,
        );
    await Future<void>.delayed(Duration.zero);

    await controller.retryJob('completed-job');

    expect(repository.startCount, 0);
    expect(controller.state.logs.last, contains('Only failed or cancelled'));
  });

  test('redacts API keys from translation failure logs', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _FailingTranslationRepository(),
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(apiKey: 'sk-config-secret'),
    );
    controller.setInputPath('C:\\Books\\book.epub');

    await controller.startInspection();
    await controller.startTranslation();

    final String lastLog = controller.state.logs.last;
    expect(lastLog, contains('[redacted]'));
    expect(lastLog, isNot(contains('sk-live-secret')));
    expect(lastLog, isNot(contains('sk-query-secret')));
    expect(lastLog, isNot(contains('sk-config-secret')));
    expect(controller.state.job?.errorMessage, lastLog.substring(20));
    expect(
      controller.state.jobHistory.single.errorMessage,
      lastLog.substring(20),
    );
  });

  test(
    'sanitizes API keys before recording failure errorMessage and history',
    () async {
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _FailingTranslationRepository(),
            historyStore: _MemoryJobHistoryStore(),
          );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(
          apiKey: 'sk-config-secret-ABCDEFGH',
        ),
      );
      controller.setInputPath('C:\\Books\\book.epub');

      await controller.startInspection();
      await controller.startTranslation();

      final String? errorMessage = controller.state.job?.errorMessage;
      expect(errorMessage, isNotNull);
      expect(errorMessage, contains('[redacted]'));
      expect(errorMessage, isNot(contains('sk-live-secret')));
      expect(errorMessage, isNot(contains('sk-query-secret')));
      expect(errorMessage, isNot(contains('sk-config-secret-ABCDEFGH')));
      expect(errorMessage, isNot(contains('Bearer sk-')));
      expect(controller.state.jobHistory.single.errorMessage, errorMessage);
      // UI logs must also only show the sanitized form.
      expect(
        controller.state.logs.any(
          (String line) =>
              line.contains('sk-live-secret') ||
              line.contains('sk-query-secret') ||
              line.contains('sk-config-secret-ABCDEFGH'),
        ),
        isFalse,
      );
    },
  );

  test('accepts a dropped EPUB path and infers the output directory', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: _MemoryJobHistoryStore(),
        );

    await controller.importDroppedEpubPath('C:\\Books\\dropped.epub');

    expect(controller.state.inputPath, 'C:\\Books\\dropped.epub');
    expect(controller.state.outputDirectory, 'C:\\Books');
    expect(controller.state.inspectedChapters, isEmpty);
    expect(controller.state.job, isNull);
    expect(controller.state.logs.last, contains('Dropped EPUB'));
  });

  test(
    'rejects dropped non-EPUB files without changing the input path',
    () async {
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _SuccessfulInspectionRepository(),
            historyStore: _MemoryJobHistoryStore(),
          );
      controller.setInputPath('C:\\Books\\original.epub');

      await controller.importDroppedEpubPath('C:\\Books\\notes.txt');

      expect(controller.state.inputPath, 'C:\\Books\\original.epub');
      expect(controller.state.logs.last, contains('.epub'));
    },
  );
}
