import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:epub_translator_flutter/shared/localization/app_strings.dart';
import 'package:epub_translator_flutter/shared/platform/native_platform_bridge.dart';
import 'package:flutter/services.dart';
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

/// A repository whose style-profile generation blocks on a completer, so a
/// test can observe the `isGeneratingStyleProfile` window and cancel inside
/// it.
class _BlockingStyleProfileRepository extends _BlockingRepository {
  final Completer<TranslationStyleProfile> profileCompleter =
      Completer<TranslationStyleProfile>();

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) {
    return profileCompleter.future;
  }
}

class _DelayedCancelRepository extends _BlockingRepository {
  final Completer<void> releaseCancellation = Completer<void>();
  final Completer<void> releaseSecondCancellation = Completer<void>();
  final Completer<InspectionResult> secondInspectionCompleter =
      Completer<InspectionResult>();

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) {
    if (startCount == 0) {
      return super.startJob(
        inputPath: inputPath,
        outputDirectory: outputDirectory,
        config: config,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
    startCount += 1;
    onProgress?.call(
      TranslationJob(
        id: 'running-job',
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.running,
        progress: 0.7,
        currentChapter: 'Scanning again',
      ),
      'Scanning EPUB again...',
    );
    return secondInspectionCompleter.future;
  }

  @override
  Future<void> cancelJob(String jobId) async {
    await super.cancelJob(jobId);
    await (cancelCount == 1
        ? releaseCancellation.future
        : releaseSecondCancellation.future);
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
  TranslationStyleProfile generatedStyleProfile = TranslationStyleProfile.empty;

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
    return generatedStyleProfile;
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
      completedBlocks: blockCount,
      totalBlocks: blockCount,
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

/// A repository whose translation run throws a genuine failure (not a
/// cancellation signal) once released, so tests can race it against a
/// concurrent cancel request.
class _ErrorTranslationRepository extends _SuccessfulInspectionRepository {
  _ErrorTranslationRepository({super.blockCount = 1});

  final Completer<void> translationStarted = Completer<void>();
  final Completer<Object> releaseTranslation = Completer<Object>();

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
    throw await releaseTranslation.future;
  }
}

class _WarningTranslationRepository extends _SuccessfulInspectionRepository {
  _WarningTranslationRepository() : super(blockCount: 2);

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
    final TranslationJob job = TranslationJob(
      id: 'warning-result',
      inputPath: inputPath,
      outputPath: '$outputDirectory\\book_translated.epub',
      status: TranslationJobStatus.completedWithWarnings,
      phase: TranslationJobPhase.translation,
      progress: 1,
      completedFiles: 1,
      totalFiles: 1,
      completedBlocks: 2,
      totalBlocks: 2,
      degradedBlockCount: 1,
    );
    onProgress?.call(job, 'Translation completed with warnings.');
    return TranslationRunResult(job: job, chapters: chapters);
  }
}

class _ZeroBlockStyleRepository extends _SuccessfulInspectionRepository {
  _ZeroBlockStyleRepository() : super(blockCount: 0);

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async {
    styleGenerateCount += 1;
    return const TranslationStyleProfile(
      primaryGenre: 'illustrated reference',
      confidence: TranslationStyleConfidence.high,
    );
  }
}

class _AllDegradedTranslationRepository
    extends _SuccessfulInspectionRepository {
  _AllDegradedTranslationRepository() : super(blockCount: 2);

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
    const String error =
        'Every selected text block fell back after translation failures.';
    final TranslationJob job = TranslationJob(
      id: 'all-degraded-result',
      inputPath: inputPath,
      outputPath: '$outputDirectory\\book_translated.epub',
      status: TranslationJobStatus.failed,
      phase: TranslationJobPhase.translation,
      progress: 1,
      currentChapter: 'Translation failed',
      completedFiles: 1,
      totalFiles: 1,
      completedBlocks: 2,
      totalBlocks: 2,
      degradedBlockCount: 2,
      errorMessage: error,
    );
    onProgress?.call(job, error);
    return TranslationRunResult(job: job, chapters: chapters);
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

class _FailThenBlockTranslationRepository
    extends _SuccessfulInspectionRepository {
  _FailThenBlockTranslationRepository() : super(blockCount: 10);

  final Completer<void> secondTranslationStarted = Completer<void>();
  final Completer<void> releaseSecondTranslation = Completer<void>();
  int attempts = 0;

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
    attempts += 1;
    if (attempts == 1) {
      onProgress?.call(
        TranslationJob(
          id: 'failed-progress',
          inputPath: inputPath,
          outputPath: outputDirectory,
          status: TranslationJobStatus.running,
          phase: TranslationJobPhase.translation,
          progress: 0.2,
          completedBlocks: 2,
          totalBlocks: 10,
        ),
        'Translated 2/10 blocks.',
      );
      throw StateError('temporary failure');
    }
    secondTranslationStarted.complete();
    await releaseSecondTranslation.future;
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

class _RestorationCancellationRepository
    extends _SuccessfulInspectionRepository {
  _RestorationCancellationRepository() : super(blockCount: 10);

  final Completer<void> restorationStarted = Completer<void>();
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
    onProgress?.call(
      TranslationJob(
        id: 'restoring-cancel',
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.running,
        phase: TranslationJobPhase.cacheRestoration,
        progress: 0.6,
        completedBlocks: 6,
        totalBlocks: 10,
        cachedBlocks: 2,
        resumedBlocks: 2,
        resumeCheckpointBlocks: 6,
        cacheScanScannedBlocks: 2,
        cacheScanTotalBlocks: 10,
      ),
      'Cache scan 2/10: verified 2 reusable blocks.',
    );
    restorationStarted.complete();
    await releaseTranslation.future;
    throw const TranslationCancelledException();
  }
}

/// Emits one cache-restoration progress report that carries a stale
/// checkpoint (progress 0.9 / 9 blocks) while only 3 blocks are actually
/// verified, then blocks so the test can inspect the controller state.
class _StaleCheckpointProgressRepository
    extends _SuccessfulInspectionRepository {
  final Completer<void> progressEmitted = Completer<void>();
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
    onProgress?.call(
      TranslationJob(
        id: 'stale-checkpoint',
        inputPath: inputPath,
        outputPath: outputDirectory,
        status: TranslationJobStatus.running,
        phase: TranslationJobPhase.cacheRestoration,
        progress: 0.9,
        completedBlocks: 9,
        totalBlocks: 10,
        cachedBlocks: 3,
        resumedBlocks: 3,
        resumeCheckpointBlocks: 9,
        cacheScanScannedBlocks: 4,
        cacheScanTotalBlocks: 10,
      ),
      'Cache scan 4/10: verified 3 reusable blocks.',
    );
    progressEmitted.complete();
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

class _RecordingSessionPathStore extends SessionPathStore {
  final List<({String inputPath, String outputDirectory})> saves = [];

  @override
  Future<({String inputPath, String outputDirectory})> load() async =>
      (inputPath: '', outputDirectory: '');

  @override
  Future<void> save({
    required String inputPath,
    required String outputDirectory,
  }) async {
    saves.add((inputPath: inputPath, outputDirectory: outputDirectory));
  }
}

class _DelayedSessionPathStore extends SessionPathStore {
  _DelayedSessionPathStore({this.failFirstWrite = false});

  final bool failFirstWrite;
  final Completer<void> releaseFirstWrite = Completer<void>();
  final Completer<void> firstWriteFinished = Completer<void>();
  final Completer<void> secondWriteFinished = Completer<void>();
  int writeCount = 0;
  String savedInputPath = '';

  @override
  Future<({String inputPath, String outputDirectory})> load() async =>
      (inputPath: '', outputDirectory: '');

  @override
  Future<void> save({
    required String inputPath,
    required String outputDirectory,
  }) async {
    final int writeNumber = ++writeCount;
    if (writeNumber == 1) {
      await releaseFirstWrite.future;
      if (failFirstWrite) {
        firstWriteFinished.complete();
        throw StateError('First write failed');
      }
    }
    savedInputPath = inputPath;
    if (writeNumber == 1) {
      firstWriteFinished.complete();
    } else if (writeNumber == 2) {
      secondWriteFinished.complete();
    }
  }
}

class _ControlledHistoryStore extends JobHistoryStore {
  final Completer<List<TranslationJob>> loadCompleter =
      Completer<List<TranslationJob>>();
  List<TranslationJob> saved = const <TranslationJob>[];

  @override
  Future<({List<TranslationJob> jobs, int clearedAt})> loadWithTombstone() =>
      loadCompleter.future.then(
        (List<TranslationJob> jobs) => (jobs: jobs, clearedAt: 0),
      );

  @override
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {
    saved = jobs;
  }

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    saved = merge(const <TranslationJob>[], 0);
    return (written: true, fileClearedAt: 0);
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

class _ProgressThenErrorRepository extends _SuccessfulInspectionRepository {
  _ProgressThenErrorRepository() : super(blockCount: 10);
  final started = Completer<void>();
  final release = Completer<Object>();
  late void Function(int) progress;

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
    progress = (completed) => onProgress?.call(
      TranslationJob(
        id: 'repository-run',
        inputPath: inputPath,
        outputPath: '$outputDirectory/not-created.epub',
        status: TranslationJobStatus.running,
        phase: TranslationJobPhase.translation,
        progress: completed / 10,
        completedBlocks: completed,
        totalBlocks: 10,
      ),
      'Progress',
    );
    progress(2);
    started.complete();
    throw await release.future;
  }
}

class _FailingHistoryStore extends JobHistoryStore {
  _FailingHistoryStore({this.initial = const <TranslationJob>[]});

  final List<TranslationJob> initial;

  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: initial, clearedAt: 0);

  @override
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {
    throw const FileSystemException('disk full');
  }

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    throw const FileSystemException('disk full');
  }
}

class _FailingInspectionRepository extends _SuccessfulInspectionRepository {
  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    throw const FormatException('cannot decode chapter');
  }
}

class _MemoryJobHistoryStore extends JobHistoryStore {
  _MemoryJobHistoryStore({this.initial = const <TranslationJob>[]});

  final List<TranslationJob> initial;
  List<TranslationJob> saved = const <TranslationJob>[];

  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: initial, clearedAt: 0);

  @override
  Future<void> save(
    List<TranslationJob> jobs, {
    int clearedAtEpochMs = 0,
  }) async {
    saved = jobs;
  }

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    saved = merge(initial, 0);
    return (written: true, fileClearedAt: 0);
  }
}

void main() {
  for (final cancelled in [false, true]) {
    test(
      'persisted progress cannot overwrite ${cancelled ? 'cancellation' : 'failure'} on restart',
      () async {
        final temp = await Directory.systemTemp.createTemp('history_terminal_');
        addTearDown(() => temp.delete(recursive: true));
        final store = JobHistoryStore(
          historyFileProvider: () async => File('${temp.path}/history.json'),
        );
        final repository = _ProgressThenErrorRepository();
        final controller = TranslationDashboardController(
          repository: repository,
          historyStore: store,
        );
        addTearDown(controller.dispose);
        controller.syncSettings(
          TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
        );
        controller.setInputPath('${temp.path}/book.epub');
        controller.setOutputDirectory(temp.path);
        await controller.startInspection();
        final run = controller.startTranslation();
        await repository.started.future;
        await controller.debugPersistJobHistoryNow();
        final running = (await store.load()).first;
        expect(running.status, TranslationJobStatus.running);
        expect(running.runStartedAt, greaterThan(0));
        repository.progress(4);
        repository.release.complete(
          cancelled
              ? const TranslationCancelledException()
              : StateError('original failure'),
        );
        await run;
        await controller.debugPersistJobHistoryNow();
        final terminal = (await store.load()).first;
        expect(
          terminal.status,
          cancelled
              ? TranslationJobStatus.cancelled
              : TranslationJobStatus.failed,
        );
        expect(terminal.completedBlocks, 4);
        expect(terminal.progress, 0.4);
        expect(terminal.recordRevision, greaterThan(running.recordRevision));
        if (!cancelled) {
          expect(terminal.errorMessage, contains('original failure'));
        }
        expect(terminal.outputDirectory, temp.path);
        expect(await File(terminal.outputPath).exists(), isFalse);
        final retryRepository = _SuccessfulInspectionRepository();
        final restored = TranslationDashboardController(
          repository: retryRepository,
          historyStore: store,
        );
        addTearDown(restored.dispose);
        restored.syncSettings(
          TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
        );
        await restored.debugPersistJobHistoryNow();
        expect(
          restored.state.jobHistory.first.errorMessage,
          terminal.errorMessage,
        );
        expect(restored.state.jobHistory.first.completedBlocks, 4);
        await restored.retryJob(terminal.id);
        expect(retryRepository.lastOutputDirectory, temp.path);
        await restored.debugPersistJobHistoryNow();
        final retried = (await store.load()).first;
        expect(retried.runStartedAt, greaterThan(terminal.runStartedAt));
        // A stale instance saving the older failure must retain the newer run.
        await controller.debugPersistJobHistoryNow();
        expect((await store.load()).first.runStartedAt, retried.runStartedAt);
      },
    );
  }

  test(
    'a new queued round supersedes an old completed disk snapshot',
    () async {
      final temp = await Directory.systemTemp.createTemp('history_round_');
      addTearDown(() => temp.delete(recursive: true));
      final store = JobHistoryStore(
        historyFileProvider: () async => File('${temp.path}/history.json'),
      );
      final repository = _FailThenBlockTranslationRepository();
      final controller = TranslationDashboardController(
        repository: repository,
        historyStore: store,
      );
      addTearDown(controller.dispose);
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
      );
      controller.setInputPath('${temp.path}/book.epub');
      await controller.startInspection();
      await controller.startTranslation();
      await controller.debugPersistJobHistoryNow();
      final old = (await store.load()).first;
      await store.save([
        old.copyWith(
          status: TranslationJobStatus.completed,
          recordRevision: 999,
        ),
      ]);
      final retry = controller.startTranslation();
      await repository.secondTranslationStarted.future;
      await controller.debugPersistJobHistoryNow();
      final queued = (await store.load()).first;
      expect(queued.status, TranslationJobStatus.queued);
      expect(queued.runStartedAt, greaterThan(old.runStartedAt));
      repository.releaseSecondTranslation.complete();
      await retry;
      await controller.debugPersistJobHistoryNow();
    },
  );

  test(
    'stale interrupted history cannot overwrite a completed disk job',
    () async {
      final temp = await Directory.systemTemp.createTemp('history_conflict_');
      addTearDown(() => temp.delete(recursive: true));
      final store = JobHistoryStore(
        historyFileProvider: () async => File('${temp.path}/history.json'),
      );
      const running = TranslationJob(
        id: 'shared',
        inputPath: 'book.epub',
        outputPath: 'out',
        status: TranslationJobStatus.running,
        phase: TranslationJobPhase.translation,
        progress: 0.3,
      );
      await store.save([running]);
      final controller = TranslationDashboardController(
        repository: _SuccessfulInspectionRepository(),
        historyStore: store,
      );
      addTearDown(controller.dispose);
      await controller.debugPersistJobHistoryNow();
      expect(
        controller.state.jobHistory.single.status,
        TranslationJobStatus.cancelled,
      );
      final completed = running.copyWith(
        status: TranslationJobStatus.completed,
        outputPath: 'out/book.epub',
        progress: 1,
        completedBlocks: 10,
      );
      await store.save([completed]);
      await controller.debugPersistJobHistoryNow();
      final saved = (await store.load()).single;
      expect(saved.status, TranslationJobStatus.completed);
      expect(saved.outputPath, 'out/book.epub');
      expect(saved.completedBlocks, 10);
    },
  );

  test(
    'retry resolves actual files and preserves .epub directories and unknown paths',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'retry_epub_directory_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final directory = await Directory(
        '${temp.path}/collection.epub',
      ).create();
      final file = await File(
        '${temp.path}/actual.epub',
      ).writeAsString('output');
      for (final phase in [
        TranslationJobPhase.inspection,
        TranslationJobPhase.translation,
      ]) {
        for (final entry in [
          (output: directory.path, expected: directory.path),
          (
            output: '${temp.path}/missing.epub',
            expected: '${temp.path}/missing.epub',
          ),
          (output: file.path, expected: temp.path),
        ]) {
          final repository = _SuccessfulInspectionRepository();
          final controller = TranslationDashboardController(
            repository: repository,
            historyStore: _MemoryJobHistoryStore(
              initial: [
                TranslationJob(
                  id: 'directory-job',
                  inputPath: '${temp.path}/book.epub',
                  outputPath: entry.output,
                  status: TranslationJobStatus.cancelled,
                  phase: phase,
                  progress: 0,
                ),
              ],
            ),
          );
          addTearDown(controller.dispose);
          await controller.debugPersistJobHistoryNow();
          await controller.retryJob('directory-job');
          expect(repository.lastOutputDirectory, entry.expected);
        }
      }
    },
  );
  test(
    'clearJobHistory reports failure when the tombstone cannot persist',
    () async {
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _SuccessfulInspectionRepository(),
            historyStore: _FailingHistoryStore(
              initial: const <TranslationJob>[
                TranslationJob(
                  id: 'old-job',
                  inputPath: 'old.epub',
                  outputPath: 'out',
                  status: TranslationJobStatus.completed,
                  progress: 1,
                ),
              ],
            ),
          );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.jobHistory, hasLength(1));

      final bool cleared = await controller.clearJobHistory();

      expect(cleared, isFalse);
      expect(
        controller.state.logs.last,
        const AppStrings(UiLanguage.english).logClearHistoryFailed,
      );
      // The failed write must not poison the persist chain: a later save
      // still goes through.
      expect(controller.state.jobHistory, isEmpty);
    },
  );

  test('inspection failure shows a localized progress title', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _FailingInspectionRepository(),
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(
        uiLanguage: UiLanguage.chinese,
        styleProfileEnabled: false,
      ),
    );
    controller.setInputPath('book.epub');

    await controller.startInspection();

    expect(controller.state.job?.status, TranslationJobStatus.failed);
    expect(
      controller.state.job?.currentChapter,
      const AppStrings(UiLanguage.chinese).jobStatusInspectionFailed,
    );
  });

  test(
    'retrying a failed translation-phase job does not depend on the English title',
    () async {
      final _SuccessfulInspectionRepository repository =
          _SuccessfulInspectionRepository(blockCount: 2);
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: _MemoryJobHistoryStore(
              initial: const <TranslationJob>[
                TranslationJob(
                  id: 'failed-cn',
                  selectedChapterPaths: ['chapter.xhtml'],
                  inputPath: 'book.epub',
                  outputPath: 'out',
                  status: TranslationJobStatus.failed,
                  phase: TranslationJobPhase.translation,
                  progress: 0,
                  // Localized title: the old heuristic matched
                  // currentChapter.contains('translation').
                  currentChapter: '翻译失败',
                  completedBlocks: 0,
                  totalBlocks: 0,
                  styleProfile: TranslationStyleProfile(
                    primaryGenre: 'business nonfiction',
                    tone: 'concise',
                    confidence: TranslationStyleConfidence.high,
                  ),
                  styleProfileConfirmed: true,
                ),
              ],
            ),
          );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(
          uiLanguage: UiLanguage.chinese,
          styleProfileEnabled: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      await controller.retryJob('failed-cn');

      // The phase (not the display string) identifies the translation run,
      // so retry continues into translation after re-inspection.
      expect(repository.translateCount, 1);
    },
  );

  test('save to downloads does not throw when disposed mid-flight', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'save-downloads',
    );
    final File epub = File('${temp.path}${Platform.pathSeparator}book.epub');
    await epub.writeAsBytes(const <int>[0x50, 0x4B, 0x03, 0x04]);
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.syncSettings(TranslationConfig.defaults());
    controller.state = controller.state.copyWith(
      job: TranslationJob(
        id: 'done-job',
        inputPath: 'book.epub',
        outputPath: epub.path,
        status: TranslationJobStatus.completed,
        phase: TranslationJobPhase.translation,
        progress: 1,
      ),
    );

    // The native bridge has no handler in unit tests, so the awaited save
    // fails; disposing mid-flight must not turn that into an unhandled
    // StateError from the post-await state writes.
    final Future<void> save = controller.saveTranslatedEpubToDownloads();
    controller.dispose();
    await save;

    await temp.delete(recursive: true);
  });

  test('committed translation result wins over a late cancellation', () async {
    final _BlockingTranslationRepository repository =
        _BlockingTranslationRepository(blockCount: 1);
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    controller.setInputPath('C:\\Books\\book.epub');
    await controller.startInspection();

    final Future<void> translation = controller.startTranslation();
    await repository.translationStarted.future;
    await controller.requestCancel();
    repository.releaseTranslation.complete();
    await translation;

    expect(controller.state.job?.status, TranslationJobStatus.completed);
    expect(
      controller.state.jobHistory.first.status,
      TranslationJobStatus.completed,
    );
  });

  test('genuine failure during cancellation is reported as failed', () async {
    // Regression: when the user hit cancel at the same moment a real error
    // surfaced, the error was downgraded to "cancelled" and the diagnosis
    // (bad key, timeout, …) was lost.
    final _ErrorTranslationRepository repository = _ErrorTranslationRepository(
      blockCount: 1,
    );
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    controller.setInputPath('C:\\Books\\book.epub');
    await controller.startInspection();

    final Future<void> translation = controller.startTranslation();
    await repository.translationStarted.future;
    await controller.requestCancel();
    repository.releaseTranslation.complete(Exception('401 Unauthorized'));
    await translation;

    expect(controller.state.job?.status, TranslationJobStatus.failed);
    expect(controller.state.job?.errorMessage, contains('401'));
  });

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

  test('late cancellation response cannot revive a finished run', () async {
    final _DelayedCancelRepository repository = _DelayedCancelRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.setInputPath('C:\\Books\\book.epub');

    final Future<void> run = controller.startInspection();
    await Future<void>.delayed(Duration.zero);
    final Future<void> cancellation = controller.requestCancel();

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

    repository.releaseCancellation.complete();
    await cancellation;
    expect(controller.state.job?.status, TranslationJobStatus.cancelled);
    expect(controller.state.isRunActive, isFalse);
  });

  test('cancellation shows a localized progress title', () async {
    final _BlockingRepository repository = _BlockingRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(
        uiLanguage: UiLanguage.chinese,
        styleProfileEnabled: false,
      ),
    );
    controller.setInputPath('C:\\\\Books\\\\book.epub');

    final Future<void> run = controller.startInspection();
    await Future<void>.delayed(Duration.zero);
    final Future<void> cancellation = controller.requestCancel();
    repository.inspectionCompleter.complete(
      const InspectionResult(
        job: TranslationJob(
          id: 'running-job',
          inputPath: 'C:\\\\Books\\\\book.epub',
          outputPath: 'C:\\\\Books',
          status: TranslationJobStatus.inspected,
          progress: 1,
        ),
        chapters: <InspectedChapter>[],
      ),
    );
    await run;
    await cancellation;

    expect(controller.state.job?.status, TranslationJobStatus.cancelled);
    expect(controller.state.job?.currentChapter, '已取消');
    expect(controller.state.logs.last, '任务已取消。');
  });

  test('old cancellation response cannot overwrite a retried run', () async {
    final _DelayedCancelRepository repository = _DelayedCancelRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.setInputPath('C:\\Books\\book.epub');

    final Future<void> firstRun = controller.startInspection();
    await Future<void>.delayed(Duration.zero);
    final Future<void> firstCancellation = controller.requestCancel();
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

    final Future<void> secondRun = controller.startInspection();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.job?.progress, 0.7);
    final Future<void> secondCancellation = controller.requestCancel();

    repository.releaseCancellation.complete();
    await firstCancellation;
    expect(controller.state.job?.progress, 0.7);
    expect(controller.state.job?.currentChapter, 'Scanning again');

    repository.releaseSecondCancellation.complete();
    await secondCancellation;
    repository.secondInspectionCompleter.complete(
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
    await secondRun;
  });

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
    testOn: 'windows',
    () async {
      final _SuccessfulInspectionRepository repository =
          _SuccessfulInspectionRepository();
      final _MemoryJobHistoryStore historyStore = _MemoryJobHistoryStore(
        initial: const <TranslationJob>[
          TranslationJob(
            id: 'failed-job',
            phase: TranslationJobPhase.translation,
            selectedChapterPaths: ['chapter.xhtml'],
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
    'retry starts cache restoration at zero until the scan verifies the checkpoint',
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
                  selectedChapterPaths: ['chapter.xhtml'],
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
      // The checkpoint is unverified until the cache scan runs: progress and
      // counters start at zero while resumeCheckpointBlocks keeps the
      // pending figure for the "to verify" UI line.
      expect(controller.state.job?.completedBlocks, 0);
      expect(controller.state.job?.resumeCheckpointBlocks, 605);
      expect(controller.state.job?.progress, 0);

      repository.releaseTranslation.complete();
      await retry;
    },
  );

  test(
    'cache restoration progress bar follows verified blocks, not the stale checkpoint',
    () async {
      final _StaleCheckpointProgressRepository repository =
          _StaleCheckpointProgressRepository();
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: _MemoryJobHistoryStore(),
          );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
      );
      controller.setInputPath(r'C:\\Books\\book.epub');
      await controller.startInspection();

      final Future<void> run = controller.startTranslation();
      await repository.progressEmitted.future;

      expect(controller.state.job?.phase, TranslationJobPhase.cacheRestoration);
      // The repository reported the old checkpoint (0.9 / 9 blocks); the bar
      // must show the verified fraction (3/10) instead.
      expect(controller.state.job?.progress, closeTo(0.3, 0.0001));
      expect(controller.state.job?.cachedBlocks, 3);
      // completedBlocks intentionally keeps the checkpoint during restoration
      // (resume semantics); only the bar is re-based.
      expect(controller.state.job?.completedBlocks, 9);
      expect(controller.state.job?.resumeCheckpointBlocks, 9);

      repository.releaseTranslation.complete();
      await run;
      expect(controller.state.job?.status, TranslationJobStatus.completed);
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
                selectedChapterPaths: ['chapter.xhtml'],
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

  test(
    'direct translation retry preserves the failed job checkpoint',
    () async {
      final _FailThenBlockTranslationRepository repository =
          _FailThenBlockTranslationRepository();
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: _MemoryJobHistoryStore(),
          );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
      );
      controller.setInputPath(r'C:\Books\book.epub');
      await controller.startInspection();
      await controller.startTranslation();
      expect(controller.state.job?.status, TranslationJobStatus.failed);
      expect(controller.state.job?.completedBlocks, 2);
      expect(controller.state.job?.errorMessage, contains('temporary failure'));

      final Future<void> retry = controller.startTranslation();
      await repository.secondTranslationStarted.future;

      expect(controller.state.job?.phase, TranslationJobPhase.cacheRestoration);
      // Counters start at zero while the scan verifies the checkpoint; only
      // resumeCheckpointBlocks keeps the pending figure.
      expect(controller.state.job?.completedBlocks, 0);
      expect(controller.state.job?.resumeCheckpointBlocks, 2);
      expect(controller.state.job?.errorMessage, isNull);
      expect(controller.state.jobHistory.first.errorMessage, isNull);
      expect(controller.state.jobHistory.first.completedBlocks, 0);

      repository.releaseSecondTranslation.complete();
      await retry;
    },
  );

  test(
    'cache restoration cancellation keeps translation resume semantics',
    () async {
      final _RestorationCancellationRepository repository =
          _RestorationCancellationRepository();
      final _MemoryJobHistoryStore historyStore = _MemoryJobHistoryStore();
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: historyStore,
          );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
      );
      controller.setInputPath(r'C:\Books\book.epub');
      await controller.startInspection();

      final Future<void> run = controller.startTranslation();
      await repository.restorationStarted.future;

      expect(controller.state.job?.completedBlocks, 6);
      expect(controller.state.job?.id, controller.state.jobHistory.first.id);
      expect(
        controller.state.jobHistory.first.phase,
        TranslationJobPhase.cacheRestoration,
      );
      expect(controller.state.jobHistory.first.completedBlocks, 6);
      expect(controller.state.jobHistory.first.cachedBlocks, 2);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(historyStore.saved.first.completedBlocks, 6);

      await controller.requestCancel();

      expect(
        controller.state.logs,
        contains(
          'Cached progress so far: ~2 blocks. After cancel, press Translate selected to resume.',
        ),
      );
      expect(
        controller.state.logs,
        isNot(
          contains(
            'Cached progress so far: ~6 blocks. After cancel, press Translate selected to resume.',
          ),
        ),
      );

      repository.releaseTranslation.complete();
      await run;

      expect(
        controller.state.actionableError?.actionKind.name,
        'retryTranslation',
      );
      expect(controller.state.job?.canResumeTranslation, isTrue);
    },
  );

  test('startup restores cache scanning as interrupted translation', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: _MemoryJobHistoryStore(
            initial: const <TranslationJob>[
              TranslationJob(
                id: 'interrupted-cache',
                inputPath: r'C:\Books\book.epub',
                outputPath: r'C:\Books',
                status: TranslationJobStatus.running,
                phase: TranslationJobPhase.cacheRestoration,
                progress: 0.6,
                completedBlocks: 6,
                totalBlocks: 10,
                cachedBlocks: 2,
              ),
            ],
          ),
        );
    await Future<void>.delayed(Duration.zero);

    final TranslationJob restored = controller.state.jobHistory.single;
    expect(restored.status, TranslationJobStatus.cancelled);
    expect(
      restored.currentChapter,
      const AppStrings(UiLanguage.english).jobStatusTranslationInterrupted,
    );
    expect(restored.canResumeTranslation, isTrue);
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

  test('preserves a warning result and records its warning log', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _WarningTranslationRepository(),
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    controller.setInputPath('C:\\Books\\book.epub');

    await controller.startInspection();
    await controller.startTranslation();

    expect(
      controller.state.job?.status,
      TranslationJobStatus.completedWithWarnings,
    );
    expect(controller.state.job?.degradedBlockCount, 1);
    expect(controller.state.jobHistory.first.degradedBlockCount, 1);
    expect(
      controller.state.logs,
      contains(
        'Translation completed with 1 blocks retaining fallback content.',
      ),
    );
  });

  test(
    'translates a selected zero-block run without style confirmation',
    () async {
      final _ZeroBlockStyleRepository repository = _ZeroBlockStyleRepository();
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: _MemoryJobHistoryStore(),
          );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: true),
      );
      controller.setInputPath('C:\\Books\\image-only.epub');

      await controller.startInspection();
      expect(controller.state.requiresStyleProfileConfirmation, isTrue);
      await controller.startTranslation();

      expect(repository.translateCount, 1);
      expect(controller.state.job?.status, TranslationJobStatus.completed);
      expect(controller.state.job?.totalBlocks, 0);
    },
  );

  test('retries completed-with-warnings history items', () async {
    final _SuccessfulInspectionRepository repository =
        _SuccessfulInspectionRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          historyStore: _MemoryJobHistoryStore(
            initial: const <TranslationJob>[
              TranslationJob(
                id: 'warning-job',
                selectedChapterPaths: ['chapter.xhtml'],
                inputPath: 'C:\\Books\\partial.epub',
                outputPath: 'C:\\Translated\\partial_translated.epub',
                status: TranslationJobStatus.completedWithWarnings,
                phase: TranslationJobPhase.translation,
                progress: 1,
                completedBlocks: 10,
                totalBlocks: 10,
                degradedBlockCount: 2,
                styleProfileEnabled: false,
              ),
            ],
          ),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    await Future<void>.delayed(Duration.zero);

    await controller.retryJob('warning-job');

    expect(repository.startCount, 1);
    expect(repository.translateCount, 1);
    expect(controller.state.logs, isNot(contains('Only failed or cancelled')));
    // The run really started, so the "continuing" log is accurate here.
    expect(
      controller.state.logs,
      contains('Inspection ready. Continuing with translation for the retry.'),
    );
  });

  test(
    'retry does not claim to continue translation when style confirmation blocks it',
    () async {
      final _SuccessfulInspectionRepository repository =
          _SuccessfulInspectionRepository();
      // A non-empty generated profile stays unconfirmed, so the style gate
      // really blocks translation (an empty profile would auto-confirm).
      repository.generatedStyleProfile = const TranslationStyleProfile(
        primaryGenre: 'Literary fiction',
      );
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: _MemoryJobHistoryStore(
              initial: const <TranslationJob>[
                TranslationJob(
                  id: 'failed-unconfirmed-style',
                  selectedChapterPaths: ['chapter.xhtml'],
                  inputPath: 'unconfirmed.epub',
                  outputPath: 'unconfirmed-out',
                  status: TranslationJobStatus.failed,
                  phase: TranslationJobPhase.translation,
                  progress: 0.2,
                  currentChapter: 'Translation failed',
                  completedBlocks: 2,
                  totalBlocks: 10,
                  styleProfileEnabled: true,
                  styleProfileConfirmed: false,
                ),
              ],
            ),
          );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(styleProfileEnabled: true),
      );
      await Future<void>.delayed(Duration.zero);

      await controller.retryJob('failed-unconfirmed-style');

      // Inspection ran, but translation never started: the style gate stopped
      // it, so the "continuing" log must not appear. The gate's own
      // "confirm style profile" log covers the situation instead.
      expect(repository.startCount, 1);
      expect(repository.translateCount, 0);
      expect(
        controller.state.logs,
        isNot(
          contains(
            'Inspection ready. Continuing with translation for the retry.',
          ),
        ),
      );
      expect(
        controller.state.logs,
        contains(
          'Confirm the book style profile before starting full-book translation.',
        ),
      );
    },
  );

  test('handles an all-degraded result as a retryable failure', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _AllDegradedTranslationRepository(),
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    controller.setInputPath('C:\\Books\\book.epub');

    await controller.startInspection();
    await controller.startTranslation();

    expect(controller.state.job?.status, TranslationJobStatus.failed);
    expect(controller.state.job?.hasExportableEpub, isFalse);
    expect(controller.state.job?.degradedBlockCount, 2);
    expect(controller.state.actionableError, isNotNull);
    expect(
      controller.state.logs.last,
      contains('Every selected text block fell back'),
    );
    expect(
      controller.state.logs,
      isNot(
        contains(
          'Translation complete. Use Open EPUB to view the output file.',
        ),
      ),
    );
  });

  test('manual EPUB change clears recovery action from the old run', () async {
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _FailingTranslationRepository(),
          historyStore: _MemoryJobHistoryStore(),
        );
    controller.syncSettings(
      TranslationConfig.defaults().copyWith(styleProfileEnabled: false),
    );
    controller.setInputPath('C:\\Books\\old.epub');
    await controller.startInspection();
    await controller.startTranslation();
    expect(controller.state.actionableError, isNotNull);

    controller.setInputPath('C:\\Books\\new.epub');

    expect(controller.state.job, isNull);
    expect(controller.state.actionableError, isNull);
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

  test(
    'accepts a dropped EPUB path and infers the output directory',
    testOn: 'windows',
    () async {
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
    },
  );

  test('EPUB import does not override a newer output directory edit', () async {
    final _RecordingSessionPathStore pathStore = _RecordingSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );

    final Future<bool> importing = controller.importDroppedEpubPath(
      'C:\\Books\\new.epub',
    );
    controller.setOutputDirectory('C:\\ChosenOutput');
    expect(await importing, isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.inputPath, 'C:\\Books\\new.epub');
    expect(controller.state.outputDirectory, 'C:\\ChosenOutput');
    expect(pathStore.saves.last.outputDirectory, 'C:\\ChosenOutput');
  });

  test('pending EPUB import cannot replace a newer manual EPUB edit', () async {
    final _RecordingSessionPathStore pathStore = _RecordingSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );

    final Future<bool> importing = controller.importDroppedEpubPath(
      'C:\\Books\\dropped.epub',
    );
    controller.setInputPath('C:\\Books\\manual.epub');
    expect(await importing, isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.inputPath, 'C:\\Books\\manual.epub');
    expect(pathStore.saves.last.inputPath, 'C:\\Books\\manual.epub');
  });

  test('pending EPUB import cannot clear an inspection that started', () async {
    final Completer<String> delayedOutputDirectory = Completer<String>();
    final _BlockingRepository repository = _BlockingRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          defaultOutputDirectoryResolver: (String? inputPath) =>
              inputPath == 'C:\\Books\\new.epub'
              ? delayedOutputDirectory.future
              : Future<String>.value('C:\\Books'),
        );
    controller.setInputPath('C:\\Books\\old.epub');

    final Future<bool> importing = controller.importDroppedEpubPath(
      'C:\\Books\\new.epub',
    );
    final Future<void> inspection = controller.startInspection();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.isRunActive, isTrue);

    delayedOutputDirectory.complete('C:\\Books');
    expect(await importing, isFalse);
    expect(controller.state.inputPath, 'C:\\Books\\old.epub');
    expect(controller.state.job?.status, TranslationJobStatus.running);

    repository.inspectionCompleter.complete(
      const InspectionResult(
        job: TranslationJob(
          id: 'running-job',
          inputPath: 'C:\\Books\\old.epub',
          outputPath: 'C:\\Books',
          status: TranslationJobStatus.inspected,
          progress: 1,
        ),
        chapters: <InspectedChapter>[],
      ),
    );
    await inspection;
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

  test('inspection does not mix an old output with a new EPUB path', () async {
    final Completer<void> lookupStarted = Completer<void>();
    final Completer<String> oldOutputDirectory = Completer<String>();
    final _SuccessfulInspectionRepository repository =
        _SuccessfulInspectionRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          defaultOutputDirectoryResolver: (String? inputPath) {
            lookupStarted.complete();
            return oldOutputDirectory.future;
          },
        );
    controller.setInputPath('C:\\OldBook\\old.epub');

    final Future<void> inspection = controller.startInspection();
    await lookupStarted.future;
    controller.setInputPath('C:\\NewBook\\new.epub');
    oldOutputDirectory.complete('C:\\OldBook');
    await inspection;

    expect(repository.startCount, 0);
    expect(controller.state.inputPath, 'C:\\NewBook\\new.epub');
    expect(controller.state.job, isNull);
  });

  test('inspection keeps a newer output directory edit', () async {
    final Completer<void> lookupStarted = Completer<void>();
    final Completer<String> inferredOutputDirectory = Completer<String>();
    final _SuccessfulInspectionRepository repository =
        _SuccessfulInspectionRepository();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: repository,
          defaultOutputDirectoryResolver: (String? inputPath) {
            lookupStarted.complete();
            return inferredOutputDirectory.future;
          },
        );
    controller.setInputPath('C:\\Books\\book.epub');

    final Future<void> inspection = controller.startInspection();
    await lookupStarted.future;
    controller.setOutputDirectory('C:\\ChosenOutput');
    inferredOutputDirectory.complete('C:\\Books');
    await inspection;

    expect(repository.lastOutputDirectory, 'C:\\ChosenOutput');
    expect(controller.state.outputDirectory, 'C:\\ChosenOutput');
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
            selectedChapterPaths: ['chapter.xhtml'],
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

  test('late session restore cannot overwrite a retried job path', () async {
    final _ControlledSessionPathStore pathStore = _ControlledSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: _MemoryJobHistoryStore(
            initial: const <TranslationJob>[
              TranslationJob(
                id: 'retry-old-job',
                selectedChapterPaths: ['chapter.xhtml'],
                inputPath: 'C:\\Books\\retry.epub',
                outputPath: 'C:\\RetryOutput',
                status: TranslationJobStatus.failed,
                phase: TranslationJobPhase.inspection,
                progress: 0,
              ),
            ],
          ),
          pathStore: pathStore,
        );
    await Future<void>.delayed(Duration.zero);

    await controller.retryJob('retry-old-job');
    pathStore.loadCompleter.complete((
      inputPath: 'C:\\Books\\stale.epub',
      outputDirectory: 'C:\\StaleOutput',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.inputPath, 'C:\\Books\\retry.epub');
    expect(controller.state.outputDirectory, 'C:\\RetryOutput');
  });

  test('session restore skips an EPUB path that no longer exists', () async {
    final _ControlledSessionPathStore pathStore = _ControlledSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );
    final String sep = Platform.pathSeparator;
    final String missingEpub =
        '${Directory.systemTemp.path}${sep}epub-translator-missing-test${sep}gone.epub';
    final String missingDir =
        '${Directory.systemTemp.path}${sep}epub-translator-missing-test${sep}out';

    pathStore.loadCompleter.complete((
      inputPath: missingEpub,
      outputDirectory: missingDir,
    ));
    // The restore chain includes a real File.exists() stat call, which needs
    // actual event-loop turns; two zero-duration delays starve under load.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // The dead EPUB path is not restored and no "restored" log is emitted...
    expect(controller.state.inputPath, isEmpty);
    expect(
      controller.state.logs.where(
        (String log) => log.startsWith('Restored last EPUB'),
      ),
      isEmpty,
    );
    // ...but the output directory is restored as-is; translation creates it
    // when missing.
    expect(controller.state.outputDirectory, missingDir);
    expect(
      controller.state.logs.any(
        (String log) => log.startsWith('Restored last output directory'),
      ),
      isTrue,
    );
  });

  test('session restore keeps an EPUB path that still exists', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'epub_translator_session_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final File book = File('${tempDir.path}${Platform.pathSeparator}book.epub');
    await book.writeAsString('fake epub');

    final _ControlledSessionPathStore pathStore = _ControlledSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );

    pathStore.loadCompleter.complete((
      inputPath: book.path,
      outputDirectory: tempDir.path,
    ));
    // The restore chain includes a real File.exists() stat call, which needs
    // actual event-loop turns; two zero-duration delays starve under load.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(controller.state.inputPath, book.path);
    expect(controller.state.logs, contains('Restored last EPUB: book.epub'));
  });

  test('manual EPUB path is remembered without starting inspection', () async {
    final _RecordingSessionPathStore pathStore = _RecordingSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );

    controller.setInputPath('C:\\Books\\manual.epub');
    await Future<void>.delayed(Duration.zero);

    expect(pathStore.saves, isNotEmpty);
    expect(pathStore.saves.last.inputPath, 'C:\\Books\\manual.epub');
  });

  test('manual output directory is remembered without inspection', () async {
    final _RecordingSessionPathStore pathStore = _RecordingSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );

    controller.setOutputDirectory('C:\\Output');
    await Future<void>.delayed(Duration.zero);

    expect(pathStore.saves, isNotEmpty);
    expect(pathStore.saves.last.outputDirectory, 'C:\\Output');
  });

  test('rapid manual edits coalesce queued session writes', () async {
    final _DelayedSessionPathStore pathStore = _DelayedSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );

    controller.setInputPath('C:\\Books\\a');
    await Future<void>.delayed(Duration.zero);
    controller.setInputPath('C:\\Books\\ab');
    controller.setInputPath('C:\\Books\\abc.epub');
    pathStore.releaseFirstWrite.complete();
    await pathStore.firstWriteFinished.future;
    await pathStore.secondWriteFinished.future;
    await Future<void>.delayed(Duration.zero);

    expect(pathStore.writeCount, 2);
    expect(pathStore.savedInputPath, 'C:\\Books\\abc.epub');
  });

  test('older session save cannot overwrite a newer EPUB selection', () async {
    final _DelayedSessionPathStore pathStore = _DelayedSessionPathStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );

    await controller.importDroppedEpubPath('C:\\Books\\first.epub');
    await controller.importDroppedEpubPath('C:\\Books\\second.epub');
    pathStore.releaseFirstWrite.complete();
    await pathStore.firstWriteFinished.future;
    await pathStore.secondWriteFinished.future;

    expect(pathStore.savedInputPath, 'C:\\Books\\second.epub');
  });

  test('failed session save does not block a newer EPUB selection', () async {
    final _DelayedSessionPathStore pathStore = _DelayedSessionPathStore(
      failFirstWrite: true,
    );
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          pathStore: pathStore,
        );

    await controller.importDroppedEpubPath('C:\\Books\\first.epub');
    await controller.importDroppedEpubPath('C:\\Books\\second.epub');
    pathStore.releaseFirstWrite.complete();
    await pathStore.firstWriteFinished.future;
    await pathStore.secondWriteFinished.future;

    expect(pathStore.savedInputPath, 'C:\\Books\\second.epub');
  });

  test('clearing history wins over a late startup history load', () async {
    final _ControlledHistoryStore historyStore = _ControlledHistoryStore();
    final TranslationDashboardController controller =
        TranslationDashboardController(
          repository: _SuccessfulInspectionRepository(),
          historyStore: historyStore,
        );

    // clearJobHistory awaits the tombstone write, but the write is chained
    // behind the still-pending startup load: complete the load first, then
    // await the clear.
    final Future<bool> clear = controller.clearJobHistory();
    historyStore.loadCompleter.complete(const <TranslationJob>[
      TranslationJob(
        id: 'old-job',
        inputPath: 'old.epub',
        outputPath: '',
        status: TranslationJobStatus.failed,
        progress: 0,
      ),
    ]);
    await clear;
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.jobHistory, isEmpty);
    expect(historyStore.saved, isEmpty);
  });

  test(
    'cancelling during style profile generation leaves the inspected job untouched',
    () async {
      // Regression test: requestCancel during style-profile generation used
      // to stamp the finished inspection job's currentChapter with
      // 'Cancellation requested'. The profile coroutine handles the cancel
      // itself, so the job must be left alone.
      final _BlockingStyleProfileRepository repository =
          _BlockingStyleProfileRepository();
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: repository,
            historyStore: _MemoryJobHistoryStore(),
          );
      controller.setInputPath('C:\\\\Books\\\\book.epub');

      // startInspection auto-starts style-profile generation (config default
      // has styleProfileEnabled: true), which blocks on profileCompleter.
      final Future<void> inspection = controller.startInspection();
      repository.inspectionCompleter.complete(
        const InspectionResult(
          job: TranslationJob(
            id: 'inspection-job',
            inputPath: 'C:\\\\Books\\\\book.epub',
            outputPath: 'C:\\\\Books',
            status: TranslationJobStatus.inspected,
            progress: 1,
          ),
          chapters: <InspectedChapter>[
            InspectedChapter(
              path: 'Text/ch1.xhtml',
              title: 'Chapter 1',
              body: 'body',
              originalHtml: '<p>body</p>',
              blocks: <ExtractedBlock>[],
              category: ChapterCategory.content,
              recommendedForTranslation: true,
              includeInTranslation: true,
            ),
          ],
        ),
      );

      // Wait until the profile coroutine has actually started.
      for (
        int i = 0;
        i < 200 && !controller.state.isGeneratingStyleProfile;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.state.isGeneratingStyleProfile, isTrue);
      expect(controller.state.job?.status, TranslationJobStatus.inspected);

      await controller.requestCancel();
      repository.profileCompleter.complete(TranslationStyleProfile.empty);
      await inspection;

      expect(controller.state.job?.status, TranslationJobStatus.inspected);
      expect(
        controller.state.job?.currentChapter,
        isNot('Cancellation requested'),
      );
      expect(controller.state.isGeneratingStyleProfile, isFalse);
      expect(repository.cancelCount, 1);
    },
  );

  group('Windows path observations (drag-drop / manual entry)', () {
    test('picker flow does not double-fire observations; drop and manual entry '
        'do fire', () async {
      final List<String> observed = <String>[];
      int pickerCalls = 0;
      // Explicit return type: an untyped closure would infer Future<String>
      // here, and Future.timeout's onTimeout (() => null) then fails its
      // runtime type check against T=String.
      Future<String?> pickEpub({
        void Function(WindowsPathNotice)? onWindowsNotice,
      }) async {
        pickerCalls += 1;
        // Simulate the bridge firing the OneDrive notice while the
        // dialog was open.
        onWindowsNotice?.call(WindowsPathNotice.oneDrivePlaceholder);
        return r'C:\Users\me\OneDrive\book.epub';
      }

      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _BlockingRepository(),
            historyStore: _MemoryJobHistoryStore(),
            epubPickerOverride: pickEpub,
            windowsPathObserverOverride: (String path) async {
              observed.add(path);
            },
          );

      await controller.pickInputPath();
      expect(pickerCalls, 1);
      // The picker's own notice was logged exactly once; the redundant
      // _acceptInputPath observation was skipped for the picker flow.
      expect(observed, isEmpty);
      const AppStrings strings = AppStrings(UiLanguage.english);
      expect(
        controller.state.logs
            .where((String line) => line == strings.logOneDrivePlaceholderHint)
            .length,
        1,
      );

      // Drag-drop bypasses the dialog hook: the observation must fire.
      final bool dropped = await controller.importDroppedEpubPath(
        r'D:\drop\book.epub',
      );
      expect(dropped, isTrue);
      expect(observed, <String>[r'D:\drop\book.epub']);

      // Manual entry also bypasses the dialog hook (fire-and-forget).
      controller.setInputPath(r'D:\manual\book.epub');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(observed, <String>[r'D:\drop\book.epub', r'D:\manual\book.epub']);
    });

    test('restored session paths run the Windows path observations', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'session_paths_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File inputFile = File('${temp.path}/book.epub')
        ..writeAsStringSync('fake-epub');
      final File sessionFile = File('${temp.path}/session.json');
      // jsonEncode, not string interpolation: on Windows the paths contain
      // backslashes, which are invalid unescaped inside a JSON string and
      // would make SessionPathStore.load() silently return empty paths.
      await sessionFile.writeAsString(
        jsonEncode(<String, String>{
          'inputPath': inputFile.path,
          'outputDirectory': '${temp.path}/out',
        }),
      );
      final List<String> observed = <String>[];
      TranslationDashboardController(
        repository: _SuccessfulInspectionRepository(),
        historyStore: _MemoryJobHistoryStore(),
        pathStore: SessionPathStore(fileProvider: () async => sessionFile),
        windowsPathObserverOverride: (String path) async {
          observed.add(path);
        },
      );
      // _loadSessionPaths is fire-and-forget from the constructor.
      for (int i = 0; i < 100 && observed.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(observed, <String>[inputFile.path, '${temp.path}/out']);
    });
  });

  group('picker re-entrancy guard', () {
    test('rapid double taps open only one file picker dialog', () async {
      final List<Completer<String?>> gates = <Completer<String?>>[];
      int pickerCalls = 0;
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _BlockingRepository(),
            historyStore: _MemoryJobHistoryStore(),
            epubPickerOverride: ({onWindowsNotice}) {
              pickerCalls += 1;
              final Completer<String?> gate = Completer<String?>();
              gates.add(gate);
              return gate.future;
            },
          );

      final Future<void> first = controller.pickInputPath();
      await Future<void>.delayed(Duration.zero);
      // Second tap while the first dialog is still open: ignored instead of
      // stacking a second WinForms dialog behind the first.
      await controller.pickInputPath();
      expect(pickerCalls, 1);

      gates.single.complete(r'C:\Books\book.epub');
      await first;
      expect(controller.state.inputPath, r'C:\Books\book.epub');

      // The guard is cleared: a later pick works again.
      final Future<void> second = controller.pickInputPath();
      await Future<void>.delayed(Duration.zero);
      expect(pickerCalls, 2);
      gates.last.complete(null);
      await second;
    });

    test('rapid double taps open only one directory picker dialog', () async {
      final List<Completer<String?>> gates = <Completer<String?>>[];
      int dirCalls = 0;
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _BlockingRepository(),
            historyStore: _MemoryJobHistoryStore(),
            directoryPickerOverride: ({onWindowsNotice}) {
              dirCalls += 1;
              final Completer<String?> gate = Completer<String?>();
              gates.add(gate);
              return gate.future;
            },
          );

      final Future<void> first = controller.pickOutputDirectory();
      await Future<void>.delayed(Duration.zero);
      await controller.pickOutputDirectory();
      expect(dirCalls, 1);

      gates.single.complete(r'D:\out');
      await first;
      expect(controller.state.outputDirectory, r'D:\out');
    });

    test('file and directory pickers share the guard', () async {
      // A file dialog open (possibly behind the app window) also blocks a
      // directory dialog: the two pickers must never overlap.
      final Completer<String?> fileGate = Completer<String?>();
      int dirCalls = 0;
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _BlockingRepository(),
            historyStore: _MemoryJobHistoryStore(),
            epubPickerOverride: ({onWindowsNotice}) => fileGate.future,
            directoryPickerOverride: ({onWindowsNotice}) async {
              dirCalls += 1;
              return null;
            },
          );

      final Future<void> first = controller.pickInputPath();
      await Future<void>.delayed(Duration.zero);
      await controller.pickOutputDirectory();
      expect(dirCalls, 0);

      fileGate.complete(null);
      await first;
    });
  });

  test(
    'restored interrupted jobs show a localized message but keep the English retry sentinel',
    () async {
      final _MemoryJobHistoryStore historyStore = _MemoryJobHistoryStore(
        initial: const <TranslationJob>[
          TranslationJob(
            id: 'interrupted-job',
            inputPath: 'book.epub',
            outputPath: 'book_translated.epub',
            status: TranslationJobStatus.running,
            phase: TranslationJobPhase.translation,
            progress: 0.4,
          ),
        ],
      );
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _SuccessfulInspectionRepository(),
            historyStore: historyStore,
          );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(uiLanguage: UiLanguage.chinese),
      );
      await Future<void>.delayed(Duration.zero);

      final TranslationJob restored = controller.state.jobHistory.single;
      expect(restored.status, TranslationJobStatus.cancelled);
      expect(restored.errorMessage, '应用在上次任务完成前已关闭。');
      expect(
        restored.currentChapter,
        const AppStrings(UiLanguage.chinese).jobStatusTranslationInterrupted,
        reason:
            'the interrupted title is localized; the retry heuristic '
            'reads phase, not the display string',
      );
    },
  );

  test(
    'a stale instance does not resurrect history cleared by another instance',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'history_tombstone_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final File historyFile = File('${temp.path}/job-history.json');
      JobHistoryStore fileStore() =>
          JobHistoryStore(historyFileProvider: () async => historyFile);

      TranslationJob staleJob() => const TranslationJob(
        id: 'stale-job',
        inputPath: 'book.epub',
        outputPath: 'book_translated.epub',
        status: TranslationJobStatus.completed,
        progress: 1,
      );

      // Instance B starts first with an empty history.
      final TranslationDashboardController controllerB =
          TranslationDashboardController(
            repository: _SuccessfulInspectionRepository(),
            historyStore: fileStore(),
          );
      await Future<void>.delayed(Duration.zero);

      // Instance A clears the history afterwards.
      final TranslationDashboardController controllerA =
          TranslationDashboardController(
            repository: _SuccessfulInspectionRepository(),
            historyStore: fileStore(),
          );
      await Future<void>.delayed(Duration.zero);
      await controllerA.clearJobHistory();

      // Wait for A's chained save to land the tombstone.
      int tombstone = 0;
      for (int i = 0; i < 100 && tombstone == 0; i++) {
        tombstone = (await fileStore().loadWithTombstone()).clearedAt;
        if (tombstone == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(tombstone, greaterThan(0));

      // B still holds a stale job in memory and tries to persist it.
      controllerB.state = controllerB.state.copyWith(
        jobHistory: <TranslationJob>[staleJob()],
      );
      await controllerB.debugPersistJobHistoryNow();

      final after = await fileStore().loadWithTombstone();
      expect(
        after.jobs,
        isEmpty,
        reason: 'a stale instance must not resurrect cleared history',
      );

      // Regression: the old guard only skipped that one write, so the next
      // persistence pass (progress tick, run end) wrote the stale entries
      // back. Adopting the tombstone now drops them from B's memory, so a
      // second persist must keep the file empty too.
      await controllerB.debugPersistJobHistoryNow();
      final afterSecond = await fileStore().loadWithTombstone();
      expect(afterSecond.jobs, isEmpty);
      expect(controllerB.state.jobHistory, isEmpty);

      // A fresh instance that saw the tombstone can persist new history.
      final TranslationDashboardController controllerC =
          TranslationDashboardController(
            repository: _SuccessfulInspectionRepository(),
            historyStore: fileStore(),
          );
      await Future<void>.delayed(Duration.zero);
      controllerC.state = controllerC.state.copyWith(
        jobHistory: <TranslationJob>[staleJob()],
      );
      await controllerC.debugPersistJobHistoryNow();

      final resumed = await fileStore().loadWithTombstone();
      expect(resumed.jobs.single.id, 'stale-job');
    },
  );

  test('SAVE_NO_SPACE maps to the localized not-enough-space notice', () {
    TranslationDashboardController controllerFor(UiLanguage language) {
      final TranslationDashboardController controller =
          TranslationDashboardController(
            repository: _SuccessfulInspectionRepository(),
          );
      controller.syncSettings(
        TranslationConfig.defaults().copyWith(uiLanguage: language),
      );
      return controller;
    }

    // The raw English text the native side throws; the log line must be
    // the localized notice, never this string.
    final PlatformException noSpace = PlatformException(
      code: 'SAVE_NO_SPACE',
      message: 'Not enough free space to save this EPUB to Downloads.',
    );

    final TranslationDashboardController english = controllerFor(
      UiLanguage.english,
    );
    expect(
      english.debugSaveErrorLogLine(noSpace),
      const AppStrings(UiLanguage.english).logNotEnoughSpace,
    );
    expect(
      english.debugSaveErrorLogLine(noSpace),
      isNot(contains('Not enough free space to save this EPUB')),
    );

    final TranslationDashboardController chinese = controllerFor(
      UiLanguage.chinese,
    );
    expect(
      chinese.debugSaveErrorLogLine(noSpace),
      const AppStrings(UiLanguage.chinese).logNotEnoughSpace,
    );

    // The sibling branches stay intact: a generic error keeps its safe
    // text, and a Dart-side timeout points at the background continuation.
    expect(
      english.debugSaveErrorLogLine(StateError('disk blew up')),
      contains('disk blew up'),
    );
    expect(
      english.debugSaveErrorLogLine(StateError('Save to Downloads timed out.')),
      const AppStrings(UiLanguage.english).saveTimeoutContinuesBackground,
    );
  });
}
