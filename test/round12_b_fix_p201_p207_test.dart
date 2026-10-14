import 'dart:async';
import 'dart:math';

import 'package:epub_translator_flutter/features/translation/application/translation_dashboard_controller.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspected_chapter.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/inspection_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_config.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_job.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_run_result.dart';
import 'package:epub_translator_flutter/features/translation/domain/models/translation_style_profile.dart';
import 'package:epub_translator_flutter/features/translation/domain/repositories/translation_repository.dart';
import 'package:epub_translator_flutter/features/translation/infrastructure/job_history_store.dart';
import 'package:flutter_test/flutter_test.dart';

InspectedChapter _chapter(String path, int sourceChars) {
  final source = 'x' * sourceChars;
  return InspectedChapter(
    path: path,
    title: path,
    body: source,
    originalHtml: '<p>$source</p>',
    blocks: [
      ExtractedBlock(
        id: 'block-0',
        tagName: 'p',
        sourceHtml: source,
        sourceText: source,
      ),
    ],
    category: ChapterCategory.content,
    recommendedForTranslation: true,
    includeInTranslation: true,
  );
}

class _Repository implements TranslationRepository {
  _Repository(this.chaptersByInput);

  final Map<String, List<InspectedChapter>> chaptersByInput;
  Future<void> Function()? duringInspection;
  Future<void> Function(
    TranslationJob job,
    void Function(TranslationJob) emit,
    void Function(String) releaseSources,
  )?
  duringTranslation;
  int inspectionCalls = 0;
  int translationCalls = 0;

  @override
  Future<InspectionResult> startJob({
    required String inputPath,
    required String outputDirectory,
    required TranslationConfig config,
    TranslationProgressCallback? onProgress,
    TranslationCancellationCheck? isCancelled,
  }) async {
    final chapters = chaptersByInput[inputPath]!;
    final job = TranslationJob(
      id: 'inspection-${++inspectionCalls}',
      inputPath: inputPath,
      outputPath: outputDirectory,
      outputDirectory: outputDirectory,
      status: TranslationJobStatus.running,
      phase: TranslationJobPhase.inspection,
      progress: 0.2,
      totalFiles: chapters.length,
      totalBlocks: chapters.fold(
        0,
        (sum, chapter) => sum + chapter.blocks.length,
      ),
    );
    onProgress?.call(job, 'Inspection running');
    await duringInspection?.call();
    if (isCancelled?.call() ?? false) {
      throw const TranslationCancelledException();
    }
    return InspectionResult(
      job: job.copyWith(status: TranslationJobStatus.inspected, progress: 1),
      chapters: chapters,
    );
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
    void Function(String chapterPath)? onChapterSourcesReleased,
  }) async {
    final selected = chapters.where((chapter) => chapter.includeInTranslation);
    final job = TranslationJob(
      id: 'translation-${++translationCalls}',
      inputPath: inputPath,
      outputPath: '$outputDirectory/translated.epub',
      outputDirectory: outputDirectory,
      status: TranslationJobStatus.running,
      phase: TranslationJobPhase.translation,
      progress: 0,
      totalFiles: selected.length,
      totalBlocks: selected.fold(
        0,
        (sum, chapter) => sum + chapter.blocks.length,
      ),
    );
    TranslationJob lastProgress = job;
    void emit(TranslationJob progress) {
      lastProgress = progress;
      onProgress?.call(progress, 'Translation progress');
    }

    final releasedPaths = <String>{};
    void releaseSources(String chapterPath) {
      releasedPaths.add(chapterPath);
      onChapterSourcesReleased?.call(chapterPath);
    }

    emit(job);
    await duringTranslation?.call(job, emit, releaseSources);
    // A published completed job represents committed output, even while
    // the repository future still waits for its final persistence.
    if (lastProgress.status != TranslationJobStatus.completed &&
        (isCancelled?.call() ?? false)) {
      throw const TranslationCancelledException();
    }
    return TranslationRunResult(
      job: job.copyWith(
        status: TranslationJobStatus.completed,
        progress: 1,
        completedFiles: job.totalFiles,
        completedBlocks: job.totalBlocks,
      ),
      chapters: [
        for (final chapter in chapters)
          releasedPaths.contains(chapter.path)
              ? chapter.copyWith(
                  originalHtml: '',
                  blocks: [
                    for (final block in chapter.blocks)
                      block.copyWith(sourceHtml: '', sourceText: ''),
                  ],
                )
              : chapter,
      ],
    );
  }

  @override
  Future<void> cancelJob(String jobId) async {}

  @override
  Future<String> testConnection({required TranslationConfig config}) async =>
      'OK';

  @override
  Future<TranslationStyleProfile> generateStyleProfile({
    required TranslationConfig config,
    required List<InspectedChapter> chapters,
    TranslationCancellationCheck? isCancelled,
  }) async => TranslationStyleProfile.empty;
}

class _MemoryHistoryStore extends JobHistoryStore {
  List<TranslationJob> jobs = [];

  @override
  Future<({List<TranslationJob> jobs, int clearedAt})>
  loadWithTombstone() async => (jobs: jobs, clearedAt: 0);

  @override
  Future<({bool written, int fileClearedAt})> saveMerged({
    required List<TranslationJob> Function(List<TranslationJob>, int) merge,
    required int clearedAtEpochMs,
  }) async {
    jobs = merge(jobs, 0);
    return (written: true, fileClearedAt: 0);
  }
}

TranslationDashboardController _controller(
  _Repository repository,
  _MemoryHistoryStore historyStore,
) {
  final controller = TranslationDashboardController(
    repository: repository,
    historyStore: historyStore,
  );
  addTearDown(controller.debugDispose);
  controller.syncSettings(
    TranslationConfig.defaults().copyWith(
      styleProfileEnabled: false,
      chunkSize: 3000,
    ),
  );
  controller.setInputPath('/books/A.epub');
  controller.setOutputDirectory('/output-A');
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('P2-01 cancellation preserves the current history context', () async {
    const bookA = '/books/A.epub';
    const bookB = '/books/B.epub';
    // Cover both cancellation/result orders and a newer translation that
    // already owns its history when the old repository result returns.
    for (final sample in [
      (inputChange: 'manual', oldResultFirst: true, newTranslation: false),
      (inputChange: 'drop', oldResultFirst: false, newTranslation: false),
      (inputChange: 'reinspect', oldResultFirst: false, newTranslation: false),
      (inputChange: 'manual', oldResultFirst: false, newTranslation: true),
    ]) {
      final repository = _Repository({
        bookA: [_chapter('A.xhtml', 100)],
        bookB: [_chapter('B.xhtml', 200)],
      });
      final historyStore = _MemoryHistoryStore();
      final controller = _controller(repository, historyStore);
      await controller.startInspection();

      final oldReady = Completer<void>();
      final releaseOld = Completer<void>();
      repository.duringTranslation = (job, emit, releaseSources) async {
        emit(
          job.copyWith(
            status: TranslationJobStatus.completed,
            progress: 1,
            completedBlocks: job.totalBlocks,
          ),
        );
        oldReady.complete();
        await releaseOld.future;
      };
      final oldRun = controller.startTranslation();
      await oldReady.future;
      final oldJob = controller.state.job!;
      expect(controller.state.isRunActive, isFalse);
      expect(oldJob.selectedChapterPaths, ['A.xhtml']);

      final newReady = Completer<void>();
      final releaseNew = Completer<void>();
      Future<void>? newRun;
      try {
        switch (sample.inputChange) {
          case 'manual':
            controller.setInputPath(bookB);
          case 'drop':
            expect(await controller.importDroppedEpubPath(bookB), isTrue);
          case 'reinspect':
            break;
        }
        controller.setOutputDirectory('/output-B');
        if (sample.oldResultFirst) {
          releaseOld.complete();
          expect(await oldRun, isTrue);
        }

        if (sample.newTranslation) {
          await controller.startInspection();
          repository.duringTranslation = (job, emit, releaseSources) async {
            newReady.complete();
            await releaseNew.future;
          };
          newRun = controller.startTranslation();
        } else {
          repository.duringInspection = () async {
            newReady.complete();
            await releaseNew.future;
          };
          newRun = controller.startInspection();
        }
        await newReady.future;
        final newJob = controller.state.job!;
        expect(newJob.id, isNot(oldJob.id));
        expect(controller.state.isRunActive, isTrue);

        if (sample.newTranslation) {
          releaseOld.complete();
          expect(await oldRun, isTrue);
          expect(controller.state.job, same(newJob));
        }
        await controller.requestCancel();
        releaseNew.complete();
        await newRun;
        if (!releaseOld.isCompleted) {
          final afterCancel = controller.state;
          releaseOld.complete();
          expect(await oldRun, isTrue);
          expect(controller.state, same(afterCancel));
        }

        final cancelled = controller.state.job!;
        expect(cancelled.id, newJob.id);
        expect(
          cancelled.inputPath,
          sample.inputChange == 'reinspect' ? bookA : bookB,
        );
        expect(cancelled.outputDirectory, '/output-B');
        expect(cancelled.status, TranslationJobStatus.cancelled);
        expect(cancelled.phase, newJob.phase);
        expect(cancelled.runStartedAt, newJob.runStartedAt);
        expect(cancelled.selectedChapterPaths, newJob.selectedChapterPaths);
        if (sample.newTranslation) {
          expect(cancelled.recordRevision, greaterThan(newJob.recordRevision));
          expect(cancelled.selectedChapterPaths, ['B.xhtml']);
        } else {
          expect(cancelled.runStartedAt, 0);
          expect(cancelled.recordRevision, 0);
          expect(cancelled.selectedChapterPaths, isNull);
        }

        await controller.debugPersistJobHistoryNow();
        for (final history in [
          controller.state.jobHistory,
          historyStore.jobs,
        ]) {
          expect(history, hasLength(2));
          expect(
            history.singleWhere((job) => job.id == oldJob.id).toJson(),
            oldJob.toJson(),
          );
          expect(
            history.singleWhere((job) => job.id == newJob.id).toJson(),
            cancelled.toJson(),
          );
        }
      } finally {
        if (!releaseOld.isCompleted) releaseOld.complete();
        if (!releaseNew.isCompleted) releaseNew.complete();
        await oldRun;
        await newRun;
      }
    }
  });

  test(
    'P2-07 partial source release preserves totals across chunk changes',
    () async {
      final repository = _Repository({
        '/books/A.epub': [_chapter('A.xhtml', 100), _chapter('B.xhtml', 200)],
      });
      final controller = _controller(repository, _MemoryHistoryStore());
      await controller.startInspection();
      final frozen = controller.debugStaticEstimateCache!;
      expect(frozen.estimatedSourceChars, 300);
      expect(frozen.estimatedInputTokens, 75);
      expect(frozen.selectedChapters, 2);
      expect(frozen.totalBlocks, 2);

      final entered = Completer<void>();
      final resume = Completer<void>();
      repository.duringTranslation = (job, emit, releaseSources) async {
        emit(
          job.copyWith(progress: 0.5, completedFiles: 1, completedBlocks: 1),
        );
        releaseSources('A.xhtml');
        entered.complete();
        await resume.future;
      };
      final translating = controller.startTranslation();
      await entered.future;
      try {
        expect(
          controller.state.inspectedChapters.first.blocks.single.sourceText,
          isEmpty,
        );
        expect(
          controller
              .state
              .inspectedChapters
              .last
              .blocks
              .single
              .sourceText
              .length,
          200,
        );
        expect(controller.debugStaticEstimateCache, same(frozen));
        expect(controller.state.runEstimate!.estimatedSourceChars, 300);
        expect(controller.state.runEstimate!.estimatedInputTokens, 75);

        for (final chunkSize in [6000, 4000, 3000]) {
          controller.syncSettings(
            controller.state.config.copyWith(chunkSize: chunkSize),
          );
          final expectedBatches = max(
            1,
            (frozen.estimatedApiBatches * 3000 / chunkSize).ceil(),
          );
          for (final estimate in [
            controller.debugStaticEstimateCache!,
            controller.state.runEstimate!,
          ]) {
            expect(estimate.estimatedSourceChars, 300);
            expect(estimate.estimatedInputTokens, 75);
            expect(estimate.selectedChapters, frozen.selectedChapters);
            expect(estimate.totalBlocks, frozen.totalBlocks);
            expect(estimate.estimatedApiBatches, expectedBatches);
          }
          expect(controller.state.runEstimate!.completedBlocks, 1);
          expect(controller.state.isRunActive, isTrue);
        }
      } finally {
        resume.complete();
        expect(await translating, isTrue);
      }
    },
  );
}
