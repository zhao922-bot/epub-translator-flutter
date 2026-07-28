import 'dart:async';

import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/session_path_store.dart';
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

class _SuccessfulInspectionRepository implements TranslationRepository {
  _SuccessfulInspectionRepository({this.blockCount = 1});

  final int blockCount;
  int startCount = 0;
  String? lastInputPath;
  String? lastOutputDirectory;
  int styleGenerateCount = 0;
  TranslationStyleProfile? lastConfirmedStyleProfile;

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
        blocks: List<ExtractedBlock>.generate(
          blockCount,
          (int index) => ExtractedBlock(
            id: 'block-$index',
            tagName: 'p',
            sourceHtml: 'short text $index',
            sourceText: 'short text $index',
          ),
        ),
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
      completedBlocks: blockCount,
      totalBlocks: blockCount,
    );
    onProgress?.call(job, 'Inspection complete.');
    return InspectionResult(job: job, chapters: chapters);
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
    styleGenerateCount += 1;
    return TranslationStyleProfile.empty;
  }

  int translateCount = 0;

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    translateCount += 1;
    lastConfirmedStyleProfile = confirmedStyleProfile;
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

class _BlockingTranslationRepository extends _SuccessfulInspectionRepository {
  _BlockingTranslationRepository({required super.blockCount});

  final Completer<void> translationStarted = Completer<void>();
  final Completer<void> releaseTranslation = Completer<void>();

  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    translationStarted.complete();
    await releaseTranslation.future;
    return super.translateChapters(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
      config: config,
      chapters: chapters,
      confirmedStyleProfile: confirmedStyleProfile,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }
}

class _CacheProgressRepository extends _SuccessfulInspectionRepository {
  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    onProgress?.call(
      TranslationJob(
        id: 'cache-progress',
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.running,
        phase: TranslationJobPhase.cacheRestoration,
        progress: 1,
        completedBlocks: 1,
        totalBlocks: 1,
        cachedBlocks: 1,
        resumedBlocks: 1,
        resumeCheckpointBlocks: 1,
        cacheScanScannedBlocks: 1,
        cacheScanTotalBlocks: 1,
      ),
      'Cache scan 1/1: verified 1 reusable block.',
    );
    return super.translateChapters(
      inputPath: inputPath,
      outputDirectory: outputDirectory,
      config: config,
      chapters: chapters,
      confirmedStyleProfile: confirmedStyleProfile,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }
}

class _ControlledSessionPathStore extends SessionPathStore {
  final Completer<({String inputPath, String outputDirectory})> loadCompleter =
      Completer<({String inputPath, String outputDirectory})>();

  @override
  Future<({String inputPath, String outputDirectory})> load() =>
      loadCompleter.future;

  @override
  Future<void> save({
    required String inputPath,
    required String outputDirectory,
  }) async {}
}

class _ControlledHistoryStore extends JobHistoryStore {
  final Completer<List<TranslationJob>> loadCompleter =
      Completer<List<TranslationJob>>();
  List<TranslationJob> saved = const <TranslationJob>[];

  @override
  Future<List<TranslationJob>> load() => loadCompleter.future;

  @override
  Future<void> save(List<TranslationJob> jobs) async {
    saved = jobs;
  }
}

class _FailingTranslationRepository extends _SuccessfulInspectionRepository {
  @override
  Future<TranslationRunResult> translateChapters({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationStyleProfile? confirmedStyleProfile,
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
    'restores an unfinished translation as resumable with its style',
    () async {
      const TranslationStyleProfile profile = TranslationStyleProfile(
        primaryGenre: 'history',
        confidence: TranslationStyleConfidence.high,
      );
      final _MemoryJobHistoryStore historyStore = _MemoryJobHistoryStore(
        initial: const <TranslationJob>[
          TranslationJob(
            id: 'interrupted-job',
            inputPath: 'C:\\Books\\old.epub',
            outputPath: 'C:\\Books\\old_translated.epub',
            status: TranslationJobStatus.running,
            phase: TranslationJobPhase.translation,
            progress: 0.4,
            completedBlocks: 4,
            totalBlocks: 10,
            styleProfile: profile,
            styleProfileConfirmed: true,
            styleProfileEnabled: true,
          ),
        ],
      );
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _SuccessfulInspectionRepository(),
            historyStore: historyStore,
          );

      await Future<void>.delayed(Duration.zero);

      final TranslationJob restored = controller.state.jobHistory.single;
      expect(restored.status, TranslationJobStatus.cancelled);
      expect(restored.phase, TranslationJobPhase.translation);
      expect(restored.styleProfileConfirmed, isTrue);
      expect(restored.styleProfile.sameContentAs(profile), isTrue);
    },
  );

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
            styleProfile: TranslationStyleProfile(
              primaryGenre: 'business nonfiction',
              tone: 'concise',
              confidence: TranslationStyleConfidence.high,
            ),
            styleProfileConfirmed: true,
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
      expect(repository.styleGenerateCount, 0);
      expect(
        repository.lastConfirmedStyleProfile?.primaryGenre,
        'business nonfiction',
      );
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

  test(
    'retry immediately exposes checkpoint as cache restoration progress',
    () async {
      final _BlockingTranslationRepository repository =
          _BlockingTranslationRepository(blockCount: 1643);
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: _MemoryJobHistoryStore(
              initial: const <TranslationJob>[
                TranslationJob(
                  id: 'failed-605',
                  inputPath: r'C:\Books\book.epub',
                  outputPath: r'C:\Books',
                  status: TranslationJobStatus.failed,
                  phase: TranslationJobPhase.translation,
                  progress: 605 / 1643,
                  currentChapter: 'Translation failed',
                  completedBlocks: 605,
                  totalBlocks: 1643,
                  styleProfile: TranslationStyleProfile(
                    primaryGenre: 'memoir',
                    confidence: TranslationStyleConfidence.high,
                  ),
                  styleProfileConfirmed: true,
                  styleProfileEnabled: true,
                ),
              ],
            ),
          );
      await Future<void>.delayed(Duration.zero);

      final Future<void> retry = controller.retryJob('failed-605');
      await repository.translationStarted.future;

      expect(controller.state.job?.phase, TranslationJobPhase.cacheRestoration);
      expect(controller.state.job?.completedBlocks, 605);
      expect(controller.state.job?.resumeCheckpointBlocks, 605);
      expect(controller.state.job?.progress, closeTo(605 / 1643, 0.0001));

      repository.releaseTranslation.complete();
      await retry;
    },
  );

  test('logs that completed cache restoration made no API requests', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _CacheProgressRepository(),
          historyStore: _MemoryJobHistoryStore(
            initial: const <TranslationJob>[
              TranslationJob(
                id: 'failed-cache',
                inputPath: r'C:\Books\book.epub',
                outputPath: r'C:\Books',
                status: TranslationJobStatus.failed,
                phase: TranslationJobPhase.translation,
                progress: 1,
                currentChapter: 'Translation failed',
                completedBlocks: 1,
                totalBlocks: 1,
                styleProfile: TranslationStyleProfile(
                  primaryGenre: 'memoir',
                  confidence: TranslationStyleConfidence.high,
                ),
                styleProfileConfirmed: true,
                styleProfileEnabled: true,
              ),
            ],
          ),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(uiLanguage: UiLanguage.chinese),
    );
    await Future<void>.delayed(Duration.zero);

    await controller.retryJob('failed-cache');

    expect(controller.state.logs, contains('已复用全部 1 块，本次未产生 API 请求。'));
  });

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
    controller.confirmStyleProfile();
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
      controller.confirmStyleProfile();
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

  test('active runs reject result-affecting dashboard changes', () async {
    final _BlockingRepository repository = _BlockingRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(repository: repository);
    controller.setInputPath('C:\\Books\\book.epub');

    final Future<void> run = controller.startInspection();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.isRunActive, isTrue);

    controller.setTargetLanguage('Japanese');
    controller.setBilingual(true);

    expect(controller.state.config.targetLanguage, 'Chinese');
    expect(controller.state.config.bilingual, isFalse);

    repository.inspectionCompleter.complete(
      InspectionResult(
        job: const TranslationJob(
          id: 'done',
          inputPath: 'C:\\Books\\book.epub',
          outputPath: 'C:\\Books',
          status: TranslationJobStatus.inspected,
          progress: 1,
        ),
        chapters: const <InspectedChapter>[],
      ),
    );
    await run;
  });

  test('waits for persisted settings before starting inspection', () async {
    final Completer<void> settingsReady = Completer<void>();
    final _SuccessfulInspectionRepository repository =
        _SuccessfulInspectionRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          settingsReady: () => settingsReady.future,
        );
    controller.setInputPath('C:\\Books\\book.epub');

    final Future<void> run = controller.startInspection();
    await Future<void>.delayed(Duration.zero);
    expect(repository.startCount, 0);

    settingsReady.complete();
    await run;

    expect(repository.startCount, 1);
  });

  test(
    'regenerates style when the saved task used a different style mode',
    () async {
      final _SuccessfulInspectionRepository repository =
          _SuccessfulInspectionRepository();
      final _MemoryJobHistoryStore historyStore = _MemoryJobHistoryStore(
        initial: const <TranslationJob>[
          TranslationJob(
            id: 'style-disabled-job',
            inputPath: 'C:\\Books\\book.epub',
            outputPath: 'C:\\Books',
            status: TranslationJobStatus.failed,
            phase: TranslationJobPhase.translation,
            progress: 0.3,
            totalBlocks: 10,
            styleProfile: TranslationStyleProfile.empty,
            styleProfileConfirmed: true,
            styleProfileEnabled: false,
          ),
        ],
      );
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: historyStore,
          );
      await Future<void>.delayed(Duration.zero);

      await controller.retryJob('style-disabled-job');

      expect(repository.styleGenerateCount, 1);
      expect(repository.translateCount, 1);
    },
  );

  test('late session restore cannot overwrite a new user path', () async {
    final _ControlledSessionPathStore pathStore = _ControlledSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );

    controller.setInputPath('C:\\Books\\new.epub');
    pathStore.loadCompleter.complete((
      inputPath: 'C:\\Books\\old.epub',
      outputDirectory: 'C:\\OldOutput',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.inputPath, 'C:\\Books\\new.epub');
    expect(controller.state.outputDirectory, isNot('C:\\OldOutput'));
  });

  test('clearing history wins over a late startup history load', () async {
    final _ControlledHistoryStore historyStore = _ControlledHistoryStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: historyStore,
        );

    controller.clearJobHistory();
    historyStore.loadCompleter.complete(const <TranslationJob>[
      TranslationJob(
        id: 'old-job',
        inputPath: 'old.epub',
        outputPath: '',
        status: TranslationJobStatus.failed,
        progress: 0,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.jobHistory, isEmpty);
    expect(historyStore.saved, isEmpty);
  });
}
